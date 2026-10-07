package frame

// 任意のバイト列に対する Decode の検査（ファジング・変異した入力・参照実装との突き合わせ）。
//
// 実行：scripts/test_relay.sh -fuzz=FuzzDecode -fuzztime=20s ./core/frame
// ファジングが失敗する入力を見つけると、testdata/fuzz/FuzzDecode/ に保存される（残す。回帰のコーパスになる）。

import (
	"bytes"
	"encoding/binary"
	"math"
	"math/rand/v2"
	"testing"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

// oracleCode は、ws-protocol.md の 4 章の表を、実装と独立に（契約の定数を使わず）書き下した参照実装。
// 受理するなら空文字列を返す。
func oracleCode(message []byte, accepts contract.FrameDirection) ErrorCode {
	const maxBytes = 2097152
	if len(message) < 17 {
		return CodeTruncatedHeader
	}
	if message[0] != 0x42 || message[1] != 0x4C {
		return CodeInvalidMagic
	}
	if message[2] != 1 {
		return CodeUnsupportedVersion
	}
	var direction contract.FrameDirection
	switch typ := message[3]; {
	case typ >= 0x01 && typ <= 0x07:
		direction = contract.FrameDirectionBrowserToRelay
	case typ >= 0x81 && typ <= 0x87:
		direction = contract.FrameDirectionRelayToBrowser
	default:
		return CodeUnknownType
	}
	if direction != accepts {
		return CodeWrongDirection
	}
	declared := uint64(binary.BigEndian.Uint32(message[13:17]))
	if uint64(len(message)) > maxBytes || 17+declared > maxBytes {
		return CodeTooLarge
	}
	if uint64(len(message))-17 != declared {
		return CodeLengthMismatch
	}
	return ""
}

// checkDecode は、1 つの入力に対する Decode の不変条件を検査する。
//   - パニックしない（呼べること自体）／入力を書き換えない
//   - 結果（受理・エラーの符号）が、参照実装と一致する
//   - 受理したときは、欄の値が入力のとおりで、符号化し直すと元と同じになる（予約ビットを除く）
func checkDecode(tb testing.TB, message []byte, accepts contract.FrameDirection) {
	tb.Helper()
	original := bytes.Clone(message)
	got, err := decodeFor(message, accepts)
	if !bytes.Equal(message, original) {
		tb.Fatalf("decodeFor modified the message %x", original)
	}

	want := oracleCode(message, accepts)
	if want != "" {
		if err == nil {
			tb.Fatalf("message %x: accepted, want %s", original, want)
		}
		assertCode(tb, err, want)
		if got.Type != 0 || got.Keyframe || got.TimestampUs != 0 || got.Body != nil {
			tb.Fatalf("message %x: a rejected message must return the zero Frame, got %s", original, describe(got))
		}
		return
	}

	if err != nil {
		tb.Fatalf("message %x: rejected with %v, want accepted", original, err)
	}
	if direction, _ := got.Type.Direction(); direction != accepts {
		tb.Fatalf("message %x: accepted type %#04x of direction %s", original, uint8(got.Type), direction)
	}
	if len(got.Body) != len(message)-17 {
		tb.Fatalf("message %x: body %d bytes, want %d", original, len(got.Body), len(message)-17)
	}
	if got.Keyframe != (message[4]&1 == 1) {
		tb.Fatalf("message %x: keyframe = %t", original, got.Keyframe)
	}
	if got.TimestampUs != binary.BigEndian.Uint64(message[5:13]) {
		tb.Fatalf("message %x: timestamp = %d", original, got.TimestampUs)
	}
	encoded, err := Encode(got)
	if err != nil {
		tb.Fatalf("message %x: re-encode failed: %v", original, err)
	}
	normalized := bytes.Clone(original)
	normalized[4] &= 1
	if !bytes.Equal(encoded, normalized) {
		tb.Fatalf("message %x: re-encoded to %x", original, encoded)
	}
}

func bothReceivers() []contract.FrameDirection {
	return []contract.FrameDirection{contract.FrameDirectionBrowserToRelay, contract.FrameDirectionRelayToBrowser}
}

// seedMessages は、共有ベクタ（有効・無効）と、境界の合成入力を返す。
func seedMessages(tb testing.TB) [][]byte {
	tb.Helper()
	vectors := loadVectors(tb)
	var seeds [][]byte
	for _, vector := range vectors.Valid {
		seeds = append(seeds, mustHex(tb, vector.Hex))
	}
	for _, vector := range vectors.Invalid {
		seeds = append(seeds, mustHex(tb, vector.Hex))
	}
	seeds = append(seeds,
		nil,
		[]byte{},
		bytes.Repeat([]byte{0xFF}, 17),
		bytes.Repeat([]byte{0x00}, 17),
		rawHeader(0x42, 0x4C, 1, 0x04, 0xFF, math.MaxUint64, math.MaxUint32),
		rawMessage(0x04, 1, 0, nil),
	)
	return seeds
}

// mutate は、元のメッセージを、変異させる（欄の書き換え・切り詰め・追加・本文長の境界値）。
// 大きさが上限の前後になる入力は作らない（確保が大きいため。TestDecodeMatchesTheOracleAroundTheSizeLimit が別に検査する）。
func mutate(rng *rand.Rand, base []byte) []byte {
	message := bytes.Clone(base)
	switch rng.IntN(7) {
	case 0: // 1 バイトを書き換える
		if len(message) > 0 {
			message[rng.IntN(len(message))] = byte(rng.IntN(256))
		}
	case 1: // 切り詰める
		if len(message) > 0 {
			message = message[:rng.IntN(len(message)+1)]
		}
	case 2: // 末尾へ追加する
		extra := make([]byte, rng.IntN(40))
		for i := range extra {
			extra[i] = byte(rng.IntN(256))
		}
		message = append(message, extra...)
	case 3: // 本文長の欄を、境界の値で書き換える
		if len(message) >= 17 {
			boundaries := []uint32{0, 1, 17, 2097152 - 18, 2097152 - 17, 2097152 - 16, 2097152, math.MaxUint32, uint32(len(message) - 17), uint32(len(message) - 16)}
			binary.BigEndian.PutUint32(message[13:17], boundaries[rng.IntN(len(boundaries))])
		}
	case 4: // 種別を書き換える
		if len(message) >= 4 {
			message[3] = byte(rng.IntN(256))
		}
	case 5: // 複数のバイトを書き換える
		for i := 0; i < 1+rng.IntN(4) && len(message) > 0; i++ {
			message[rng.IntN(len(message))] = byte(rng.IntN(256))
		}
	default: // そのまま
	}
	return message
}

// 全体の大きさが上限（2,097,152 バイト）の前後になる入力（本文長の宣言と実際の大きさの組み合わせ）を、参照実装と突き合わせる。
func TestDecodeMatchesTheOracleAroundTheSizeLimit(t *testing.T) {
	const maxBytes = 2097152
	actualSizes := []int{17, maxBytes - 1, maxBytes, maxBytes + 1}
	declaredBodies := []uint32{0, 1, maxBytes - 18, maxBytes - 17, maxBytes - 16, maxBytes, math.MaxUint32}
	types := []byte{0x04, 0x81}
	for _, size := range actualSizes {
		for _, declared := range declaredBodies {
			for _, typ := range types {
				message := make([]byte, size)
				copy(message, rawHeader(0x42, 0x4C, 1, typ, 0, 5, declared))
				for _, accepts := range bothReceivers() {
					checkDecode(t, message, accepts)
				}
			}
		}
	}
}

// 固定のシードで、変異させた入力を大量に流し、参照実装と一致することを確かめる（-fuzz なしの通常のテストでも、すべての分岐を通る）。
func TestDecodeMatchesTheOracleOnMutatedInputs(t *testing.T) {
	seeds := seedMessages(t)
	rng := rand.New(rand.NewPCG(18, 20261007))
	iterations := 60000
	if testing.Short() {
		iterations = 5000
	}
	for i := 0; i < iterations; i++ {
		message := mutate(rng, seeds[rng.IntN(len(seeds))])
		for _, accepts := range bothReceivers() {
			checkDecode(t, message, accepts)
		}
	}
}

// FuzzDecode は、任意のバイト列で、Decode がパニックせず、過大な確保をせず、参照実装と一致することを確かめる。
func FuzzDecode(f *testing.F) {
	for _, seed := range seedMessages(f) {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, message []byte) {
		for _, accepts := range bothReceivers() {
			checkDecode(t, message, accepts)
		}
		// 中継の入口は、ブラウザ → 中継の方向と同じ結果になる
		gotRelay, errRelay := Decode(message)
		gotDirect, errDirect := decodeFor(message, contract.FrameDirectionBrowserToRelay)
		if (errRelay == nil) != (errDirect == nil) || (errRelay == nil && !bytes.Equal(gotRelay.Body, gotDirect.Body)) {
			t.Fatalf("Decode and decodeFor(browser_to_relay) disagree for %x", message)
		}
	})
}
