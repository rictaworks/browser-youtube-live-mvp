package session

import (
	"log/slog"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
)

// ブラウザへ送る制御メッセージ。ループのゴルーチンだけが呼ぶ。

// encoded は、符号化の結果と失敗を受ける。符号化は、固定の型の JSON なので失敗しない。失敗したら、記録して、送らない（nil）。
func (s *IngestSession) encoded(message []byte, err error) []byte {
	if err != nil {
		s.log.Error("a control message could not be encoded", slog.String("class", errorClass(err)))
		return nil
	}
	return message
}

// send は、送信元へ、符号化済みのメッセージを送る。送れなければ（接続が閉じている）、送信元を失ったものとして扱う。
func (s *IngestSession) send(src *source, message []byte) {
	if message == nil {
		return
	}
	if err := src.conn.link.Send(message); err != nil {
		s.log.Warn("sending to the browser failed; treating the connection as gone", slog.String("class", errorClass(err)))
		s.sourceLost(src)
	}
}

// sendRaw は、送信元へ送る。失敗しても、何もしない（閉じる手順の中で使う）。
func (s *IngestSession) sendRaw(src *source, message []byte) {
	if message == nil {
		return
	}
	_ = src.conn.link.Send(message)
}

// statusOf は、通知（心拍の応答）を、status の内容にする。視聴 URL は、準備の完了後は、以降のすべての status に載せる
// （通知が持たなければ、中継が知っている値）。
func (s *IngestSession) statusOf(notice backend.Notice) statusFields {
	fields := statusFields{
		State:                  notice.State,
		WatchURL:               notice.WatchURL,
		Warning:                notice.Warning,
		TimeLimitNoticeSeconds: notice.TimeLimitNoticeSeconds,
		EndReason:              notice.EndReason,
	}
	if fields.WatchURL == "" {
		fields.WatchURL = s.watchURL
	}
	return fields
}

func (s *IngestSession) sendStatus(src *source, fields statusFields) {
	if fields.WatchURL == "" {
		fields.WatchURL = s.watchURL
	}
	s.send(src, s.encoded(encodeStatus(fields)))
}

func (s *IngestSession) sendKeyframeRequest(src *source) {
	s.send(src, s.encoded(encodeKeyframeRequest()))
}

// sendAccepted は、接続受理（照合の成功）。再開（状態が reserved 以外）のとき、確定済みのプロファイルを伝える。
func (s *IngestSession) sendAccepted(src *source, result backend.VerifyResult) {
	s.send(src, s.encoded(encodeAccepted(result.State, src.resume, result.Profile, result.Limits.TimeLimitSeconds)))
}
