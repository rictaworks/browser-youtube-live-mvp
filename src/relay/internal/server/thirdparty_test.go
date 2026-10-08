package server

import (
	"bytes"
	"log/slog"
	"strings"
	"sync"
	"testing"

	"github.com/sirupsen/logrus"
)

type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// go-rtmp は、接続ごとに、logrus の標準の出力へ 1 行（"Changing chunkSize"）を書く。その出力先を、中継の記録（slog）へ揃える
// （#19 のレビューの申し送り）。logrus 自身は、何も書かない。
func TestRedirectThirdPartyLogsRoutesLogrusIntoSlogAndSilencesItsOwnOutput(t *testing.T) {
	std := logrus.StandardLogger()
	var original bytes.Buffer
	previousOut := std.Out
	std.SetOutput(&original)
	t.Cleanup(func() { std.SetOutput(previousOut) })

	var records syncBuffer
	logger := slog.New(slog.NewJSONHandler(&records, &slog.HandlerOptions{Level: slog.LevelDebug}))
	restore := RedirectThirdPartyLogs(logger)
	logrus.Infof("Changing chunkSize %d->%d", 128, 4096)
	logrus.Warn("a warning")
	logrus.Error("an error")

	if original.Len() != 0 {
		t.Errorf("logrus still wrote to its own output: %q", original.String())
	}
	text := records.String()
	for _, want := range []string{
		`"component":"go-rtmp"`, "Changing chunkSize 128->4096", `"level":"DEBUG"`, `"level":"WARN"`, `"level":"ERROR"`, "a warning", "an error",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("slog records = %s; want %q", text, want)
		}
	}

	restore()
	logrus.Info("after restore")
	if !strings.Contains(original.String(), "after restore") {
		t.Errorf("logrus did not return to its own output after restore: %q", original.String())
	}
	if strings.Contains(records.String(), "after restore") {
		t.Error("logrus still reached slog after restore")
	}
}

// 本番の水準（Info）では、go-rtmp の情報の行は、出ない。警告以上は出る
func TestRoutedThirdPartyInfoLinesAreBelowTheProductionLevel(t *testing.T) {
	std := logrus.StandardLogger()
	previousOut := std.Out
	t.Cleanup(func() { std.SetOutput(previousOut) })

	var records syncBuffer
	logger := slog.New(slog.NewJSONHandler(&records, &slog.HandlerOptions{Level: slog.LevelInfo}))
	restore := RedirectThirdPartyLogs(logger)
	defer restore()
	logrus.Infof("Changing chunkSize %d->%d", 128, 4096)
	logrus.Warn("kept")
	text := records.String()
	if strings.Contains(text, "chunkSize") {
		t.Errorf("an Info line of the library appeared at the production level: %s", text)
	}
	if !strings.Contains(text, "kept") {
		t.Errorf("a warning of the library was lost: %s", text)
	}
}

// 長い行は切る（想定外の内容を、そのまま記録に写さない）
func TestRoutedThirdPartyMessagesAreTruncated(t *testing.T) {
	std := logrus.StandardLogger()
	previousOut := std.Out
	t.Cleanup(func() { std.SetOutput(previousOut) })

	var records syncBuffer
	restore := RedirectThirdPartyLogs(slog.New(slog.NewJSONHandler(&records, &slog.HandlerOptions{Level: slog.LevelDebug})))
	defer restore()
	logrus.Warn(strings.Repeat("x", 5000))
	if n := strings.Count(records.String(), "x"); n > maxThirdPartyMessageBytes {
		t.Errorf("%d bytes of the message were logged; want at most %d", n, maxThirdPartyMessageBytes)
	}
}
