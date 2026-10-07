// Package policer は、受信量の監視（requirements.md 11.9・28.1）です。
//
// 受信ビットレートの上限は、プロファイルの映像ビットレートの上限の 1.5 倍です（契約 limits.json の relay。720p は 9,000 kbps、
// 480p は 3,750 kbps）。直近 10 秒の平均がこれを超える接続は、致命通知（bitrate_exceeded）のうえ切断し、配信を終了します
// （その切断・終了は、呼び出し側の取り込みセッションの仕事です）。プロファイルが未確定の間（回線計測中）は、720p の上限を使います。
package policer

import (
	"fmt"
	"math"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

const (
	// windowSeconds は、平均を取る窓（秒）。
	windowSeconds = contract.RelayIngressBitrateWindowSeconds
	window        = windowSeconds * time.Second

	// coalesceInterval は、これより短い間隔で続く記録を、1 つの項目へまとめる間隔。大量の小さなメッセージが届いても、窓の中の項目が
	// 10 秒あたり最大 10,000 件に収まる（メモリが、受信の量・速さに比例して増えない）。
	coalesceInterval = time.Millisecond

	// maxWindowBytes は、窓の合計として受け付ける最大のバイト数（ビットへ直しても、int64 に収まる）。
	maxWindowBytes = math.MaxInt64 / 8

	bitsPerByte = 8
	bitsPerKbit = 1000
)

// Error は、このパッケージのエラー（定数。errors.Is で判定できる）。
type Error string

func (e Error) Error() string { return string(e) }

const (
	// ErrNegativeBytes は、負のバイト数を記録しようとした。
	ErrNegativeBytes Error = "policer: negative byte count"
	// ErrTimeRegression は、直前の記録より前の時刻で記録しようとした。
	ErrTimeRegression Error = "policer: time went backward"
	// ErrBytesOutOfRange は、窓の合計が、扱える大きさ（桁あふれしない範囲）を超える。
	ErrBytesOutOfRange Error = "policer: byte count out of range"
	// ErrInvalidProfile は、列挙 profile の値でも、未確定（空）でもない。
	ErrInvalidProfile Error = "policer: invalid profile"
)

// LimitKbps は、プロファイルの受信ビットレートの上限（kbps）を返す。映像ビットレートの上限 × 1.5
// （720p は 9,000、480p は 3,750）。profile が空（未確定）なら、720p の上限（RelayIngressBitrateLimitProbeProfile）。
// 列挙 profile の値でなければ、ErrInvalidProfile（別のプロファイルへ倒さない）。
func LimitKbps(profile contract.Profile) (int, error) {
	if profile == "" {
		profile = contract.RelayIngressBitrateLimitProbeProfile
	}
	limits, ok := contract.ProfileLimitsOf(profile)
	if !ok {
		return 0, fmt.Errorf("%w: %q", ErrInvalidProfile, string(profile))
	}
	return int(float64(limits.VideoBitrateMaxKbps) * contract.RelayIngressBitrateLimitFactor), nil
}

// sample は、1 つの項目（受け取った量とその時刻。1 ミリ秒以内のものは、まとめてある）。
type sample struct {
	at    time.Time
	bytes int64
}

// IngressPolicer は、受信量の、直近 10 秒の窓の集計。ゼロ値が使える。ゴルーチンから並行に呼ばない。
//
// 窓は、問い合わせの時刻から遡る 10 秒で、ちょうど 10 秒前の記録は窓の外（経過が 10 秒未満のものが窓の内）。
// 平均は、窓が満ちていなくても 10 秒で割る（接続の直後の、最初のキーフレームなどの大きな 1 枚で、過大な値に見せない）。
type IngressPolicer struct {
	entries   []sample // 古い順。entries[head:] が、保持している項目
	head      int
	sum       int64 // entries[head:] の合計（バイト）
	latest    time.Time
	hasLatest bool
}

// Record は、受け取ったバイト数（メッセージ全体の大きさ）を、時刻 now で記録する。
// bytes が負なら ErrNegativeBytes、now が直前の記録より前なら ErrTimeRegression（同じ時刻は可）、
// 窓の合計が桁あふれする大きさになるなら ErrBytesOutOfRange。エラーのとき、状態は変わらない。
func (p *IngressPolicer) Record(now time.Time, bytes int) error {
	if bytes < 0 {
		return fmt.Errorf("%w: %d", ErrNegativeBytes, bytes)
	}
	if p.hasLatest && now.Before(p.latest) {
		return fmt.Errorf("%w: now=%d latest=%d (unix nanoseconds)", ErrTimeRegression, now.UnixNano(), p.latest.UnixNano())
	}
	added := int64(bytes)
	if current := p.windowBytes(now); added > maxWindowBytes-current {
		return fmt.Errorf("%w: adding %d bytes to %d", ErrBytesOutOfRange, added, current)
	}

	p.expire(now)
	if added > 0 {
		p.add(now, added)
	}
	p.latest = now
	p.hasLatest = true
	return nil
}

// BitrateKbps は、時刻 now の直近 10 秒の、受信ビットレートの平均（kbps。1 kbps = 1,000 bit/s。切り捨て）。状態を変えない。
func (p *IngressPolicer) BitrateKbps(now time.Time) int {
	return int(p.windowBytes(now) * bitsPerByte / (windowSeconds * bitsPerKbit))
}

// Exceeds は、時刻 now の直近 10 秒の平均が、プロファイルの上限（LimitKbps）を超えているか。上限ちょうどは、超過ではない。
// 切り捨てた kbps ではなく、ビット数で比べる（上限を 1 バイトでも超えれば真）。profile が空（未確定）なら、720p の上限。
// profile が不正なら、ErrInvalidProfile。状態を変えない。
func (p *IngressPolicer) Exceeds(now time.Time, profile contract.Profile) (bool, error) {
	limitKbps, err := LimitKbps(profile)
	if err != nil {
		return false, err
	}
	bits := p.windowBytes(now) * bitsPerByte
	return bits > int64(limitKbps)*bitsPerKbit*windowSeconds, nil
}

// windowBytes は、時刻 now の窓の中の合計（バイト）。保持している項目は古い順なので、窓の外の先頭の項目を、合計から引く
// （状態は変えない）。
func (p *IngressPolicer) windowBytes(now time.Time) int64 {
	sum := p.sum
	for i := p.head; i < len(p.entries) && now.Sub(p.entries[i].at) >= window; i++ {
		sum -= p.entries[i].bytes
	}
	return sum
}

// expire は、時刻 now で窓の外になった項目を捨てる。捨てた項目が保持の半分以上になったら、領域を詰める
// （長時間の配信でも、保持する領域が、配信の長さに比例して増えない）。
func (p *IngressPolicer) expire(now time.Time) {
	for p.head < len(p.entries) && now.Sub(p.entries[p.head].at) >= window {
		p.sum -= p.entries[p.head].bytes
		p.head++
	}
	if p.head > 0 && p.head*2 >= len(p.entries) {
		kept := copy(p.entries, p.entries[p.head:])
		p.entries = p.entries[:kept]
		p.head = 0
	}
}

// add は、項目を足す。直前の項目から 1 ミリ秒未満なら、その項目へまとめる（時刻は、先の記録のまま）。
func (p *IngressPolicer) add(now time.Time, bytes int64) {
	if last := len(p.entries) - 1; last >= p.head && now.Sub(p.entries[last].at) < coalesceInterval {
		p.entries[last].bytes += bytes
	} else {
		p.entries = append(p.entries, sample{at: now, bytes: bytes})
	}
	p.sum += bytes
}
