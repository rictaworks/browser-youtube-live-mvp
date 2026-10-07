#!/usr/bin/env python3
"""変異テスト: 実装（internal/flv・internal/rtmps）を 1 か所ずつ壊し、Go のテストが、必ず失敗することを確かめる。

  使い方: python3 -I mutate_relay.py <リポジトリのルート> [--only <変異の ID の前方一致>]
          python3 -I mutate_relay.py --self-test

仕組み:
  - 変異は、元のソースの 1 か所の文字列の置き換え。置き換え前の文字列が、ソースに、ちょうど 1 回だけ現れること（現れなければ、
    ソースが変わったので、変異の定義を直す）。
  - ソースのファイルは、書き換えない。変異したファイルを、src/relay/.cache/mutants/<実行ごとの名前>/<変異の ID>/ へ作り、
    go test -overlay（ビルドのときだけ、ファイルの内容を差し替える）で、relay のコンテナの中で、テストを実行する。
    作った変異のファイルは、削除しない（.cache は gitignore 済み。実行ごとに、新しい名前の場所を作る）。
  - 最初に、変異なし（同じ内容の差し替え）で、同じテストが成功することを確かめる（仕組みそのものが動いていること）。
  - 変異を入れたテストが失敗（FAIL・パニック・タイムアウト）すれば「検出」。成功したら「見逃し」。ビルドできなければ、変異の定義の誤り。
  - 見逃し・ビルドの失敗が 1 件でもあれば、失敗（終了コード 1）。

削除系の語は、このファイルのソースにそのまま書かない（実行権限のあるファイルを、CI の hygiene が検査するため）。
"""
import json
import os
import re
import subprocess
import sys
import time

RELAY_IN_CONTAINER = "/app"
GO_TEST_TIMEOUT = "60s"

# ---- テストの選択（変異ごとに、関係するテストだけを実行して、時間を抑える） ----

DESTINATION_TESTS = (
    "^(TestValidateAcceptsYouTubeIngestInProduction|TestValidateRejects|TestValidateInDevelopmentAndTest|"
    "TestProductionHasNoDevelopmentAllowance|TestPolicyForGinMode|TestPolicyForRejectsAnUnknownEnvironment|"
    "TestPolicyIsBuiltFromTheContract|TestNewPolicy|TestValidateWithAnInjectedPolicy|"
    "TestValidateWithAnEmptyPolicyRejectsEverything|TestPolicyTargetsReturnsACopy|TestValidationErrorsDoNotEchoTheInput|"
    "TestValidatedDestinationIsRedactedWhenFormatted|TestZeroValidatedDestinationIsInvalid|FuzzValidate|"
    "TestRtmpsSourcesFollowTheRules)$"
)
STREAM_KEY_TESTS = (
    "^(TestStreamKeyValidate|TestStreamKeyErrorDoesNotContainAnyPartOfTheKey|TestStreamKeyIsRedactedWhenFormatted|"
    "TestStreamKeyIsRedactedInStructuredOutput|TestStreamKeyCanBeDecodedFromJSON|TestPublisherFormatting|"
    "TestRtmpsSourcesFollowTheRules)$"
)
PUBLISHER_UNIT_TESTS = (
    "^(TestPublisherDeliversEverythingInOrder|TestWritesDoNotBlockWhenTheSinkIsStalled|"
    "TestPendingMsIsTheWidthBetweenTheLastQueuedAndTheLastSentTimes|TestOverflowBoundary|"
    "TestOverflowDiscardsTheBufferAndClosesThePublisher|TestNoOverflowWhileTheSinkKeepsUp|"
    "TestOverflowByBytesWhenTimestampsDoNotAdvance|TestMetaMessagesDoNotCountTowardsTheLimit|"
    "TestCloseSendsEverythingPendingBeforeClosing|TestCloseGivesUpAfterTheTimeoutWhenTheSinkIsStalled|"
    "TestAbortDiscardsTheBufferAndDropsTheConnection|TestSinkWriteFailureClosesThePublisher|"
    "TestDisconnectIsDetectedWithoutAnyWrite|TestDisconnectRightAfterPublishIsClassifiedAsRejected|"
    "TestDisconnectAfterTheWindowIsAPlainDisconnect|TestConcurrentWriters|TestInvalidMessagesAreRejectedWithoutClosing|"
    "TestCloseIsIdempotentAndSafeToCallConcurrently|TestCloseWithNothingPending|TestCloseReturnsTheConnectionCloseError|"
    "TestNoGoroutinesRemainAfterAnyKindOfClose|TestPublisherRandomizedOperations|"
    "TestCloseReturnsTeardownTimeoutWhenTheSinkNeverFinishesClosing|TestTeardownBudgetIncludesTheLinger|TestConfigNormalize)$"
)
DIAL_TESTS = (
    "^(TestDialRejectsInvalidArgumentsBeforeTouchingTheNetwork|TestDialWithACanceledContextDoesNotConnect|"
    "TestDialVerifiesTheServerCertificate|TestTLSConfigFor|TestDialTimesOutWhenTheReceiverNeverAnswersTheRTMPHandshake|"
    "TestDialTimesOutDuringTheTLSHandshake|TestDialTimesOutWhenConnectIsNeverAnswered|"
    "TestDialFailsFastWhenTheReceiverClosesWhileConnecting|TestDialReportsARejectedConnect|TestDialIsCanceledByTheCaller|"
    "TestDialHonorsTheCallersDeadline|TestPublisherDeliversMuxerOutputToTheReceiver|TestRtmpsSourcesFollowTheRules)$"
)
INTEGRATION_TESTS = (
    "^(TestPublisherDeliversMuxerOutputToTheReceiver|TestAbortReleasesAStalledWriterImmediately|"
    "TestBufferOverflowWhenTheReceiverStopsReading|TestServerDisconnectIsDetected|TestRejectedPublishIsReportedAsPublishRejected|"
    "TestPublisherCloseWaitsForTheReceiverToClose|TestPublisherCloseStopsWaitingForAReceiverThatDoesNotClose)$"
)
FAILURE_TESTS = (
    "^(TestFailureKind|TestFailureAttrsKeepTheCauseOnlyForProtocolFailures|"
    "TestConnectionFailuresAreLoggedByKindWithoutAddresses|TestOnlyTheFirstFailureIsLogged|TestDialFailuresAreLoggedByKind)$"
)
KILLSWITCH_TESTS = "^TestKillSwitch"
SILENT_DIAL_TESTS = "^(TestDialTimesOutWhenTheReceiverNeverAnswersTheRTMPHandshake|TestDialIsCanceledByTheCaller)$"
FLV_TESTS = "."

RTMPS = "./internal/rtmps/"
FLV = "./internal/flv/"
RTMPS_DIR = "internal/rtmps/"
FLV_DIR = "internal/flv/"


def mutant(identifier, description, relative_file, old, new, package, tests):
    return {
        "id": identifier,
        "description": description,
        "file": relative_file,
        "old": old,
        "new": new,
        "package": package,
        "tests": tests,
    }


def mutants():
    d, k, p, dl, s, ks, f, fl = (RTMPS_DIR + "destination.go", RTMPS_DIR + "streamkey.go", RTMPS_DIR + "publisher.go", RTMPS_DIR + "dial.go",
                                 RTMPS_DIR + "sink_rtmp.go", RTMPS_DIR + "killswitch_unix.go", FLV_DIR + "muxer.go", RTMPS_DIR + "failure.go")
    return [
        # --- 送出先の検証（destination.go） ---
        mutant("dest-scheme", "スキームを検査しない（平文の rtmp を受理する）", d, "if parsed.Scheme != schemeRTMPS {", "if false {", RTMPS, DESTINATION_TESTS),
        mutant("dest-port-any", "ポートを検査しない", d, "if port == strconv.Itoa(allowed.Port) {", "if true {", RTMPS, DESTINATION_TESTS),
        mutant(
            "dest-port-numeric", "ポートを数値で比べる（0443 を 443 として受理する）", d,
            "if port == strconv.Itoa(allowed.Port) {",
            "if number, err := strconv.Atoi(port); err == nil && number == allowed.Port {",
            RTMPS, DESTINATION_TESTS,
        ),
        mutant("dest-userinfo", "ユーザー情報を拒否しない", d, "if parsed.User != nil {", "if false {", RTMPS, DESTINATION_TESTS),
        mutant(
            "dest-query", "クエリの空・フラグメントを拒否しない（?backup=1 だけを拒否する）", d,
            'if parsed.RawQuery != "" || parsed.ForceQuery || parsed.Fragment != "" || parsed.RawFragment != "" || strings.ContainsAny(rawURL, "?#") {',
            'if parsed.RawQuery != "" {', RTMPS, DESTINATION_TESTS,
        ),
        mutant("dest-host", "ホストを照合しない", d, "if allowed.Host != host {", "if false {", RTMPS, DESTINATION_TESTS),
        mutant("dest-host-case", "ホスト名の大文字を、小文字へそろえない", d, "strings.ToLower(parsed.Hostname())", "parsed.Hostname()", RTMPS, DESTINATION_TESTS),
        mutant("dest-encoded-path", "パーセントエンコードのパスを拒否しない", d, 'if parsed.RawPath != "" {', "if false {", RTMPS, DESTINATION_TESTS),
        mutant("dest-app-chars", "アプリ名の文字を検査しない", d, "if !isAppNameByte(app[i]) {", "if false {", RTMPS, DESTINATION_TESTS),
        mutant("dest-app-length", "アプリ名の長さの上限を検査しない", d, "if len(app) < 1 || len(app) > maxAppNameBytes {", "if len(app) < 1 {", RTMPS, DESTINATION_TESTS),
        mutant("dest-printable", "空白・制御文字・非 ASCII を拒否しない", d, "if rawURL[i] < firstPrintable || rawURL[i] > lastPrintable {", "if false {", RTMPS, DESTINATION_TESTS),
        mutant("dest-dev-in-production", "開発用の許可を、production にも置く", d, "if slices.Contains(contract.DevIngestAllowedEnvironments(), string(env)) {", "if true {", RTMPS, DESTINATION_TESTS),
        mutant("dest-skip-verify-inverted", "開発用の取り込み口の、検証の省略の印を、反転する", d, "skipTLSVerify: contract.DevIngestTLS == devTLSSelfSigned,", "skipTLSVerify: contract.DevIngestTLS != devTLSSelfSigned,", RTMPS, DESTINATION_TESTS),
        mutant(
            "dest-skip-verify-youtube", "YouTube の取り込み口にも、検証の省略の印を付ける", d,
            "allowed = append(allowed, allowedTarget{Target: Target{Host: host, Port: contract.RTMPSIngestPort}})",
            "allowed = append(allowed, allowedTarget{Target: Target{Host: host, Port: contract.RTMPSIngestPort}, skipTLSVerify: true})",
            RTMPS, DESTINATION_TESTS,
        ),
        mutant("policy-numeric-tld", "許可リストの、数字だけの最後のラベル（127.0.0.1・127.1 など）を拒否しない", d, "if looksNumeric(labels[len(labels)-1]) {", "if false {", RTMPS, DESTINATION_TESTS),
        mutant("policy-hex-tld", "許可リストの、16 進の最後のラベル（0x7f.0x1）を拒否しない", d, 'if strings.HasPrefix(label, "0x") && len(label) > 2 {', "if false {", RTMPS, DESTINATION_TESTS),
        # --- 配信キー（streamkey.go） ---
        mutant("key-format", "Format が、配信キーの中身を書く", k, "_, _ = io.WriteString(f, redactedStreamKey)", "_, _ = io.WriteString(f, string(k))", RTMPS, STREAM_KEY_TESTS),
        mutant("key-string", "String が、配信キーの中身を返す", k, "func (k StreamKey) String() string { return redactedStreamKey }", "func (k StreamKey) String() string { return string(k) }", RTMPS, STREAM_KEY_TESTS),
        mutant("key-gostring", "GoString が、配信キーの中身を返す", k, "func (k StreamKey) GoString() string { return redactedStreamKey }", "func (k StreamKey) GoString() string { return string(k) }", RTMPS, STREAM_KEY_TESTS),
        mutant("key-text", "MarshalText が、配信キーの中身を返す", k, "return []byte(redactedStreamKey), nil", "return []byte(string(k)), nil", RTMPS, STREAM_KEY_TESTS),
        mutant("key-json", "MarshalJSON が、配信キーの中身を返す", k, "return []byte(`\"` + redactedStreamKey + `\"`), nil", "return []byte(`\"` + string(k) + `\"`), nil", RTMPS, STREAM_KEY_TESTS),
        mutant("key-slog", "LogValue が、配信キーの中身を返す", k, "slog.StringValue(redactedStreamKey)", "slog.StringValue(string(k))", RTMPS, STREAM_KEY_TESTS),
        mutant("key-validate-chars", "配信キーの空白・制御文字を拒否しない", k, "if k[i] < firstPrintable || k[i] > lastPrintable {", "if false {", RTMPS, STREAM_KEY_TESTS),
        mutant("key-validate-length", "配信キーの長さの上限を検査しない", k, "if len(k) > maxStreamKeyBytes {", "if false {", RTMPS, STREAM_KEY_TESTS),
        mutant(
            "key-error-echo", "不正な配信キーのエラーに、配信キーの中身を入れる", k,
            'return fmt.Errorf("%w: unexpected character at position %d", ErrInvalidStreamKey, i)',
            'return fmt.Errorf("%w: invalid key %s", ErrInvalidStreamKey, string(k))', RTMPS, STREAM_KEY_TESTS,
        ),
        # --- 送出キュー・閉じ方（publisher.go） ---
        mutant("pub-overflow-boundary", "送出待ちの上限を「超える」にする（上限ちょうどで、達していない）", p, "pending >= bufferLimitMs", "pending > bufferLimitMs", RTMPS, PUBLISHER_UNIT_TESTS),
        mutant(
            "pub-byte-boundary", "送出待ちの量の上限を「以上」にする", p,
            "total > maxPendingBytes {", "total >= maxPendingBytes {", RTMPS, PUBLISHER_UNIT_TESTS,
        ),
        mutant("pub-byte-limit", "送出待ちの量（バイト）の上限が無い", p, "total > maxPendingBytes {", "total > maxPendingBytes*1000 {", RTMPS, PUBLISHER_UNIT_TESTS),
        mutant("pub-message-limit", "RTMP のメッセージの長さの上限を検査しない", p, "len(payload) == 0 || len(payload) > maxMessageBytes", "len(payload) == 0", RTMPS, PUBLISHER_UNIT_TESTS),
        mutant(
            "pub-failure-no-kill", "接続の失敗（書き込みの失敗・切断）のあと、接続を壊さずに閉じる", p,
            "if p.terminate(p.classifyFailure(cause), true) {", "if p.terminate(p.classifyFailure(cause), false) {",
            RTMPS, PUBLISHER_UNIT_TESTS,
        ),
        mutant("pub-abort-no-kill", "Abort が、接続を壊さない", p, "p.terminate(ErrClosed, true)\n\tp.waitDone()", "p.terminate(ErrClosed, false)\n\tp.waitDone()", RTMPS, PUBLISHER_UNIT_TESTS),
        mutant("pub-teardown-no-kill", "後始末が、先に接続を壊さない", p, "\tif kill {\n\t\tp.sink.kill()\n\t}", "\tif false {\n\t\tp.sink.kill()\n\t}", RTMPS, PUBLISHER_UNIT_TESTS),
        mutant("pub-accept-after-close", "閉じたあとの書き込みを受け付ける", p, "\tif p.state != stateOpen {\n\t\treturn p.closedErrLocked()\n\t}", "\tif false {\n\t\treturn p.closedErrLocked()\n\t}", RTMPS, PUBLISHER_UNIT_TESTS),
        mutant(
            "pub-no-drain", "Close が、送出待ちを送り切らずに閉じる（送り切るのを待たない）", p,
            "case p.state == stateDraining:", "case false:", RTMPS,
            "^(TestCloseSendsEverythingPendingBeforeClosing|TestPublisherDeliversEverythingInOrder)$",
        ),
        mutant("pub-baseline", "最後に送った時刻の起点を 0 にする", p, "p.hasMedia = true\n\t\tp.lastSentMs = timestampMs", "p.hasMedia = true\n\t\tp.lastSentMs = 0", RTMPS, PUBLISHER_UNIT_TESTS),
        mutant("pub-sent-time", "最後に送った時刻を進めない", p, "if sent.kind != kindMeta && sent.ts > p.lastSentMs {", "if false {", RTMPS, PUBLISHER_UNIT_TESTS),
        mutant("pub-drain-cause", "Close の期限切れの原因を、ErrDrainTimeout にしない", p, 'p.terminate(fmt.Errorf("%w (%v)", ErrDrainTimeout, p.cfg.CloseTimeout), true)', "p.terminate(ErrClosed, true)", RTMPS, PUBLISHER_UNIT_TESTS),
        mutant("pub-reject-window", "publish 直後の切断を、ErrPublishRejected に分類しない", p, "if time.Since(p.publishedAt) < p.cfg.PublishRejectWindow {", "if false {", RTMPS, PUBLISHER_UNIT_TESTS),
        mutant("pub-closed-error", "閉じたあとの書き込みのエラーが、原因を包まない", p, 'return fmt.Errorf("%w: %w", ErrClosed, p.cause)', "return ErrClosed", RTMPS, PUBLISHER_UNIT_TESTS),
        mutant(
            "pub-final-error", "Close が、失敗の原因を返さない", p,
            "\tif p.cause != nil && !errors.Is(p.cause, ErrClosed) {\n\t\treturn p.cause\n\t}\n\treturn p.closeErr",
            "\treturn p.closeErr", RTMPS, PUBLISHER_UNIT_TESTS,
        ),
        mutant("pub-teardown-budget", "後始末を待つ期限に、CloseLinger を含めない", p, "p.cfg.TeardownTimeout + p.cfg.CloseLinger", "p.cfg.TeardownTimeout", RTMPS, PUBLISHER_UNIT_TESTS),
        mutant(
            "pub-teardown-timeout-ignored", "後始末が期限内に済まなくても、ErrTeardownTimeout を返さない", p,
            "\tif !p.waitDone() {\n\t\treturn ErrTeardownTimeout\n\t}", "\tif !p.waitDone() && false {\n\t\treturn ErrTeardownTimeout\n\t}", RTMPS, PUBLISHER_UNIT_TESTS,
        ),
        mutant("pub-no-monitor", "接続の切断を見張らない", p, "if err := p.sink.connectionError(); err != nil {", "if err := p.sink.connectionError(); err != nil && false {", RTMPS, PUBLISHER_UNIT_TESTS),
        mutant("pub-keep-queue", "終了しても、バッファを破棄しない", p, "\tp.queue = nil\n\tp.queuedBytes = 0\n\tclose(p.closed)", "\tclose(p.closed)", RTMPS, PUBLISHER_UNIT_TESTS),
        mutant("pub-bytes-count", "送り終えた分を、送出待ちの量から引かない", p, "\t\t\tp.queuedBytes -= len(next.payload)\n", "", RTMPS, PUBLISHER_UNIT_TESTS),
        mutant("pub-log-every-failure", "自分で接続を壊したあとの失敗も、接続の失敗として記録する", p, "if p.terminate(p.classifyFailure(cause), true) {", "if p.terminate(p.classifyFailure(cause), true) || true {", RTMPS, FAILURE_TESTS),
        mutant("failure-detail-always", "protocol 以外の失敗の原因（アドレスを含み得る文言）も、ログへ残す", fl, "if kind == kindProtocol {", "if true {", RTMPS, FAILURE_TESTS),
        mutant("failure-kind-transport", "接続の終わり（EOF）を、transport と分類しない", fl, "case errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF), errors.Is(err, net.ErrClosed),", "case errors.Is(err, io.ErrUnexpectedEOF), errors.Is(err, net.ErrClosed),", RTMPS, FAILURE_TESTS),
        mutant("failure-kind-certificate", "証明書の失敗を、certificate と分類しない", fl, "case errors.As(err, &verification):", "case errors.As(err, &verification) && false:", RTMPS, FAILURE_TESTS),
        # --- 接続（dial.go・sink_rtmp.go・killswitch_unix.go） ---
        mutant("dial-no-killswitch", "接続のソケットを、見張りに登録しない", dl, "FallbackDelay: -1, Control: a.guard.control}", "FallbackDelay: -1}", RTMPS, DIAL_TESTS),
        mutant("dial-abandon-no-shutdown", "見放すときに、ソケットを壊さない", dl, "\ta.guard.shutdown()\n\tif conn := a.conn.Load(); conn != nil {", "\tif conn := a.conn.Load(); conn != nil {", RTMPS, DIAL_TESTS),
        mutant("dial-skip-verify", "TLS の証明書の検証を、常に省略する", dl, "InsecureSkipVerify: dest.skipTLSVerify,", "InsecureSkipVerify: true,", RTMPS, DIAL_TESTS),
        mutant("dial-tls-version", "TLS 1.0 を許す", dl, "MinVersion: tls.VersionTLS12,", "MinVersion: tls.VersionTLS10,", RTMPS, DIAL_TESTS),
        mutant("dial-server-name", "サーバーの名前（SNI）を設定しない", dl, "ServerName: dest.host,", 'ServerName: "",', RTMPS, DIAL_TESTS),
        mutant("dial-publish-type", "publish の種類を live にしない", dl, 'publishingType       = "live"', 'publishingType       = "record"', RTMPS, DIAL_TESTS),
        mutant("dial-no-poll", "接続の途中の切断を、見張らない", dl, "if lastErr := conn.LastError(); lastErr != nil && a.abandon() {", "if lastErr := conn.LastError(); false && lastErr != nil && a.abandon() {", RTMPS, DIAL_TESTS),
        mutant(
            "dial-timeout-error", "期限切れを、ErrDialTimeout にしない", dl,
            "case errors.Is(cause, context.DeadlineExceeded), errors.Is(dialCtx.Err(), context.DeadlineExceeded):", "case false:",
            RTMPS, DIAL_TESTS,
        ),
        mutant("dial-no-deadline", "期限・取り消しを、見張らない", dl, "\t\tcase <-ctx.Done():\n\t\t\tif a.abandon() {", "\t\tcase <-make(chan struct{}):\n\t\t\tif a.abandon() {", RTMPS, SILENT_DIAL_TESTS),
        mutant("sink-meta-name", "メタデータを、@setDataFrame で送らない", s, 'dataMessageName = "@setDataFrame"', 'dataMessageName = "onMetaData"', RTMPS, INTEGRATION_TESTS),
        mutant("sink-no-kill", "sink の kill が、何もしない", s, "func (s *rtmpSink) kill() {\n\ts.guard.shutdown()\n}", "func (s *rtmpSink) kill() {\n}", RTMPS, INTEGRATION_TESTS),
        mutant(
            "sink-close-no-finish", "sink の close が、おだやかに閉じず、記述子を解放するだけにする（読んでいない受信があると、RST で最後の部分が捨てられる）", s,
            "\ts.guard.finish(s.linger)\n", "\ts.guard.release()\n", RTMPS, INTEGRATION_TESTS,
        ),
        mutant("ks-not-broken", "shutdown のあとも、新しいソケットを作らせる", ks, "\tk.broken = true\n", "", RTMPS, KILLSWITCH_TESTS),
        mutant("ks-no-close-on-release", "release が、記述子を閉じない", ks, "\tk.released = true\n\tfor _, fd := range k.fds {\n\t\t_ = syscall.Close(fd)\n\t}\n\tk.fds = nil", "\tk.released = true\n\tk.fds = nil", RTMPS, KILLSWITCH_TESTS),
        mutant("ks-keep-unconnected", "接続できなかった試行の記述子を、閉じない", ks, "if _, err := syscall.Getpeername(fd); err != nil {", "if false {", RTMPS, KILLSWITCH_TESTS),
        mutant("ks-no-shutdown-call", "shutdown が、ソケットを壊さない", ks, "_ = syscall.Shutdown(fd, syscall.SHUT_RDWR)", "_ = fd", RTMPS, KILLSWITCH_TESTS),
        mutant(
            "ks-finish-no-linger", "finish が、受け口が閉じるのを待たずに、記述子を解放する", ks,
            "for k.peerStillOpen() && time.Now().Before(deadline) {", "for false && k.peerStillOpen() && time.Now().Before(deadline) {",
            RTMPS, KILLSWITCH_TESTS,
        ),
        mutant("ks-finish-no-fin", "finish が、送信側を閉じない（FIN を送らない）", ks, "_ = syscall.Shutdown(fd, syscall.SHUT_WR)", "_ = fd", RTMPS, KILLSWITCH_TESTS),
        mutant(
            "ks-finish-peek-only", "finish が、受信を捨てずに、のぞくだけにする（FIN が、読んでいない受信の後ろに隠れる）", ks,
            "syscall.Recvfrom(fd, buffer, syscall.MSG_DONTWAIT)", "syscall.Recvfrom(fd, buffer, syscall.MSG_DONTWAIT|syscall.MSG_PEEK)",
            RTMPS, KILLSWITCH_TESTS,
        ),
        mutant(
            "ks-finish-eof-as-open", "finish が、受け口が閉じた（読み取りが 0 バイト）ことを、閉じていないとみなす", ks,
            "case err == nil && n == 0:\n\t\t\treturn false", "case err == nil && n == 0:\n\t\t\treturn true",
            RTMPS, KILLSWITCH_TESTS,
        ),
        mutant("ks-finish-no-release", "finish が、記述子を解放しない", ks, "\tk.release()\n}\n\n// closeWrite", "\t_ = k\n}\n\n// closeWrite", RTMPS, KILLSWITCH_TESTS),
        # --- FLV 多重化（internal/flv/muxer.go） ---
        mutant("flv-composition-time", "構成時間を 0 にしない", f, "CompositionTime: 0,", "CompositionTime: 1,", FLV, FLV_TESTS),
        mutant("flv-keyframe-flag", "キーフレームの印を反転する", f, "\tif keyframe {\n\t\tframeType = tag.FrameTypeKeyFrame", "\tif !keyframe {\n\t\tframeType = tag.FrameTypeKeyFrame", FLV, FLV_TESTS),
        mutant("flv-video-ready", "映像フレームが、準備を確かめない", f, "\tif err := m.Ready(); err != nil {\n\t\treturn nil, err\n\t}\n\tif len(avccNALUs) == 0 {", "\tif len(avccNALUs) == 0 {", FLV, FLV_TESTS),
        mutant("flv-audio-ready", "音声フレームが、準備を確かめない", f, "\tif err := m.Ready(); err != nil {\n\t\treturn nil, err\n\t}\n\tif len(rawAAC) == 0 {", "\tif len(rawAAC) == 0 {", FLV, FLV_TESTS),
        mutant("flv-reconnect-audio", "再接続のあと、音声設定を作り直させない", f, "\tm.videoConfig = false\n\tm.audioConfig = false", "\tm.videoConfig = false", FLV, FLV_TESTS),
        mutant("flv-reconnect-video", "再接続のあと、映像設定を作り直させない", f, "\tm.videoConfig = false\n\tm.audioConfig = false", "\tm.audioConfig = false", FLV, FLV_TESTS),
        mutant("flv-provisioned", "準備の結果を、記録しない", f, "\tm.provisioned = true", "\tm.provisioned = false", FLV, FLV_TESTS),
        mutant("flv-avc-version", "AVCDecoderConfigurationRecord の版を検査しない", f, "if record[0] != avcConfigurationVersion {", "if false {", FLV, FLV_TESTS),
        mutant("flv-avc-min-length", "映像設定の長さの下限を検査しない", f, "len(record) < minVideoConfigBytes ||", "len(record) < 1 ||", FLV, FLV_TESTS),
        mutant("flv-avc-max-length", "映像設定の長さの上限を検査しない", f, "len(record) > MaxVideoConfigBytes", "len(record) > 1<<30", FLV, FLV_TESTS),
        mutant("flv-asc-min-length", "音声設定の長さの下限を検査しない", f, "len(config) < minAudioConfigBytes ||", "len(config) < 1 ||", FLV, FLV_TESTS),
        mutant("flv-stereo", "stereo の判定を、モノラルにする", f, "profile.AudioChannels == stereoChannels,", "profile.AudioChannels == monoChannels,", FLV, FLV_TESTS),
        mutant("flv-audio-codec", "音声のコーデック ID を、AAC にしない", f, "AudioCodecID = int(tag.SoundFormatAAC)", "AudioCodecID = int(tag.SoundFormatMP3)", FLV, FLV_TESTS),
        mutant("flv-video-empty", "空の映像フレームを受理する", f, "if len(avccNALUs) == 0 {", "if false {", FLV, FLV_TESTS),
        mutant("flv-width", "メタデータの幅に、高さを入れる", f, "metaKeyWidth:           float64(profile.Width),", "metaKeyWidth:           float64(profile.Height),", FLV, FLV_TESTS),
        mutant("flv-channels", "チャンネル数の検査をしない", f, "if p.AudioChannels != monoChannels && p.AudioChannels != stereoChannels {", "if false {", FLV, FLV_TESTS),
    ]


# ---- 実行 ----

def apply_mutation(source, old, new):
    count = source.count(old)
    if count != 1:
        raise ValueError(f"置き換え前の文字列が、ソースに {count} 回現れます（ちょうど 1 回であること）: {old[:80]!r}")
    return source.replace(old, new)


def go_test_command(package, tests, overlay):
    parts = [
        f"cd {RELAY_IN_CONTAINER}",
        "&&",
        "GIN_MODE=test go test -count=1 -failfast",
        f"-timeout {GO_TEST_TIMEOUT}",
    ]
    if overlay:
        parts.append(f"-overlay={overlay}")
    parts += [f"-run '{tests}'", package]
    return " ".join(parts)


def run_in_relay(root, command, timeout):
    return subprocess.run(
        ["scripts/dc.sh", "exec", "-T", "relay", "sh", "-c", command],
        cwd=root, capture_output=True, text=True, timeout=timeout,
    )


def classify(result):
    """go test の結果を分類する: 'passed' | 'killed' | 'build-failed'。"""
    output = result.stdout + result.stderr
    if result.returncode == 0:
        return "passed", []
    if "[build failed]" in output or "build failed" in output or re.search(r"^# github\.com/.*\n.*\.go:\d+:\d+:", output, re.MULTILINE):
        return "build-failed", []
    failed = re.findall(r"^--- FAIL: (\S+)", output, re.MULTILINE)
    if not failed and "panic: test timed out" in output:
        failed = ["(timeout)"]
    if not failed and "FAIL" in output:
        failed = ["(FAIL)"]
    return "killed", failed


def write_overlay(directory, container_directory, relative_file, content):
    os.makedirs(directory, exist_ok=False)
    base = os.path.basename(relative_file)
    with open(os.path.join(directory, base), "w", encoding="utf-8") as handle:
        handle.write(content)
    overlay_path = os.path.join(directory, "overlay.json")
    with open(overlay_path, "w", encoding="utf-8") as handle:
        json.dump({"Replace": {f"{RELAY_IN_CONTAINER}/{relative_file}": f"{container_directory}/{base}"}}, handle)
    return f"{container_directory}/overlay.json"


def main(argv):
    if len(argv) == 2 and argv[1] == "--self-test":
        return self_test()
    only = None
    args = argv[1:]
    if "--only" in args:
        index = args.index("--only")
        only = args[index + 1]
        args = args[:index] + args[index + 2:]
    if len(args) != 1:
        print("使い方: mutate_relay.py <リポジトリのルート> [--only <ID の前方一致>] | --self-test", file=sys.stderr)
        return 2
    root = os.path.abspath(args[0])
    relay = os.path.join(root, "src", "relay")

    run_name = time.strftime("%Y%m%d_%H%M%S")
    work = os.path.join(relay, ".cache", "mutants", run_name)
    container_work = f"{RELAY_IN_CONTAINER}/.cache/mutants/{run_name}"
    os.makedirs(work, exist_ok=False)
    print(f"変異のファイルの置き場（削除しません）: {work}")

    selected = [m for m in mutants() if only is None or m["id"].startswith(only)]
    if not selected:
        print("該当する変異がありません", file=sys.stderr)
        return 2

    # 仕組みの確認：変異なし（同じ内容の差し替え）で、各グループのテストが成功すること
    controls = {}
    for m in selected:
        controls.setdefault((m["file"], m["package"], m["tests"]), m)
    print(f"\n== 対照（変異なし）: {len(controls)} 組")
    for index, ((relative_file, package, tests), m) in enumerate(controls.items()):
        with open(os.path.join(relay, relative_file), encoding="utf-8") as handle:
            original = handle.read()
        overlay = write_overlay(os.path.join(work, f"control{index}"), f"{container_work}/control{index}", relative_file, original)
        started = time.time()
        result = run_in_relay(root, go_test_command(package, tests, overlay), timeout=400)
        verdict, _ = classify(result)
        print(f"  {'成功' if verdict == 'passed' else '失敗'}  {relative_file} {package}  ({time.time() - started:.1f} 秒)")
        if verdict != "passed":
            print((result.stdout + result.stderr)[-3000:])
            print("FAIL 変異なしでも、テストが成功しません。変異テストの結果は、意味を持ちません")
            return 1

    print(f"\n== 変異: {len(selected)} 件")
    killed, survived, invalid = [], [], []
    for index, m in enumerate(selected):
        with open(os.path.join(relay, m["file"]), encoding="utf-8") as handle:
            original = handle.read()
        try:
            mutated = apply_mutation(original, m["old"], m["new"])
        except ValueError as error:
            print(f"  定義の誤り  {m['id']}: {error}")
            invalid.append(m["id"])
            continue
        overlay = write_overlay(os.path.join(work, f"m{index:03d}_{m['id']}"), f"{container_work}/m{index:03d}_{m['id']}", m["file"], mutated)
        started = time.time()
        try:
            result = run_in_relay(root, go_test_command(m["package"], m["tests"], overlay), timeout=400)
        except subprocess.TimeoutExpired:
            print(f"  検出（実行の打ち切り）  {m['id']}: {m['description']}")
            killed.append(m["id"])
            continue
        verdict, failed = classify(result)
        seconds = time.time() - started
        if verdict == "killed":
            killed.append(m["id"])
            print(f"  検出    {m['id']}: {m['description']}  [{', '.join(failed[:2])}]  ({seconds:.1f} 秒)")
        elif verdict == "build-failed":
            invalid.append(m["id"])
            print(f"  ビルドできない  {m['id']}: {m['description']}")
            print((result.stdout + result.stderr)[-1500:])
        else:
            survived.append(m["id"])
            print(f"  見逃し  {m['id']}: {m['description']}  ({seconds:.1f} 秒)")

    print(f"\n検出 {len(killed)} 件 / 見逃し {len(survived)} 件 / 定義の誤り・ビルドの失敗 {len(invalid)} 件（全 {len(selected)} 件）")
    if survived or invalid:
        if survived:
            print("見逃した変異: " + "、".join(survived))
        if invalid:
            print("定義の誤り・ビルドの失敗: " + "、".join(invalid))
        print("FAIL 変異テストに失敗しました")
        return 1
    print("PASS すべての変異を、テストが検出しました")
    return 0


# ---- 自己検査 ----

def self_test():
    failures = []

    def expect(name, condition):
        if not condition:
            failures.append(name)

    expect("1 回だけ現れるものを置き換える", apply_mutation("a b c", "b", "X") == "a X c")
    try:
        apply_mutation("a b b", "b", "X")
        expect("2 回現れる場合は、定義の誤り", False)
    except ValueError:
        expect("2 回現れる場合は、定義の誤り", True)
    try:
        apply_mutation("a b", "z", "X")
        expect("現れない場合は、定義の誤り", False)
    except ValueError:
        expect("現れない場合は、定義の誤り", True)

    class Result:
        def __init__(self, code, out):
            self.returncode, self.stdout, self.stderr = code, out, ""

    expect("成功を分類", classify(Result(0, "ok"))[0] == "passed")
    expect("失敗したテストを分類", classify(Result(1, "--- FAIL: TestX (0.00s)\nFAIL"))[0:2] == ("killed", ["TestX"]))
    expect("タイムアウトを検出に分類", classify(Result(1, "panic: test timed out after 60s\nFAIL"))[0] == "killed")
    expect("ビルドの失敗を分類", classify(Result(1, "FAIL\tpkg [build failed]"))[0] == "build-failed")
    expect("コンパイルエラーを分類", classify(Result(1, "# github.com/x/y\ninternal/a.go:3:4: undefined: z\nFAIL"))[0] == "build-failed")

    ids = [m["id"] for m in mutants()]
    expect("変異の ID が重複しない", len(ids) == len(set(ids)))
    expect("変異が 50 件以上ある", len(ids) >= 50)
    expect("すべての変異が、置き換えを持つ", all(m["old"] != m["new"] and m["old"] for m in mutants()))
    expect(
        "削除系の語を、変異の定義に含めない",
        not any(re.search(r"(?<![A-Za-z0-9_])(" + "r" + "m|un" + "link|sh" + "red)(?![A-Za-z0-9_])", m["old"] + m["new"]) for m in mutants()),
    )

    if failures:
        print("自己検査に失敗しました:")
        for name in failures:
            print("  - " + name)
        return 1
    print("自己検査: すべて成功しました")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
