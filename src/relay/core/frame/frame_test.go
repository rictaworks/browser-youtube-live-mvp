package frame

// フレームの符号化・復号の検査。
//
// 共有テストベクタ（ws-frame-vectors.json）の有効・無効のすべてを通し、そのうえで、検証の順・境界・方向・
// 往復・本文の取り扱い（コピーしない・ログへ出さない）を、表形式で確かめる。
// 数値（符号・欄の位置・上限）は、実装と独立に、契約の文書（ws-protocol.md）から書き下している。

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"math/rand/v2"
	"runtime"
	"strings"
	"testing"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

// rawHeader は、検証を通さずに 17 バイトのヘッダを組み立てる（欄の位置を、実装と独立に数値で書く）。
func rawHeader(magic0, magic1, version, typ, attributes byte, timestampUs uint64, declaredBodyBytes uint32) []byte {
	header := make([]byte, 17)
	header[0] = magic0
	header[1] = magic1
	header[2] = version
	header[3] = typ
	header[4] = attributes
	binary.BigEndian.PutUint64(header[5:13], timestampUs)
	binary.BigEndian.PutUint32(header[13:17], declaredBodyBytes)
	return header
}

// rawMessage は、正しい識別子・版のヘッダと本文からなるメッセージを組み立てる。
func rawMessage(typ, attributes byte, timestampUs uint64, body []byte) []byte {
	return append(rawHeader(0x42, 0x4C, 1, typ, attributes, timestampUs, uint32(len(body))), body...)
}

func describe(f Frame) string {
	return fmt.Sprintf("{type=%#04x keyframe=%t timestamp_us=%d body=%x}", uint8(f.Type), f.Keyframe, f.TimestampUs, f.Body)
}

func assertFrameEqual(tb testing.TB, got, want Frame) {
	tb.Helper()
	if got.Type != want.Type || got.Keyframe != want.Keyframe || got.TimestampUs != want.TimestampUs || !bytes.Equal(got.Body, want.Body) {
		tb.Fatalf("frame = %s, want %s", describe(got), describe(want))
	}
}

func assertCode(tb testing.TB, err error, want ErrorCode) {
	tb.Helper()
	code, ok := CodeOf(err)
	if !ok || code != want {
		tb.Fatalf("error = %v (code %q, typed=%t), want code %q", err, code, ok, want)
	}
	if !errors.Is(err, want) {
		tb.Fatalf("errors.Is(%v, %q) = false", err, want)
	}
}

func TestSharedVectorsValid(t *testing.T) {
	vectors := loadVectors(t)
	receivers := []string{receiverRelay, receiverBrowser}
	for _, vector := range vectors.Valid {
		t.Run(vector.Name, func(t *testing.T) {
			message := mustHex(t, vector.Hex)
			want := vector.wantFrame(t)
			for _, receiver := range receivers {
				accepts := receiverAccepts(t, receiver)
				got, err := decodeFor(message, accepts)
				if string(accepts) == vector.Direction {
					if err != nil {
						t.Fatalf("receiver %s: decode failed: %v", receiver, err)
					}
					assertFrameEqual(t, got, want)
					continue
				}
				// 反対側の受信側は、wrong_direction で拒否する
				assertCode(t, err, CodeWrongDirection)
			}

			// 中継の入口 Decode は、ブラウザ → 中継の種別だけを受理する
			got, err := Decode(message)
			if vector.Direction == string(contract.FrameDirectionBrowserToRelay) {
				if err != nil {
					t.Fatalf("Decode failed: %v", err)
				}
				assertFrameEqual(t, got, want)
			} else {
				assertCode(t, err, CodeWrongDirection)
			}
		})
	}
}

func TestSharedVectorsInvalid(t *testing.T) {
	vectors := loadVectors(t)
	for _, vector := range vectors.Invalid {
		t.Run(vector.Name, func(t *testing.T) {
			message := mustHex(t, vector.Hex)
			for _, receiver := range vector.Receivers {
				accepts := receiverAccepts(t, receiver)
				_, err := decodeFor(message, accepts)
				assertCode(t, err, ErrorCode(vector.Error))
				if receiver == receiverRelay {
					_, err := Decode(message)
					assertCode(t, err, ErrorCode(vector.Error))
				}
			}
		})
	}
}

// 共有ベクタを、黙って一部しか通さない形になっていないことの検査（空振りの防止）。
func TestSharedVectorsCoverTheContract(t *testing.T) {
	vectors := loadVectors(t)

	t.Run("有効なフレームは、14 種の種別をすべて持ち、符号と方向が契約の定数と一致する", func(t *testing.T) {
		seen := map[contract.FrameType]bool{}
		for _, vector := range vectors.Valid {
			message, ok := contract.FrameTypeOf(contract.WSMessageType(vector.Decoded.Type))
			if !ok {
				t.Fatalf("%s: unknown message type %q", vector.Name, vector.Decoded.Type)
			}
			if int(message) != vector.Decoded.TypeCode {
				t.Errorf("%s: type_code %d, contract says %d", vector.Name, vector.Decoded.TypeCode, message)
			}
			direction, _ := message.Direction()
			if string(direction) != vector.Direction {
				t.Errorf("%s: direction %q, contract says %q", vector.Name, vector.Direction, direction)
			}
			seen[message] = true
		}
		for _, frameType := range contract.FrameTypes() {
			if !seen[frameType] {
				t.Errorf("no valid vector for type %#04x", uint8(frameType))
			}
		}
	})

	t.Run("無効なフレームは、7 種のエラーのすべてを、中継を受信側として持つ", func(t *testing.T) {
		codes := map[ErrorCode]int{}
		for _, vector := range vectors.Invalid {
			if containsString(vector.Receivers, receiverRelay) {
				codes[ErrorCode(vector.Error)]++
			}
		}
		for _, code := range []ErrorCode{
			CodeTruncatedHeader, CodeInvalidMagic, CodeUnsupportedVersion, CodeUnknownType,
			CodeWrongDirection, CodeTooLarge, CodeLengthMismatch,
		} {
			if codes[code] == 0 {
				t.Errorf("no invalid vector for the relay with error %q", code)
			}
		}
	})
}

func TestEncodeMatchesSharedVectors(t *testing.T) {
	vectors := loadVectors(t)
	for _, vector := range vectors.Valid {
		t.Run(vector.Name, func(t *testing.T) {
			wantHex := mustHex(t, vector.Hex)
			want := vector.wantFrame(t)

			encoded, err := Encode(want)
			if err != nil {
				t.Fatalf("Encode failed: %v", err)
			}
			if vector.DecodeOnly {
				// 属性の予約ビットを立てた例。エンコーダは予約ビットを 0 にするので、同じ並びにはならない（復号だけを検査する）
				if bytes.Equal(encoded, wantHex) {
					t.Fatalf("decode_only vector %s was reproduced; the encoder must zero the reserved bits", vector.Name)
				}
				if encoded[4] != wantHex[4]&1 {
					t.Fatalf("attributes = %#04x, want %#04x (reserved bits zero)", encoded[4], wantHex[4]&1)
				}
				return
			}
			if !bytes.Equal(encoded, wantHex) {
				t.Fatalf("Encode = %x, want %x", encoded, wantHex)
			}

			// 中継 → ブラウザの種別は、時刻 0・属性 0 の制御メッセージとして、EncodeControl でも作れる
			if vector.Direction == string(contract.FrameDirectionRelayToBrowser) {
				if want.Keyframe || want.TimestampUs != 0 {
					t.Fatalf("vector %s is not a plain control message", vector.Name)
				}
				control, err := EncodeControl(want.Type, want.Body)
				if err != nil {
					t.Fatalf("EncodeControl failed: %v", err)
				}
				if !bytes.Equal(control, wantHex) {
					t.Fatalf("EncodeControl = %x, want %x", control, wantHex)
				}
			}
		})
	}
}

func TestDecodeHeaderFieldSweeps(t *testing.T) {
	t.Run("種別符号 0x00〜0xFF：ブラウザ → 中継の 7 種だけを受理し、中継 → ブラウザの 7 種は wrong_direction、残りは unknown_type", func(t *testing.T) {
		for code := 0; code <= 0xFF; code++ {
			_, err := Decode(rawMessage(byte(code), 0, 0, nil))
			switch {
			case code >= 0x01 && code <= 0x07:
				if err != nil {
					t.Errorf("type %#04x: err = %v, want nil", code, err)
				}
			case code >= 0x81 && code <= 0x87:
				if got, ok := CodeOf(err); !ok || got != CodeWrongDirection {
					t.Errorf("type %#04x: err = %v, want %s", code, err, CodeWrongDirection)
				}
			default:
				if got, ok := CodeOf(err); !ok || got != CodeUnknownType {
					t.Errorf("type %#04x: err = %v, want %s", code, err, CodeUnknownType)
				}
			}
		}
	})

	t.Run("版 0〜255：1 だけを受理する", func(t *testing.T) {
		for version := 0; version <= 0xFF; version++ {
			_, err := Decode(rawHeader(0x42, 0x4C, byte(version), 0x04, 0, 0, 0))
			if version == 1 {
				if err != nil {
					t.Errorf("version 1: err = %v, want nil", err)
				}
				continue
			}
			if got, ok := CodeOf(err); !ok || got != CodeUnsupportedVersion {
				t.Errorf("version %d: err = %v, want %s", version, err, CodeUnsupportedVersion)
			}
		}
	})

	t.Run("識別子 65,536 通り：0x42 0x4C だけを受理する", func(t *testing.T) {
		for first := 0; first <= 0xFF; first++ {
			for second := 0; second <= 0xFF; second++ {
				_, err := Decode(rawHeader(byte(first), byte(second), 1, 0x04, 0, 0, 0))
				if first == 0x42 && second == 0x4C {
					if err != nil {
						t.Fatalf("magic 0x42 0x4C: err = %v, want nil", err)
					}
					continue
				}
				if got, ok := CodeOf(err); !ok || got != CodeInvalidMagic {
					t.Fatalf("magic %#04x %#04x: err = %v, want %s", first, second, err, CodeInvalidMagic)
				}
			}
		}
	})

	t.Run("属性：bit0 だけがキーフレーム。予約ビット（bit1〜bit7）は検査せず無視する", func(t *testing.T) {
		cases := []struct {
			attributes byte
			wantKey    bool
		}{
			{0x00, false}, {0x01, true}, {0x02, false}, {0x03, true},
			{0x80, false}, {0x81, true}, {0xFE, false}, {0xFF, true},
		}
		for _, c := range cases {
			got, err := Decode(rawMessage(0x04, c.attributes, 1, []byte{1}))
			if err != nil {
				t.Fatalf("attributes %#04x: err = %v", c.attributes, err)
			}
			if got.Keyframe != c.wantKey {
				t.Errorf("attributes %#04x: keyframe = %t, want %t", c.attributes, got.Keyframe, c.wantKey)
			}
		}
	})

	t.Run("時刻：ビッグエンディアンの符号なし 64 ビットを、そのまま読む", func(t *testing.T) {
		for _, timestamp := range []uint64{
			0, 1, 33_333, 1 << 32, 1<<53 - 1, 1 << 53, 1<<53 + 1, 1 << 63, math.MaxUint64,
		} {
			got, err := Decode(rawMessage(0x05, 0, timestamp, []byte{0x21, 0x00}))
			if err != nil {
				t.Fatalf("timestamp %d: err = %v", timestamp, err)
			}
			if got.TimestampUs != timestamp {
				t.Errorf("timestamp = %d, want %d", got.TimestampUs, timestamp)
			}
		}
	})
}

func TestDecodeTruncatedHeader(t *testing.T) {
	valid := rawMessage(0x04, 1, 33_333, []byte{0, 0, 0, 2, 0x65, 0x88})
	for length := 0; length < 17; length++ {
		_, err := Decode(valid[:length])
		if got, ok := CodeOf(err); !ok || got != CodeTruncatedHeader {
			t.Errorf("length %d: err = %v, want %s", length, err, CodeTruncatedHeader)
		}
	}
	if _, err := Decode(nil); err == nil {
		t.Error("nil message: err = nil")
	} else {
		assertCode(t, err, CodeTruncatedHeader)
	}
	if _, err := Decode(valid); err != nil {
		t.Errorf("full message: err = %v, want nil", err)
	}
}

// 長さの境界（上限ちょうど・上限 + 1・宣言と実際の食い違い）。ws-protocol.md の 4 章：too_large は length_mismatch より先に判定する。
func TestDecodeLengthBoundaries(t *testing.T) {
	const (
		maxBytes    = 2097152 // ws_frame.max_message_bytes
		headerBytes = 17
		video       = 0x04
	)
	cases := []struct {
		name         string
		actualBytes  int
		declaredBody uint32
		wantCode     ErrorCode // 空なら受理
	}{
		{"本文なし（本文長 0）", headerBytes, 0, ""},
		{"本文が 3 バイト足りない（本文長 5・実際 2）", headerBytes + 2, 5, CodeLengthMismatch},
		{"本文が 2 バイト多い（本文長 3・実際 5）", headerBytes + 5, 3, CodeLengthMismatch},
		{"本文長 1 でヘッダだけ", headerBytes, 1, CodeLengthMismatch},
		{"全体がちょうど上限（本文長 = 上限 − 17）", maxBytes, maxBytes - headerBytes, ""},
		{"全体がちょうど上限だが本文長は 0（多い）", maxBytes, 0, CodeLengthMismatch},
		{"全体が上限 + 1（宣言も一致）", maxBytes + 1, maxBytes + 1 - headerBytes, CodeTooLarge},
		{"全体が上限 + 1（宣言は 0。受け取ったバイト数で判定する）", maxBytes + 1, 0, CodeTooLarge},
		{"宣言が上限ちょうど（ヘッダだけ）：上限を超えていないので、本文が足りない", headerBytes, maxBytes - headerBytes, CodeLengthMismatch},
		{"宣言が上限 + 1（ヘッダだけ）：宣言の大きさで too_large", headerBytes, maxBytes - headerBytes + 1, CodeTooLarge},
		{"宣言が uint32 の最大（ヘッダだけ）：オーバーフローしない", headerBytes, math.MaxUint32, CodeTooLarge},
		{"宣言が uint32 の最大（実際は小さな本文）", headerBytes + 10, math.MaxUint32, CodeTooLarge},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			message := make([]byte, c.actualBytes)
			copy(message, rawHeader(0x42, 0x4C, 1, video, 0, 7, c.declaredBody))
			got, err := Decode(message)
			if c.wantCode == "" {
				if err != nil {
					t.Fatalf("err = %v, want nil", err)
				}
				if len(got.Body) != c.actualBytes-headerBytes {
					t.Fatalf("body = %d bytes, want %d", len(got.Body), c.actualBytes-headerBytes)
				}
				return
			}
			assertCode(t, err, c.wantCode)
		})
	}
}

func TestDecodeDoesNotCopyOrModifyTheMessage(t *testing.T) {
	message := rawMessage(0x04, 1, 1_000_000, []byte{0, 0, 0, 5, 0x41, 0x9a, 0x24, 0x6c, 0x41})
	original := bytes.Clone(message)

	got, err := Decode(message)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(message, original) {
		t.Fatal("Decode modified the message")
	}
	if len(got.Body) == 0 || &got.Body[0] != &message[17] {
		t.Fatal("Body must alias the message (no copy; the caller must not reuse the message buffer while holding the frame)")
	}
	if cap(got.Body) != len(got.Body) {
		t.Fatalf("Body capacity %d exceeds its length %d (an append must not write into the message)", cap(got.Body), len(got.Body))
	}
}

// 任意のバイト列で、宣言された本文長に比例した確保をしない（本文長 4 GB のヘッダだけで、巨大な確保が起きない）。
func TestDecodeAllocationIsIndependentOfDeclaredLength(t *testing.T) {
	huge := rawHeader(0x42, 0x4C, 1, 0x04, 0, 0, math.MaxUint32)
	atLimit := rawHeader(0x42, 0x4C, 1, 0x04, 0, 0, 2097152-17)

	for name, message := range map[string][]byte{"too_large": huge, "length_mismatch": atLimit} {
		const iterations = 2000
		var before, after runtime.MemStats
		runtime.GC()
		runtime.ReadMemStats(&before)
		for i := 0; i < iterations; i++ {
			if _, err := Decode(message); err == nil {
				t.Fatalf("%s: err = nil", name)
			}
		}
		runtime.ReadMemStats(&after)
		perCall := (after.TotalAlloc - before.TotalAlloc) / iterations
		if perCall > 1024 {
			t.Errorf("%s: %d bytes allocated per call, want a small constant (not proportional to the declared length)", name, perCall)
		}
	}
}

func TestEncode(t *testing.T) {
	t.Run("欄の位置と値（ビッグエンディアン）", func(t *testing.T) {
		got, err := Encode(Frame{Type: contract.FrameTypeVideo, Keyframe: true, TimestampUs: 0x0102030405060708, Body: []byte{1, 2, 3}})
		if err != nil {
			t.Fatal(err)
		}
		want := []byte{
			0x42, 0x4C, // 識別子
			0x01,                                           // 版
			0x04,                                           // 種別（video）
			0x01,                                           // 属性（bit0 = キーフレーム）
			0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, // 時刻
			0x00, 0x00, 0x00, 0x03, // 本文長
			0x01, 0x02, 0x03, // 本文
		}
		if !bytes.Equal(got, want) {
			t.Fatalf("Encode = %x, want %x", got, want)
		}
	})

	t.Run("キーフレームでなければ属性は 0。本文なしは 17 バイト", func(t *testing.T) {
		got, err := Encode(Frame{Type: contract.FrameTypeAudio})
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(got, rawMessage(0x05, 0, 0, nil)) || len(got) != 17 {
			t.Fatalf("Encode = %x", got)
		}
	})

	t.Run("未知の種別は unknown_type", func(t *testing.T) {
		for _, code := range []byte{0x00, 0x08, 0x7F, 0x80, 0x88, 0xFF} {
			_, err := Encode(Frame{Type: contract.FrameType(code)})
			assertCode(t, err, CodeUnknownType)
		}
	})

	t.Run("全体が上限ちょうどまでは作れ、1 バイト超えたら too_large", func(t *testing.T) {
		const maxBody = 2097152 - 17
		got, err := Encode(Frame{Type: contract.FrameTypeVideo, Body: make([]byte, maxBody)})
		if err != nil {
			t.Fatalf("max body: err = %v", err)
		}
		if len(got) != 2097152 {
			t.Fatalf("encoded %d bytes, want 2097152", len(got))
		}
		_, err = Encode(Frame{Type: contract.FrameTypeVideo, Body: make([]byte, maxBody+1)})
		assertCode(t, err, CodeTooLarge)
	})

	t.Run("作ったフレームは、同じ内容に復号できる（往復）。入力の本文を書き換えない", func(t *testing.T) {
		body := []byte("body")
		encoded, err := Encode(Frame{Type: contract.FrameTypeHello, Body: body})
		if err != nil {
			t.Fatal(err)
		}
		encoded[17] = 'X'
		if string(body) != "body" {
			t.Fatal("Encode aliased the input body")
		}
	})
}

func TestEncodeControl(t *testing.T) {
	t.Run("中継 → ブラウザの 7 種を、時刻 0・属性 0 で作り、ブラウザ側が復号できる", func(t *testing.T) {
		relayToBrowser := 0
		for _, frameType := range contract.FrameTypes() {
			direction, _ := frameType.Direction()
			if direction != contract.FrameDirectionRelayToBrowser {
				continue
			}
			relayToBrowser++
			body := []byte(`{"x":1}`)
			if frameType == contract.FrameTypeKeyframeRequest {
				body = nil
			}
			got, err := EncodeControl(frameType, body)
			if err != nil {
				t.Fatalf("type %#04x: err = %v", uint8(frameType), err)
			}
			if !bytes.Equal(got, rawMessage(byte(frameType), 0, 0, body)) {
				t.Fatalf("type %#04x: EncodeControl = %x", uint8(frameType), got)
			}
			decoded, err := decodeFor(got, contract.FrameDirectionRelayToBrowser)
			if err != nil {
				t.Fatalf("type %#04x: browser decode: %v", uint8(frameType), err)
			}
			assertFrameEqual(t, decoded, Frame{Type: frameType, Body: body})
		}
		if relayToBrowser != 7 {
			t.Fatalf("checked %d relay-to-browser types, want 7", relayToBrowser)
		}
	})

	t.Run("キーフレーム要求は、本文なしの 17 バイト", func(t *testing.T) {
		got, err := EncodeControl(contract.FrameTypeKeyframeRequest, nil)
		if err != nil {
			t.Fatal(err)
		}
		want := []byte{0x42, 0x4C, 0x01, 0x84, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
		if !bytes.Equal(got, want) {
			t.Fatalf("EncodeControl = %x, want %x", got, want)
		}
	})

	t.Run("ブラウザ → 中継の種別を、中継は作らない（wrong_direction）", func(t *testing.T) {
		for _, frameType := range []contract.FrameType{
			contract.FrameTypeHello, contract.FrameTypeProbe, contract.FrameTypeStart,
			contract.FrameTypeVideo, contract.FrameTypeAudio, contract.FrameTypeReport, contract.FrameTypeEnd,
		} {
			_, err := EncodeControl(frameType, nil)
			assertCode(t, err, CodeWrongDirection)
		}
	})

	t.Run("未知の種別は unknown_type", func(t *testing.T) {
		for _, code := range []byte{0x00, 0x08, 0x80, 0x88, 0xFF} {
			_, err := EncodeControl(contract.FrameType(code), nil)
			assertCode(t, err, CodeUnknownType)
		}
	})

	t.Run("上限を超える本文は too_large", func(t *testing.T) {
		_, err := EncodeControl(contract.FrameTypeStatus, make([]byte, 2097152-17+1))
		assertCode(t, err, CodeTooLarge)
		if _, err := EncodeControl(contract.FrameTypeStatus, make([]byte, 2097152-17)); err != nil {
			t.Fatalf("max body: err = %v", err)
		}
	})
}

// 乱数（固定のシード）で作ったフレームが、符号化と復号の往復で同じになる。反対側の受信側は wrong_direction で拒否する。
func TestRoundTripRandomFrames(t *testing.T) {
	rng := rand.New(rand.NewPCG(20261007, 18))
	frameTypes := contract.FrameTypes()
	for i := 0; i < 3000; i++ {
		frameType := frameTypes[rng.IntN(len(frameTypes))]
		body := make([]byte, rng.IntN(400))
		for j := range body {
			body[j] = byte(rng.IntN(256))
		}
		want := Frame{Type: frameType, Keyframe: rng.IntN(2) == 0, TimestampUs: rng.Uint64(), Body: body}

		encoded, err := Encode(want)
		if err != nil {
			t.Fatalf("case %d: Encode: %v", i, err)
		}
		direction, _ := frameType.Direction()
		opposite := contract.FrameDirectionBrowserToRelay
		if direction == contract.FrameDirectionBrowserToRelay {
			opposite = contract.FrameDirectionRelayToBrowser
		}

		got, err := decodeFor(encoded, direction)
		if err != nil {
			t.Fatalf("case %d: decode: %v", i, err)
		}
		assertFrameEqual(t, got, want)

		_, err = decodeFor(encoded, opposite)
		assertCode(t, err, CodeWrongDirection)
	}
}

func TestErrorCodes(t *testing.T) {
	t.Run("errors.Is・errors.As・CodeOf で、符号を取り出せる", func(t *testing.T) {
		_, err := Decode(nil)
		if !errors.Is(err, CodeTruncatedHeader) {
			t.Fatalf("errors.Is(%v, truncated_header) = false", err)
		}
		if errors.Is(err, CodeInvalidMagic) {
			t.Fatalf("errors.Is(%v, invalid_magic) = true", err)
		}
		var typed *Error
		if !errors.As(err, &typed) || typed.Code != CodeTruncatedHeader {
			t.Fatalf("errors.As failed: %v", err)
		}
		wrapped := fmt.Errorf("session x: %w", err)
		if code, ok := CodeOf(wrapped); !ok || code != CodeTruncatedHeader {
			t.Fatalf("CodeOf(wrapped) = (%q, %t)", code, ok)
		}
	})

	t.Run("型付きでないエラーと nil は、符号を持たない", func(t *testing.T) {
		if code, ok := CodeOf(nil); ok || code != "" {
			t.Errorf("CodeOf(nil) = (%q, %t)", code, ok)
		}
		if code, ok := CodeOf(errors.New("other")); ok || code != "" {
			t.Errorf("CodeOf(other) = (%q, %t)", code, ok)
		}
	})

	t.Run("符号は契約の綴り（ws-protocol.md の 4 章）と一致する", func(t *testing.T) {
		want := map[ErrorCode]string{
			CodeTruncatedHeader:    "truncated_header",
			CodeInvalidMagic:       "invalid_magic",
			CodeUnsupportedVersion: "unsupported_version",
			CodeUnknownType:        "unknown_type",
			CodeWrongDirection:     "wrong_direction",
			CodeTooLarge:           "too_large",
			CodeLengthMismatch:     "length_mismatch",
		}
		for code, text := range want {
			if string(code) != text {
				t.Errorf("code %q, want %q", code, text)
			}
		}
	})
}

// 本文（接続チケットなど）を、エラーの文面・ログ用の文字列へ出さない（requirements.md 28.1・IMPLEMENTER_GUIDE の 3）。
func TestBodyIsNeverExposedInErrorsOrStrings(t *testing.T) {
	const secret = "dummy-secret-body-0123456789"
	body := []byte(secret)

	t.Run("エラーの文面", func(t *testing.T) {
		withBadMagic := append(rawHeader(0x58, 0x58, 1, 0x01, 0, 0, uint32(len(body))), body...)
		withBadVersion := append(rawHeader(0x42, 0x4C, 2, 0x01, 0, 0, uint32(len(body))), body...)
		withUnknownType := append(rawHeader(0x42, 0x4C, 1, 0x7F, 0, 0, uint32(len(body))), body...)
		withWrongDirection := rawMessage(0x81, 0, 0, body)
		withLengthMismatch := append(rawHeader(0x42, 0x4C, 1, 0x01, 0, 0, uint32(len(body)+3)), body...)
		withTooLarge := append(rawHeader(0x42, 0x4C, 1, 0x01, 0, 0, math.MaxUint32), body...)

		for name, message := range map[string][]byte{
			"invalid_magic":       withBadMagic,
			"unsupported_version": withBadVersion,
			"unknown_type":        withUnknownType,
			"wrong_direction":     withWrongDirection,
			"length_mismatch":     withLengthMismatch,
			"too_large":           withTooLarge,
		} {
			_, err := Decode(message)
			if err == nil {
				t.Fatalf("%s: err = nil", name)
			}
			if strings.Contains(err.Error(), "dummy-secret") {
				t.Errorf("%s: the error text exposes the body: %v", name, err)
			}
		}
	})

	t.Run("Frame の文字列表現（%v・%+v・%#v・%s・%x）", func(t *testing.T) {
		frame := Frame{Type: contract.FrameTypeHello, Body: body}
		texts := []string{
			fmt.Sprintf("%v", frame),
			fmt.Sprintf("%+v", frame),
			fmt.Sprintf("%#v", frame),
			fmt.Sprintf("%s", frame),
			fmt.Sprintf("%x", frame),
			fmt.Sprint(&frame),
			frame.String(),
		}
		for _, text := range texts {
			if strings.Contains(text, "dummy-secret") || strings.Contains(text, fmt.Sprintf("%x", body)) {
				t.Errorf("a string form exposes the body: %q", text)
			}
		}
		if text := frame.String(); !strings.Contains(text, fmt.Sprint(len(body))) {
			t.Errorf("String() = %q, want the body length", text)
		}
	})
}

// 独立したインスタンス・関数を、複数のゴルーチンから使っても競合しない（グローバルな状態を持たない。-race で確かめる）。
func TestConcurrentUseOfIndependentInstances(t *testing.T) {
	done := make(chan error, 8)
	for worker := 0; worker < 8; worker++ {
		go func(worker int) {
			var guard TimeGuard
			for i := 0; i < 500; i++ {
				message := rawMessage(0x04, 1, uint64(i)*33_333, []byte{byte(worker), byte(i)})
				frame, err := Decode(message)
				if err != nil {
					done <- err
					return
				}
				if err := guard.Admit(frame); err != nil {
					done <- err
					return
				}
				if _, err := Encode(frame); err != nil {
					done <- err
					return
				}
			}
			done <- nil
		}(worker)
	}
	for worker := 0; worker < 8; worker++ {
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	}
}
