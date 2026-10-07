package frame

import "github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"

// mediaKinds は、時刻を持つ種別の数（映像・音声）。
const mediaKinds = 2

// mediaIndex は、映像・音声の種別を、TimeGuard の状態の添字にする。映像・音声でなければ、false。
func mediaIndex(frameType contract.FrameType) (int, bool) {
	switch frameType {
	case contract.FrameTypeVideo:
		return 0, true
	case contract.FrameTypeAudio:
		return 1, true
	}
	return 0, false
}

// TimeGuard は、映像・音声のフレームの時刻の整合を検査する（ws-protocol.md の 4.1・requirements.md 28.1「長さ・種別・時刻の整合」）。
//
// 同じ種別（映像・音声。種別ごとに独立）で、時刻が逆行する（直前に受け入れた時刻より小さい）フレームは破棄する。
// 同じ時刻は、逆行ではない。前方への飛びは、復帰時の空白として受け入れる。
// 制御メッセージ（時刻 0）は、対象外（常に受け入れ、状態を変えない）。
//
// ゼロ値が使える。ゴルーチンから並行に呼ばない。復帰（再接続）をまたいでも、ブラウザのクロックは続くので、状態を引き継ぐ
// （ws-protocol.md の 6 章）。
type TimeGuard struct {
	last [mediaKinds]uint64
	seen [mediaKinds]bool
}

// Admit は、フレームの時刻を検査する。受け入れるなら nil（その種別の最新の時刻を更新する）。
// 逆行していれば、CodeTimeRegression の *Error（呼び出し側は、このフレームを破棄する。状態は変わらない）。
func (g *TimeGuard) Admit(f Frame) error {
	index, media := mediaIndex(f.Type)
	if !media {
		return nil
	}
	if g.seen[index] && f.TimestampUs < g.last[index] {
		return newError(CodeTimeRegression, "type %s: got %d us, last admitted %d us", typeName(f.Type), f.TimestampUs, g.last[index])
	}
	g.last[index] = f.TimestampUs
	g.seen[index] = true
	return nil
}
