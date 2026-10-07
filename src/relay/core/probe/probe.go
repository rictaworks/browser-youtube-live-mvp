// Package probe は、回線計測（requirements.md 11.8、ws-protocol.md の 5.2）です。
//
// ブラウザは、接続受理のあと、3 秒間、最大 6,000 kbps 相当で計測データ（probe）を送ります。中継は、最初の計測データを受けてから
// 3 秒後に、その間に受けた量から、実効スループットを 1 回だけ返します（計測データを 1 つも受けていなければ、3 秒を数え始めません）。
//
// throughput_kbps = その 3 秒間に受けた計測データメッセージ全体（ヘッダを含む）のバイト数の合計 × 8 ÷ 3,000 の切り捨て
// （1 kbps = 1,000 bit/s。契約の仮置き）。
package probe

import (
	"fmt"
	"math"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/policer"
)

const (
	// windowSeconds は、計測の長さ（秒）。最初の計測データを受けた時刻から数える。
	windowSeconds = contract.LineProbeDurationSeconds
	window        = windowSeconds * time.Second

	// maxCountedBytes は、数える量の上限（ビットへ直しても int64 に収まる）。これを超える分は、ここで頭打ちにする
	// （異常の判定は、これより小さい上限で行うので、判定に影響しない）。
	maxCountedBytes = math.MaxInt64 / 8

	bitsPerByte = 8
	bitsPerKbit = 1000
)

// Error は、このパッケージのエラー（定数。errors.Is で判定できる）。
type Error string

func (e Error) Error() string { return string(e) }

const (
	// ErrNoData は、計測データを 1 つも受けていない（計測は始まっていない）。
	ErrNoData Error = "probe: no measurement data received"
	// ErrAbnormal は、受領量が、受信ビットレートの上限（計測中は 720p の上限 = 9,000 kbps）を超える。
	// 計測の最大の送信レート（6,000 kbps）を大きく超える量で、正しいブラウザは送らない。
	// 呼び出し側は、受信ビットレートの超過（致命通知 bitrate_exceeded）と同じ扱いにできる。
	ErrAbnormal Error = "probe: received more than the ingress bitrate limit during the measurement"
	// ErrNegativeBytes は、負のバイト数を追加しようとした。
	ErrNegativeBytes Error = "probe: negative byte count"
	// ErrTimeRegression は、直前の追加より前の時刻で追加しようとした。
	ErrTimeRegression Error = "probe: time went backward"
)

// ProbeMeter は、回線計測の集計。ゼロ値が使える。ゴルーチンから並行に呼ばない。
type ProbeMeter struct {
	started bool
	startAt time.Time
	latest  time.Time
	bytes   int64
}

// Add は、計測データを受け取ったことを、時刻 now・メッセージ全体のバイト数で記録する。
// 最初の追加が、3 秒を数え始める時刻になる。3 秒より後（最初の受信から 3 秒以上経った）の追加は、その間に受けた量ではないので、
// 数えない（エラーにしない。送出の遅れで、後から届く分がある）。
// bytes が負なら ErrNegativeBytes、now が直前の追加より前なら ErrTimeRegression（同じ時刻は可）。エラーのとき、状態は変わらない。
func (m *ProbeMeter) Add(now time.Time, bytes int) error {
	if bytes < 0 {
		return fmt.Errorf("%w: %d", ErrNegativeBytes, bytes)
	}
	if m.started && now.Before(m.latest) {
		return fmt.Errorf("%w: now=%d latest=%d (unix nanoseconds)", ErrTimeRegression, now.UnixNano(), m.latest.UnixNano())
	}
	if !m.started {
		m.started = true
		m.startAt = now
	}
	m.latest = now
	if now.Sub(m.startAt) >= window {
		return nil
	}
	if added := int64(bytes); added > maxCountedBytes-m.bytes {
		m.bytes = maxCountedBytes // 頭打ち（異常の判定は、これより小さい上限で行う）
	} else {
		m.bytes += added
	}
	return nil
}

// Due は、最初の計測データの受信から 3 秒以上経ったか（結果を返す時期か）。計測データを受けていなければ、false。状態を変えない。
func (m *ProbeMeter) Due(now time.Time) bool {
	return m.started && now.Sub(m.startAt) >= window
}

// ThroughputKbps は、最初の計測データの受信から 3 秒間の受領量から、実効スループットを kbps の整数（切り捨て）で返す。
// Due が真になってから呼ぶ（3 秒に満たないうちに呼ぶと、満たない量を 3 秒で割った、小さい値になる）。
//
// 計測データを受けていなければ ErrNoData（黙って 0 を返さない）。受領量が、受信ビットレートの上限（計測中は 720p の上限 =
// 映像ビットレートの上限 × 1.5 = 9,000 kbps。policer.LimitKbps）を 3 秒で受けた量より多ければ ErrAbnormal（上限ちょうどは正常）。
// 状態を変えない。
func (m *ProbeMeter) ThroughputKbps() (int, error) {
	if !m.started {
		return 0, ErrNoData
	}
	limitKbps, err := policer.LimitKbps(contract.RelayIngressBitrateLimitProbeProfile)
	if err != nil {
		return 0, err
	}
	bits := m.bytes * bitsPerByte
	if bits > int64(limitKbps)*bitsPerKbit*windowSeconds {
		return 0, fmt.Errorf("%w: limit %d kbps over %d seconds", ErrAbnormal, limitKbps, windowSeconds)
	}
	return int(bits / (windowSeconds * bitsPerKbit)), nil
}
