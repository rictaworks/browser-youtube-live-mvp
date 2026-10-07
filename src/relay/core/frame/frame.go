// Package frame は、ブラウザと中継の間の WebSocket のバイナリフレーム（ws-protocol.md・requirements.md 11.9）の、
// 符号化・復号・検証と、時刻の整合の検査（TimeGuard）です。
//
// 1 メッセージ = 1 フレーム = ヘッダ 17 バイト + 本文です。ヘッダは、識別子 2（0x42 0x4C）・版 1・種別 1・属性 1（bit0 = キーフレーム）・
// 時刻 8（メディアクロック。マイクロ秒）・本文長 4 で、数値はビッグエンディアンです。
//
// 判定の入力は、受け取ったバイト列そのものです。本文（符号化データ・JSON・接続チケット）の中身は見ません（再エンコードしません。
// 11.1）。検査は、長さ・種別・方向・大きさだけです。
package frame

import (
	"encoding/binary"
	"fmt"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

// ヘッダの欄の位置と大きさ・上限（契約 limits.json の ws_frame）。
const (
	headerBytes     = contract.WSFrameHeaderBytes
	maxMessageBytes = contract.WSFrameMaxMessageBytes

	offsetMagic      = contract.WSFrameHeaderFieldsMagicOffset
	offsetVersion    = contract.WSFrameHeaderFieldsVersionOffset
	offsetType       = contract.WSFrameHeaderFieldsTypeOffset
	offsetAttributes = contract.WSFrameHeaderFieldsAttributesOffset
	offsetTimestamp  = contract.WSFrameHeaderFieldsTimestampUsOffset
	offsetBodyLength = contract.WSFrameHeaderFieldsBodyLengthOffset

	timestampBytes  = contract.WSFrameHeaderFieldsTimestampUsLength
	bodyLengthBytes = contract.WSFrameHeaderFieldsBodyLengthLength

	// keyframeMask は、属性の bit0（キーフレーム）。bit1〜bit7 は予約で、送信側は 0 にし、受信側は検査せず無視する。
	keyframeMask byte = 1 << contract.WSFrameKeyframeAttributeBit
)

// Frame は、WebSocket の 1 メッセージ（ヘッダ + 本文）を復号した結果、または符号化する内容。
type Frame struct {
	// Type は、種別符号（ヘッダの 4 バイト目）。
	Type contract.FrameType
	// Keyframe は、属性の bit0（映像のキーフレームか）。
	Keyframe bool
	// TimestampUs は、メディアクロックのマイクロ秒（符号なし 64 ビット）。映像・音声だけが時刻を持ち、制御メッセージは 0。
	TimestampUs uint64
	// Body は、本文。Decode が返す Body は、復号したメッセージの一部を指す（コピーしない）ので、
	// フレームを使い終わるまで、呼び出し側は、メッセージのバッファを再利用・書き換えしてはならない。
	Body []byte
}

// String は、本文の内容を含めず、長さだけを示す。本文には、接続チケットなどが入り得るため、ログ・エラーへ出さない。
func (f Frame) String() string {
	name := "unknown"
	if message, ok := f.Type.MessageType(); ok {
		name = string(message)
	}
	return fmt.Sprintf("frame{type=%s(0x%02x) keyframe=%t timestamp_us=%d body=%d bytes}", name, uint8(f.Type), f.Keyframe, f.TimestampUs, len(f.Body))
}

// GoString は、%#v でも、本文の内容を出さない。
func (f Frame) GoString() string { return f.String() }

// Decode は、中継が受け取った 1 メッセージを検証し、復号する。受理する種別は、ブラウザ → 中継の 7 種（hello・probe・start・
// video・audio・report・end）だけで、中継 → ブラウザの種別は wrong_direction。
//
// 検証は、ws-protocol.md の 4 章の順に行い、最初に該当した誤りを返す（返す error は *Error）:
//  1. truncated_header     17 バイトに満たない
//  2. invalid_magic        識別子が 0x42 0x4C でない
//  3. unsupported_version  版が 1 でない
//  4. unknown_type         種別符号が 14 種のどれでもない
//  5. wrong_direction      受理しない方向の種別
//  6. too_large            受け取ったバイト数、または宣言する大きさ（17 + 本文長）が、2,097,152 を超える
//  7. length_mismatch      受け取った本文のバイト数が、本文長と一致しない（不足も超過も）
//
// 切断するか・破棄するかは、呼び出し側が決める（too_large は切断、他は破棄。ws-protocol.md の 4.1）。
// 本文長の宣言に比例した確保をしない（ヘッダだけで判定する）。message は書き換えない。
func Decode(message []byte) (Frame, error) {
	return decodeFor(message, contract.FrameDirectionBrowserToRelay)
}

// decodeFor は、direction の種別だけを受理する復号。direction は、受信側が受理する種別の方向
// （中継は browser_to_relay、ブラウザは relay_to_browser）。共有テストベクタは、両方の受信側を検査する。
func decodeFor(message []byte, accepts contract.FrameDirection) (Frame, error) {
	if len(message) < headerBytes {
		return Frame{}, newError(CodeTruncatedHeader, "message is %d bytes, the header needs %d", len(message), headerBytes)
	}
	magic := contract.WSFrameMagic()
	if message[offsetMagic] != magic[0] || message[offsetMagic+1] != magic[1] {
		return Frame{}, newError(CodeInvalidMagic, "got 0x%02x 0x%02x, want 0x%02x 0x%02x", message[offsetMagic], message[offsetMagic+1], magic[0], magic[1])
	}
	if version := message[offsetVersion]; version != contract.WSFrameVersion {
		return Frame{}, newError(CodeUnsupportedVersion, "got %d, want %d", version, contract.WSFrameVersion)
	}

	frameType := contract.FrameType(message[offsetType])
	direction, known := frameType.Direction()
	if !known {
		return Frame{}, newError(CodeUnknownType, "got 0x%02x", uint8(frameType))
	}
	if direction != accepts {
		return Frame{}, newError(CodeWrongDirection, "type %s (0x%02x) goes %s, this receiver accepts %s", typeName(frameType), uint8(frameType), direction, accepts)
	}

	bodyLength := binary.BigEndian.Uint32(message[offsetBodyLength : offsetBodyLength+bodyLengthBytes])
	declaredBytes := uint64(headerBytes) + uint64(bodyLength)
	if uint64(len(message)) > maxMessageBytes || declaredBytes > maxMessageBytes {
		return Frame{}, newError(CodeTooLarge, "message is %d bytes, the header declares %d, the limit is %d", len(message), declaredBytes, maxMessageBytes)
	}
	if uint64(len(message)-headerBytes) != uint64(bodyLength) {
		return Frame{}, newError(CodeLengthMismatch, "body is %d bytes, the header declares %d", len(message)-headerBytes, bodyLength)
	}

	return Frame{
		Type:        frameType,
		Keyframe:    message[offsetAttributes]&keyframeMask != 0,
		TimestampUs: binary.BigEndian.Uint64(message[offsetTimestamp : offsetTimestamp+timestampBytes]),
		// 容量も本文までに絞る（append が、呼び出し側のバッファの続きを書き換えないように）
		Body: message[headerBytes:len(message):len(message)],
	}, nil
}

// Encode は、フレームを、1 メッセージのバイト列にする。種別は 14 種のどれか（でなければ unknown_type）で、
// 全体（17 + 本文）が 2,097,152 バイト以下（超えれば too_large）。属性の予約ビットは 0。
// 本文は、新しい領域へコピーする（返したバイト列を書き換えても、f.Body は変わらない）。
func Encode(f Frame) ([]byte, error) {
	if _, known := f.Type.Direction(); !known {
		return nil, newError(CodeUnknownType, "got 0x%02x", uint8(f.Type))
	}
	total := uint64(headerBytes) + uint64(len(f.Body))
	if total > maxMessageBytes {
		return nil, newError(CodeTooLarge, "message would be %d bytes, the limit is %d", total, maxMessageBytes)
	}

	message := make([]byte, total)
	magic := contract.WSFrameMagic()
	message[offsetMagic] = magic[0]
	message[offsetMagic+1] = magic[1]
	message[offsetVersion] = contract.WSFrameVersion
	message[offsetType] = byte(f.Type)
	if f.Keyframe {
		message[offsetAttributes] = keyframeMask
	}
	binary.BigEndian.PutUint64(message[offsetTimestamp:offsetTimestamp+timestampBytes], f.TimestampUs)
	binary.BigEndian.PutUint32(message[offsetBodyLength:offsetBodyLength+bodyLengthBytes], uint32(len(f.Body)))
	copy(message[headerBytes:], f.Body)
	return message, nil
}

// EncodeControl は、中継が送る制御メッセージ（中継 → ブラウザの 7 種：accepted・probe_result・ack・keyframe_request・
// throttle・status・fatal）を、時刻 0・属性 0 で符号化する。kind がブラウザ → 中継の種別なら wrong_direction、
// 14 種のどれでもなければ unknown_type、全体が上限を超えれば too_large。本文の中身（JSON）は検査しない。
func EncodeControl(kind contract.FrameType, body []byte) ([]byte, error) {
	direction, known := kind.Direction()
	if !known {
		return nil, newError(CodeUnknownType, "got 0x%02x", uint8(kind))
	}
	if direction != contract.FrameDirectionRelayToBrowser {
		return nil, newError(CodeWrongDirection, "type %s (0x%02x) goes %s, a relay sends only %s", typeName(kind), uint8(kind), direction, contract.FrameDirectionRelayToBrowser)
	}
	return Encode(Frame{Type: kind, Body: body})
}

// newError は、符号と、診断のための詳細（数値と符号だけ。本文を含めない）から、*Error を作る。
func newError(code ErrorCode, format string, args ...any) *Error {
	return &Error{Code: code, Detail: fmt.Sprintf(format, args...)}
}

// typeName は、種別の名前（列挙 ws_message_type の符号）。診断用。
func typeName(frameType contract.FrameType) string {
	if message, ok := frameType.MessageType(); ok {
		return string(message)
	}
	return "unknown"
}
