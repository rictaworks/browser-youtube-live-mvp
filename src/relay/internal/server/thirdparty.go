package server

import (
	"context"
	"fmt"
	"io"
	"log/slog"

	"github.com/sirupsen/logrus"
)

// maxThirdPartyMessageBytes は、外部のライブラリの記録 1 行から写す、メッセージの長さの上限（バイト）。
const maxThirdPartyMessageBytes = 256

// componentGoRTMP は、外部のライブラリ（go-rtmp）の記録に付ける印。
const componentGoRTMP = "go-rtmp"

// RedirectThirdPartyLogs は、外部のライブラリが logrus の標準の出力へ書く記録を、中継の記録（logger）へ向ける。
// go-rtmp は、接続ごとに 1 行（"Changing chunkSize"）を、logrus の標準の出力へ書く（#19 のレビューの申し送り）。これを、中継の
// 記録の形式（slog）に揃える。logrus 自身の出力は、止める。
//
// 水準は、logrus の Info 以下を slog の Debug、Warn を Warn、Error 以上を Error にする（本番の水準 Info では、情報の行は出ない）。
// メッセージは、長さを制限して写す。go-rtmp が全体の記録へ書くのは、チャンクの大きさの変更だけで、配信キー・取り込み先を含まない
// （接続ごとの記録は、go-rtmp の既定で捨てられる。ConnConfig の Logger は設定しない）。
//
// logger は必須。nil は ErrInvalidDeps で、logrus の設定は何も変えない（nil のまま設定すると、外部のライブラリが最初に書いた時点で、
// そのゴルーチンごと落ちる。捨てる出力先へも、黙って差し替えない）。
//
// 戻り値は、元の出力へ戻す関数（試験が使う）。プロセス全体の設定なので、起動時に 1 回だけ呼ぶ。
func RedirectThirdPartyLogs(logger *slog.Logger) (restore func(), err error) {
	if logger == nil {
		return nil, fmt.Errorf("%w: the logger is required", ErrInvalidDeps)
	}
	std := logrus.StandardLogger()
	previousOut := std.Out
	previousHooks := std.ReplaceHooks(make(logrus.LevelHooks))
	std.SetOutput(io.Discard)
	std.AddHook(slogHook{logger: logger})
	return func() {
		std.ReplaceHooks(previousHooks)
		std.SetOutput(previousOut)
	}, nil
}

// slogHook は、logrus の記録を slog へ渡す。
type slogHook struct {
	logger *slog.Logger
}

func (slogHook) Levels() []logrus.Level { return logrus.AllLevels }

func (h slogHook) Fire(entry *logrus.Entry) error {
	message := entry.Message
	if len(message) > maxThirdPartyMessageBytes {
		message = message[:maxThirdPartyMessageBytes]
	}
	h.logger.Log(context.Background(), slogLevelOf(entry.Level), "a library logged a line",
		slog.String("component", componentGoRTMP), slog.String("message", message))
	return nil
}

// slogLevelOf は、logrus の水準を、slog の水準に対応づける。
func slogLevelOf(level logrus.Level) slog.Level {
	switch level {
	case logrus.PanicLevel, logrus.FatalLevel, logrus.ErrorLevel:
		return slog.LevelError
	case logrus.WarnLevel:
		return slog.LevelWarn
	default:
		return slog.LevelDebug
	}
}
