# test/pr51

PR #51（issue #21「中継: WebSocket の受け口（Gin）と結線・設定・停止処理・結合テスト」）のテストです。対象は開発サーバー（`scripts/dc.sh` 経由の docker compose の relay コンテナ）です。実際の YouTube・実際のアプリケーションには接続しません（結合テストは、疑似のアプリケーションと、疑似の RTMP の受け口。TLS・自己署名）。実物どうしの結合は #30 で行います。

実装担当が書いた Go のテスト（`src/relay/internal/wsapi`・`internal/server`・`internal/config`・`main_test.go`）を 1 回で実行し、そのうえで、受け入れ条件がすべて検査されていること（空振りでないこと）と、開発サーバーの `GET /health`・`GET /ws` が、実際の WebSocket の接続で期待どおりに答えることを確かめます。

```bash
scripts/setup_dev_env.sh   # .env を生成します（済んでいれば何も変わりません）
test/pr51/run_all.sh
```

| 手順 | 確かめること |
|---|---|
| relay コンテナの再起動 | 現在のソースで、開発用のバイナリをビルドし直して起動できる（healthy になる） |
| `go build ./...` | 中継の全パッケージがビルドできる |
| `scripts/test_relay.sh`（wsapi・server・config・main） | gofmt の差分なし・`go vet`・`go test`（時計・アプリケーション・RTMP の受け口は疑似。実時間は、ごく短い待ちだけ） |
| `-race -count=1` | 競合検出つき（CI と同じ形。キャッシュを使わない）で警告が無い |
| `-race -count=3 -cpu 1,4` | 繰り返しと並列度の変更でも、結果が変わらない（時計の注入による決定性。ゴルーチンが残らない） |
| `scripts/test_relay.sh -race -count=1`（全体） | #18（Domain Core）・#19（FLV・RTMPS）・#20（取り込みセッション・内部通信）など、既存の部品が壊れていない |
| `check_acceptance_tests.py` | 受け入れ条件に対応するテスト（名前）が、すべて実行され、成功している（名前の変更・スキップで、黙って検査されなくならない） |
| `go mod verify`・`go mod tidy -diff` | 依存が整っている（`gorilla/websocket` v1.5.3 と、`logrus` の直接参照への移動だけ） |
| `docker build --target production src/relay` | 本番用イメージがビルドできる |
| `dev_server_check.py` | 開発サーバーに、実際の WebSocket で接続し、下の表のとおりに答える |
| `scan_sources.py --self-test` / `scan_sources.py` | 走査器が、違反を見逃さず、誤検知しない。対象のファイルがそろっている。絵文字・削除系の記述が無い。`go.mod` が `gorilla/websocket` v1.5.3 を固定している。`src/relay` の変更が、範囲の中だけ |

終了コード 0 が成功です（1 = 失敗がある、2 = `.env` が無いなど前提の不足）。

## 開発サーバーの確認（`dev_server_check.py`）

標準ライブラリだけの小さな WebSocket のクライアントで、`ws://localhost:3002/ws` へ接続します。値は明らかなダミーで、実際のアプリケーション・YouTube には何も起こりません。

| 確認 | 期待 |
|---|---|
| `GET /health` | 200 と `{"status":"ok"}`（#1 のまま） |
| WebSocket ではない `GET /ws`、`POST /ws` | 400、404 |
| `Origin: http://evil.example` からの接続 | 受け付ける（Cookie を使わず、接続チケットで認可するため。`handler.go` の `CheckOrigin` のコメント） |
| 形式の不正なチケット（空白を含む）の hello | 致命通知 `invalid_ticket` のあと、通常の切断（1000） |
| 存在しないチケットの hello | 致命通知 `invalid_ticket`（アプリケーションが照合できる場合）、または `internal_error`（アプリケーションの内部通信の口が、まだ無い場合）のあと、通常の切断 |
| テキストのメッセージ | 致命通知 `protocol_violation` のあと、通常の切断 |
| 2 MiB を 1 バイト超えるメッセージ | 致命通知 `message_too_large` が先に届き、そのあと Close コード 1009 |
| 壊れたフレームと、照合前のメッセージ | 破棄されて、接続が続く |
| hello を送らずに 10 秒 | 致命通知 `hello_timeout` のあと、通常の切断（実時間で 10 秒待つ） |

## 受け入れ条件との対応

| 受け入れ条件（issue #21） | 確かめるテスト（主なもの） |
|---|---|
| `gorilla/websocket` でアップグレード。Cookie に依存しない。`CheckOrigin` を明示し、理由をコメントに残す | `TestAnyOriginMayConnect`・`TestARequestThatIsNotAWebSocketUpgradeIsRefused`・`TestCheckOriginIsExplicitAndExplained`・`TestTheUpgraderIsBuiltInOnePlaceWithCheckOrigin` |
| 接続から 10 秒以内に hello が無い接続は切断 | `TestNoHelloForTenSecondsClosesTheConnection`・`TestAHelloInTimeCancelsTheHelloTimeout` |
| 1 メッセージ 2,097,152 バイト。`SetReadLimit` を使わず、自前で数え、`fatal(message_too_large)` を先に送ってから Close 1009 | `TestReadMessageReadsUpToTheLimit`・`TestTheMessageSizeLimitIsInclusive`・`TestAnOversizeMessageIsReportedBeforeItIsFullyReceivedAndTheFatalComesFirst`・`TestAMessageAtTheLimitIsAcceptedAndOneByteOverIsFatalWithCloseCode1009`・`TestAnOversizeMessageThatNeverEndsIsCutAsSoonAsTheLimitIsPassed`・`TestWsapiSourcesFollowTheRules` |
| バイナリのみ受理。テキストは `protocol_violation` | `TestATextMessageIsReportedAndNeverHandedOverAsData`・`TestATextFrameIsAProtocolViolation` |
| 受信したフレームを復号して `IngestSession` へ。逸脱するメッセージは破棄して数える | `TestBinaryMessagesReachTheSessionUnchangedAndInOrder`・`TestBrokenFramesAreDiscardedAndTheConnectionContinues`・`TestMessagesBeforeHelloAreDiscardedAndTheConnectionContinues` |
| 送信：単一のゴルーチンに直列化・キューの上限・`ack` などを優先・ping／pong で死活を確認 | `TestSendWritesBinaryMessagesInOrder`・`TestAckAndThrottleAreSentAheadOfQueuedMessagesAndOnlyTheLatestIsKept`・`TestTheQueueOfImportantMessagesIsBounded`・`TestAckAndThrottleNeverGrowTheQueue`・`TestAStalledWriteDropsTheConnectionAfterTheWriteTimeout`・`TestPingsAreSentAtTheInterval`・`TestASilentPeerIsClosedAfterTheIdleTimeout`・`TestPongsKeepAnIdleConnectionAlive` |
| 接続が閉じたとき、セッションへ通知する | `TestACleanCloseByThePeerNotifiesTheSessionOnce`・`TestAnAbruptCloseByThePeerNotifiesTheSessionOnce` |
| 接続ごとのゴルーチン・メモリの上限 | `TestTheNumberOfConnectionsIsLimited`・`TestTwentyConcurrentBroadcastsAtThirtyFramesPerSecondScaleLinearly` |
| `GET /health`・`PORT`・環境変数の読み込み（欠けていれば起動を失敗。名前のみ）・開発用の許可 | `TestHealthReturns200WithJSON`・`TestLoadReadsEveryVariable`・`TestLoadFailsWhenARequiredVariableIsMissing`・`TestStartupFailureNamesTheMissingVariablesButNeverShowsValues`・`TestDestinationPolicyFollowsTheEnvironment` |
| 正常停止（SIGTERM・SIGINT）：新しい接続を受け付けず、既存のセッションを閉じる（RTMPS は送り切る）、`session_ended`、猶予を超えたら中止、ゴルーチンが残らない | `TestRunStopsOnSIGTERMAndSIGINT`・`TestServeStopsGracefullyWhenTheContextIsCancelled`・`TestShutdownClosesEverySessionGracefullyAndFlushesTheEvents`・`TestShutdownAbortsAStalledDrainWhenTheGraceIsExceeded` |
| ログ：クエリ・ヘッダに秘密が無い。チケット・配信キー・取り込み先をログ・パニックの出力に出さない | `TestAccessLogOmitsQueryStringAndClientIP`・`TestAccessLogOfTheWebSocketPathOmitsQueryAndClientIP`・`TestRecoveryLogsThePanicTypeWithoutTheValueOrRequestDetails`・`TestAPanicInTheSessionClosesOnlyThatConnectionAndIsNotLoggedWithItsValue`・`TestRedirectThirdPartyLogsRoutesLogrusIntoSlogAndSilencesItsOwnOutput`（結合テストの末尾でも、全出力に秘密値が無いことを確かめる） |
| 結合：hello → accepted → probe → probe_result → start → status → video・audio → 受け口のタグ（0 起点の時刻）→ ack・心拍 → end → 切断・事象 | `TestAFullBroadcastFromHelloToEnd` |
| 結合・異常系：無効なチケット／hello なし 10 秒／2 MB 超／テキスト／壊れたフレーム／世代の古い接続の排除／同一アカウントの別の配信／受信ビットレートの超過／準備の失敗 | `TestAnUnknownTicketIsFatalAndTheConnectionIsClosed`・`TestNoHelloForTenSecondsClosesTheConnection`・`TestAMessageAtTheLimitIsAcceptedAndOneByteOverIsFatalWithCloseCode1009`・`TestATextFrameIsAProtocolViolation`・`TestBrokenFramesAreDiscardedAndTheConnectionContinues`・`TestAnOlderConnectionIsClosedAtOnceWhenANewerEpochConnects`・`TestANewBroadcastOfTheSameAccountClosesTheOldOne`・`TestExcessiveIngressDisconnectsAndTheBroadcastCannotReconnect`・`TestPreparationFailuresEndTheBroadcastWithTheirReason` |
| 結合：心拍の応答喪失は 60 秒で止まり、59 秒では続く | `TestHeartbeatLossStopsTheBroadcastAtSixtySecondsButNotBefore` |
| 結合：アプリケーションの不達の間のメディアの継続と事象の再送 | `TestMediaContinuesAndEventsAreResentWhileTheApplicationIsUnreachable` |
| 結合：ブラウザの切断 → 復帰（時刻が連続） | `TestBrowserDisconnectAndResumeKeepTheOutputTimelineContinuous`・`TestAResumeHelloToARestartedRelayRebuildsTheSession` |
| 負荷：同時 20 接続（30 fps）で、ゴルーチン・メモリが線形、`-race` に警告が無い | `TestTwentyConcurrentBroadcastsAtThirtyFramesPerSecondScaleLinearly` |

Go の構文木による規則（実時計を使わない・接続に実時間の期限を設定しない・`SetReadLimit` を使わない・グローバル変数を持たない・日本語を直書きしない・ログに秘密値と受信した内容とエラーの文言を渡さない・`rtmps.NewPolicy` を本番のコードに置かない・`InsecureSkipVerify` を書かない）は、`src/relay/internal/wsapi/rules_test.go` が、`internal/wsapi`・`internal/server`・`internal/config`・`main.go` について検査します。

## 確かめられないこと

- 実際の YouTube の取り込み口・実際のアプリケーション（Rails の内部通信の口）・実際のブラウザの WebSocket。結合テストの相手は疑似で、実物どうしは #30 で確かめる。開発サーバーの確認で「存在しないチケット」が `internal_error` になるのは、アプリケーションの内部通信の口（#14）が、まだ無いため。
- Railway のプロキシ越しの WebSocket（TLS の終端・アイドルの切断）。最初のデプロイの後に確かめる。
- 実時間のタイマー（`session.SystemClock`）での長時間の動作。結合テストは、時計を注入して決定的に検査している。

## ユーザー（ブラウザ）から見える変更

ありません。中継が WebSocket（`GET /ws`）を受け付ける状態になります。ブラウザからの接続は #28・#29 以降です。ブラウザで `http://localhost:3002/health` が `{"status":"ok"}` のままであることを確かめてください。
