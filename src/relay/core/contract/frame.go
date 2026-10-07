package contract

// FrameDirection は、WebSocket フレームの方向（11.9）。
type FrameDirection string

const (
	FrameDirectionBrowserToRelay FrameDirection = "browser_to_relay"
	FrameDirectionRelayToBrowser FrameDirection = "relay_to_browser"
)

// FrameDirectionValues は、方向の全値を、契約の順に返す（新しいスライス）。
func FrameDirectionValues() []FrameDirection {
	return []FrameDirection{
		FrameDirectionBrowserToRelay,
		FrameDirectionRelayToBrowser,
	}
}

// Valid は、v が契約の方向なら true を返す。
func (v FrameDirection) Valid() bool {
	switch v {
	case FrameDirectionBrowserToRelay, FrameDirectionRelayToBrowser:
		return true
	}
	return false
}

// FrameType は、フレームの種別符号（ヘッダの 4 バイト目）。最上位ビットが方向（0 = ブラウザ → 中継、1 = 中継 → ブラウザ）。
type FrameType uint8

const (
	FrameTypeHello           FrameType = 0x01
	FrameTypeProbe           FrameType = 0x02
	FrameTypeStart           FrameType = 0x03
	FrameTypeVideo           FrameType = 0x04
	FrameTypeAudio           FrameType = 0x05
	FrameTypeReport          FrameType = 0x06
	FrameTypeEnd             FrameType = 0x07
	FrameTypeAccepted        FrameType = 0x81
	FrameTypeProbeResult     FrameType = 0x82
	FrameTypeAck             FrameType = 0x83
	FrameTypeKeyframeRequest FrameType = 0x84
	FrameTypeThrottle        FrameType = 0x85
	FrameTypeStatus          FrameType = 0x86
	FrameTypeFatal           FrameType = 0x87
)

// FrameTypes は、種別符号の全値を、契約の順（列挙 WSMessageType の順）に返す（新しいスライス）。
func FrameTypes() []FrameType {
	return []FrameType{
		FrameTypeHello,
		FrameTypeProbe,
		FrameTypeStart,
		FrameTypeVideo,
		FrameTypeAudio,
		FrameTypeReport,
		FrameTypeEnd,
		FrameTypeAccepted,
		FrameTypeProbeResult,
		FrameTypeAck,
		FrameTypeKeyframeRequest,
		FrameTypeThrottle,
		FrameTypeStatus,
		FrameTypeFatal,
	}
}

// Direction は、種別符号の方向を返す。未知の符号は、空文字列と false。
func (t FrameType) Direction() (FrameDirection, bool) {
	switch t {
	case FrameTypeHello,
		FrameTypeProbe,
		FrameTypeStart,
		FrameTypeVideo,
		FrameTypeAudio,
		FrameTypeReport,
		FrameTypeEnd:
		return FrameDirectionBrowserToRelay, true
	case FrameTypeAccepted,
		FrameTypeProbeResult,
		FrameTypeAck,
		FrameTypeKeyframeRequest,
		FrameTypeThrottle,
		FrameTypeStatus,
		FrameTypeFatal:
		return FrameDirectionRelayToBrowser, true
	}
	return "", false
}

// MessageType は、種別符号に対応するメッセージ種別（列挙 WSMessageType）を返す。未知の符号は、空文字列と false。
func (t FrameType) MessageType() (WSMessageType, bool) {
	switch t {
	case FrameTypeHello:
		return WSMessageTypeHello, true
	case FrameTypeProbe:
		return WSMessageTypeProbe, true
	case FrameTypeStart:
		return WSMessageTypeStart, true
	case FrameTypeVideo:
		return WSMessageTypeVideo, true
	case FrameTypeAudio:
		return WSMessageTypeAudio, true
	case FrameTypeReport:
		return WSMessageTypeReport, true
	case FrameTypeEnd:
		return WSMessageTypeEnd, true
	case FrameTypeAccepted:
		return WSMessageTypeAccepted, true
	case FrameTypeProbeResult:
		return WSMessageTypeProbeResult, true
	case FrameTypeAck:
		return WSMessageTypeAck, true
	case FrameTypeKeyframeRequest:
		return WSMessageTypeKeyframeRequest, true
	case FrameTypeThrottle:
		return WSMessageTypeThrottle, true
	case FrameTypeStatus:
		return WSMessageTypeStatus, true
	case FrameTypeFatal:
		return WSMessageTypeFatal, true
	}
	return "", false
}

// FrameTypeOf は、メッセージ種別（列挙 WSMessageType）に対応する種別符号を返す。未知の種別は、0 と false。
func FrameTypeOf(message WSMessageType) (FrameType, bool) {
	switch message {
	case WSMessageTypeHello:
		return FrameTypeHello, true
	case WSMessageTypeProbe:
		return FrameTypeProbe, true
	case WSMessageTypeStart:
		return FrameTypeStart, true
	case WSMessageTypeVideo:
		return FrameTypeVideo, true
	case WSMessageTypeAudio:
		return FrameTypeAudio, true
	case WSMessageTypeReport:
		return FrameTypeReport, true
	case WSMessageTypeEnd:
		return FrameTypeEnd, true
	case WSMessageTypeAccepted:
		return FrameTypeAccepted, true
	case WSMessageTypeProbeResult:
		return FrameTypeProbeResult, true
	case WSMessageTypeAck:
		return FrameTypeAck, true
	case WSMessageTypeKeyframeRequest:
		return FrameTypeKeyframeRequest, true
	case WSMessageTypeThrottle:
		return FrameTypeThrottle, true
	case WSMessageTypeStatus:
		return FrameTypeStatus, true
	case WSMessageTypeFatal:
		return FrameTypeFatal, true
	}
	return 0, false
}

// WSFrameMagic は、フレームの識別子（ヘッダの先頭 2 バイト。0x42 0x4C = "BL"）を返す。
func WSFrameMagic() [2]byte {
	return [2]byte{0x42, 0x4C}
}
