package session

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/appenv"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/rtmps"
)

// RTMPS の接続の本番の実装（internal/rtmps への薄い接続）の試験。取り込み先の検証は、ネットワークに触れずに確かめる。
// 接続そのものは、結合の試験（#21）が、疑似の受け口で確かめる。ここでは、ローカルの閉じたポートへの接続の失敗だけを確かめる。

func productionFactory(t *testing.T) *RTMPSFactory {
	t.Helper()
	policy, err := rtmps.PolicyFor(appenv.Production)
	if err != nil {
		t.Fatalf("PolicyFor: %v", err)
	}
	return NewRTMPSFactory(policy, rtmps.Config{DialTimeout: 2 * time.Second})
}

func TestTheFactoryRejectsDestinationsThatAreNotYouTubeIngest(t *testing.T) {
	cases := []struct {
		name string
		url  string
		key  string
	}{
		{"別のホスト", "rtmps://evil.example:443/live2", "abcd-efgh"},
		{"平文の rtmp", "rtmp://a.rtmps.youtube.com:443/live2", "abcd-efgh"},
		{"443 以外のポート", "rtmps://a.rtmps.youtube.com:1935/live2", "abcd-efgh"},
		{"ポートの省略", "rtmps://a.rtmps.youtube.com/live2", "abcd-efgh"},
		{"バックアップ（クエリ）", "rtmps://a.rtmps.youtube.com:443/live2?backup=1", "abcd-efgh"},
		{"ユーザー情報", "rtmps://user:pass@a.rtmps.youtube.com:443/live2", "abcd-efgh"},
		{"開発用の疑似の取り込み口（本番には存在しない）", "rtmps://fake-ingest:1935/live2", "abcd-efgh"},
		{"IP アドレス", "rtmps://127.0.0.1:443/live2", "abcd-efgh"},
		{"配信キーを URL に混ぜた形", "rtmps://a.rtmps.youtube.com:443/live2/abcd-efgh", "abcd-efgh"},
		{"空", "", "abcd-efgh"},
		{"配信キーが空", "rtmps://a.rtmps.youtube.com:443/live2", ""},
		{"配信キーに空白", "rtmps://a.rtmps.youtube.com:443/live2", "abcd efgh"},
	}
	factory := productionFactory(t)
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			pub, err := factory.Open(context.Background(), OpenRequest{URL: backendURL(c.url), StreamKey: rtmps.StreamKey(c.key)})
			if pub != nil {
				t.Fatal("a publisher was returned for a rejected destination")
			}
			if !errors.Is(err, ErrDestinationRejected) {
				t.Fatalf("error = %v, want ErrDestinationRejected (no connection may be attempted)", err)
			}
			for _, secret := range []string{c.key, "pass"} {
				if secret != "" && strings.Contains(err.Error(), secret) {
					t.Fatalf("the error contains %q: %q", secret, err.Error())
				}
			}
		})
	}
}

func backendURL(raw string) backend.IngestURL { return backend.IngestURL(raw) }

// 検証に通った取り込み先への接続の失敗は、再試行の対象（ErrDestinationRejected ではない）。記録は、要求の logger に出る。
func TestAConnectionFailureIsRetryableAndLoggedOnTheRequestLogger(t *testing.T) {
	policy, err := rtmps.NewPolicy(rtmps.Target{Host: "localhost", Port: 1})
	if err != nil {
		t.Fatalf("NewPolicy: %v", err)
	}
	factory := NewRTMPSFactory(policy, rtmps.Config{DialTimeout: 2 * time.Second})
	logs := &syncBuffer{}
	logger := slog.New(slog.NewJSONHandler(logs, &slog.HandlerOptions{Level: slog.LevelDebug})).With(slog.String("broadcast_id", idA))

	pub, err := factory.Open(context.Background(), OpenRequest{URL: backendURL("rtmps://localhost:1/live2"), StreamKey: rtmps.StreamKey(dummyStreamKey), Logger: logger})
	if pub != nil {
		t.Fatal("a publisher was returned although nothing listens")
	}
	if err == nil || errors.Is(err, ErrDestinationRejected) || !errors.Is(err, rtmps.ErrDialFailed) {
		t.Fatalf("error = %v, want a dial failure that is not a rejection", err)
	}
	if !strings.Contains(logs.String(), idA) {
		t.Fatalf("the connection failure was not logged with the broadcast id: %q", logs.String())
	}
	for _, text := range []string{err.Error(), logs.String(), fmt.Sprintf("%+v", err)} {
		if strings.Contains(text, dummyStreamKey) {
			t.Fatalf("the stream key leaked: %q", text)
		}
	}
}

func TestTheFactoryDoesNotConnectWhenTheContextIsAlreadyDone(t *testing.T) {
	policy, err := rtmps.NewPolicy(rtmps.Target{Host: "localhost", Port: 1})
	if err != nil {
		t.Fatalf("NewPolicy: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = NewRTMPSFactory(policy, rtmps.Config{}).Open(ctx, OpenRequest{URL: backendURL("rtmps://localhost:1/live2"), StreamKey: "abcd-efgh"})
	if !errors.Is(err, context.Canceled) || errors.Is(err, ErrDestinationRejected) {
		t.Fatalf("error = %v, want context.Canceled", err)
	}
}
