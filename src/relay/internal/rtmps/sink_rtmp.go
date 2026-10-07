package rtmps

import (
	"bytes"
	"time"

	rtmp "github.com/yutopp/go-rtmp"
	"github.com/yutopp/go-rtmp/message"
)

// RTMP のチャンクストリーム ID。0・1 は予約、2 は制御メッセージ、3 はコマンド（go-rtmp が使う）。
// 映像・音声・データは、別の ID にする（go-rtmp の例と同じ。映像の大きなメッセージが、音声を待たせないように、チャンクが交互に流れる）。
const (
	chunkStreamIDData  = 4
	chunkStreamIDAudio = 5
	chunkStreamIDVideo = 6

	// dataMessageName は、RTMP のデータメッセージの名前。publish するクライアントが、メタデータ（onMetaData）を、
	// 「@setDataFrame」の次に付けて送る（OBS・ffmpeg と同じ）。
	dataMessageName = "@setDataFrame"
)

// rtmpSink は、go-rtmp の接続（ClientConn）とストリーム（Stream）の上の sink。
// Stream.Write は、並行に呼べない（共有のメッセージ構造体を書き換える）ので、Publisher の単一の書き込みのゴルーチンだけが呼ぶ。
// Stream.Write は、メッセージを送出の順番待ちへ渡して戻る（実際の書き込みは、go-rtmp の別のゴルーチン）。同じチャンクストリームの
// 次のメッセージは、前のものが書き終わるまで、最大 5 秒待つ（回線が詰まると、ここで止まる）。
type rtmpSink struct {
	conn   *rtmp.ClientConn
	stream *rtmp.Stream
	guard  *killSwitch
	linger time.Duration // おだやかに閉じるとき、相手が閉じるのを待つ上限
}

func (s *rtmpSink) writeVideo(timestampMs uint32, payload []byte) error {
	return s.stream.Write(chunkStreamIDVideo, timestampMs, &message.VideoMessage{Payload: bytes.NewReader(payload)})
}

func (s *rtmpSink) writeAudio(timestampMs uint32, payload []byte) error {
	return s.stream.Write(chunkStreamIDAudio, timestampMs, &message.AudioMessage{Payload: bytes.NewReader(payload)})
}

func (s *rtmpSink) writeMeta(payload []byte) error {
	return s.stream.Write(chunkStreamIDData, 0, &message.DataMessage{
		Name:     dataMessageName,
		Encoding: message.EncodingTypeAMF0,
		Body:     bytes.NewReader(payload),
	})
}

// connectionError は、go-rtmp の読み取りのゴルーチンが止まった原因（切断・読み取りの失敗）を返す。
// go-rtmp は、サーバーの応答 onStatus を無視して（未知のコマンドとして読み捨てる）、読み取りを続けるので、publish が成功しても、
// nil のまま。
func (s *rtmpSink) connectionError() error {
	return s.conn.LastError()
}

func (s *rtmpSink) kill() {
	s.guard.shutdown()
}

// close は、書き込み中のものを待って（go-rtmp の Close）、接続を閉じ、持っていた記述子を解放する。強制の終わり（kill のあと）は、
// すぐに解放する。送り切ったあとの終わりは、おだやかに閉じる（killSwitch.finish。送り残しを送り切り、相手が閉じるのを待つ）。
func (s *rtmpSink) close() error {
	err := s.conn.Close()
	s.guard.finish(s.linger)
	return err
}
