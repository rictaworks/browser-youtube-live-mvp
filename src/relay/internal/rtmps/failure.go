package rtmps

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"log/slog"
	"net"
	"strings"
	"syscall"
)

// 接続の失敗の種類（ログ用の、決まった語彙）。取り込み先のホスト名・IP アドレスを含み得る、原因の文言を、ログへ出さないための分類。
const (
	kindTimeout      = "timeout"       // 接続全体の期限が過ぎた
	kindCanceled     = "canceled"      // 呼び出し側が取り消した
	kindCertificate  = "certificate"   // TLS の証明書の検証が通らない
	kindDNS          = "dns"           // 名前を解決できない
	kindRefused      = "refused"       // 接続を拒否された
	kindTransport    = "transport"     // 接続の切断・リセット・閉じたソケットへの読み書き
	kindWriteTimeout = "write_timeout" // 書き込みの順番待ちが、go-rtmp の固定の期限（5 秒）を過ぎた
	kindProtocol     = "protocol"      // go-rtmp が、受け取ったメッセージを処理できなかった（未対応のメッセージ・パニック）ほか

	// maxLoggedDetailBytes は、protocol の失敗の原因を、ログへ残すときの長さの上限（バイト）。
	maxLoggedDetailBytes = 200
)

// failureKind は、失敗（接続・書き込み・読み取り）の種類を返す。errors.Is・errors.As で、包んだ原因まで調べる。
func failureKind(err error) string {
	var verification *tls.CertificateVerificationError
	var dnsErr *net.DNSError
	var opErr *net.OpError
	switch {
	case errors.Is(err, ErrDialTimeout):
		return kindTimeout
	case errors.Is(err, context.Canceled):
		return kindCanceled
	case errors.As(err, &verification):
		return kindCertificate
	case errors.As(err, &dnsErr):
		return kindDNS
	case errors.Is(err, syscall.ECONNREFUSED):
		return kindRefused
	case errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF), errors.Is(err, net.ErrClosed),
		errors.As(err, &opErr), errors.Is(err, syscall.ECONNRESET), errors.Is(err, syscall.EPIPE):
		return kindTransport
	case errors.Is(err, context.DeadlineExceeded):
		return kindWriteTimeout
	default:
		return kindProtocol
	}
}

// failureAttrs は、失敗の種類（と、protocol のときだけ、原因）を、ログの属性にする。
//
// protocol の原因は、アドレスを含まない（go-rtmp のデコードの失敗・未対応のメッセージの文言）ので、残す。go-rtmp は、未対応の
// メッセージ（未知のユーザー制御イベント・AMF3 のコマンドなど）を受けると、読み取りを止めるので、実機で、YouTube が送った
// メッセージが原因のときに、突き止められるようにする。それ以外の原因の文言は、取り込み先のホスト名・IP アドレスを含み得るので、
// 残さない。
func failureAttrs(err error) []any {
	kind := failureKind(err)
	attrs := []any{slog.String("kind", kind)}
	if kind == kindProtocol {
		attrs = append(attrs, slog.String("detail", truncateForLog(err.Error(), maxLoggedDetailBytes)))
	}
	return attrs
}

// truncateForLog は、文字列を、limit バイトまでに切る（UTF-8 の途中で切らない）。
func truncateForLog(text string, limit int) string {
	if len(text) <= limit {
		return text
	}
	return strings.ToValidUTF8(text[:limit], "") + "..."
}
