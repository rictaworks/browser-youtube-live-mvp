# test/pr49

PR #49（issue #20「中継: 取り込みセッション・セッション台帳・アプリケーションとの内部通信クライアント」）のテストです。対象は開発サーバー（`scripts/dc.sh` 経由の docker compose の relay コンテナ）です。実際の YouTube・アプリケーション・ブラウザには接続しません（境界は疑似の実装。実物の結線は #21、結合は #30）。

実装担当が書いた Go のテスト（`src/relay/internal/session/*_test.go`・`src/relay/internal/backend/*_test.go`）を、1 回で実行し、そのうえで、受け入れ条件がすべて検査されていること（空振りでないこと）を確かめます。

```bash
scripts/setup_dev_env.sh   # .env を生成します（済んでいれば何も変わりません）
test/pr49/run_all.sh
```

| 手順 | 確かめること |
|---|---|
| `go build ./...` | 中継の全パッケージがビルドできる |
| `scripts/test_relay.sh ./internal/session/... ./internal/backend/...` | gofmt の差分なし・`go vet`・`go test`（時計・アプリケーション・RTMPS・ブラウザの接続は疑似。実時間を待たない） |
| `-race -count=1` | 競合検出つき（CI と同じ形。キャッシュを使わない） |
| `-race -count=3 -cpu 1,4` | 繰り返しと並列度の変更でも、結果が変わらない（時計の注入による決定性。ゴルーチンが残らない） |
| `scripts/test_relay.sh -race -count=1`（全体） | #18（Domain Core）・#19（FLV 多重化・RTMPS 送出）など、既存の部品が壊れていない |
| `check_acceptance_tests.py` | 受け入れ条件に対応するテスト（名前）が、すべて実行され、成功している（名前の変更・スキップで、黙って検査されなくならない） |
| `scan_sources.py --self-test` | 走査器そのものが、違反を見逃さず、違反でないものを誤検知しない（変更の範囲の判定は、一時ディレクトリの確認用リポジトリで、未コミットの変更を数えないことまで確かめる） |
| `scan_sources.py` | 対象のファイルがそろっている。絵文字・削除系の記述が無い。PR のブランチのコミット済みの内容を比較の基準（既定 `origin/main`）と比べて、`src/relay` の変更が `internal/session`・`internal/backend`・`go.mod`・`go.sum` の中だけ（`internal/flv`・`internal/rtmps`・`core` は参照のみ） |

終了コード 0 が成功です（1 = 失敗がある、2 = `.env` が無い、比較の基準を解決できないなど前提の不足）。

変更の範囲の検査は、作業ツリーの未コミットの変更（他の issue の作業）を見ません。比較の基準は `origin/main` で、古いときは `git fetch origin main` で取得してください。別の基準を使うときは、環境変数 `PR_BASE_REF` で指定します（例：`PR_BASE_REF=origin/main test/pr49/run_all.sh`）。基準を解決できないときは、別の基準へ切り替えずに、エラーで止まります。

Go の構文木による規則（実時計を使わない・入出力に触れない・グローバル変数を持たない・日本語を直書きしない・ログに秘密値とエラーの文言を渡さない・`rtmps.NewPolicy` を本番のコードに置かない・`reveal()` の使用箇所）は、`src/relay/internal/session/rules_test.go` が、`internal/session` と `internal/backend` の両方について検査します。

## 受け入れ条件との対応

| 受け入れ条件（issue #20） | 確かめるテスト（主なもの） |
|---|---|
| 内部通信クライアント：`Verify`・`Provision`・`Heartbeat`・`Event`、ヘッダ `X-Relay-Secret`、期限（心拍・事象 5 秒、準備 90 秒）、リダイレクトを追わない、型付きの結果とエラー | `TestVerifySendsTheContractRequestAndParsesTheResult`・`TestProvisionSendsTheContractRequestAndParsesTheResult`・`TestHeartbeatSendsTheContractRequest`・`TestEventSendsTheContractRequest`・`TestDefaultTimeoutsFollowTheIssue`・`TestEachCallHasItsOwnDeadline`・`TestRedirectsAreNotFollowed`・`TestCallFailuresAreTyped` |
| 事象は保持して再送する（上限あり・指数的な待機・順序を保つ） | `TestEventsAreSentInOrderOneAtATime`・`TestEventsAreHeldAndResentWithExponentialBackoff`・`TestTheQueueIsBoundedAndDropsTheOldest`・`TestEventsAreHeldWhileTheApplicationIsUnreachableAndDeliveredInOrderAfterwards` |
| 秘密値・チケット・配信キー・取り込み先を、ログ・エラー・`%v` に出さない | `TestSensitiveValuesAreRedactedWhenFormatted`・`TestNoSecretIsLoggedOverAWholeBroadcast`・`TestFormattingTheSessionStructuresNeverExposesSecrets`・`TestErrorTextIsFixedVocabularyAndDoesNotEchoTheBody` |
| 状態（接続通知待ち 10 秒・照合済み・計測・開始・送出・中断・終了）、照合前のメッセージの破棄、hello の 2 回目は `protocol_violation` | `TestHelloTimesOutAfterTenSeconds`・`TestMessagesBeforeHelloAreDiscarded`・`TestMessagesDuringVerificationAreDiscarded`・`TestSecondHelloIsAProtocolViolation` |
| `OnHello`：照合・`accepted`・無効なチケットは `fatal(invalid_ticket)` | `TestAcceptedAfterAValidHello`・`TestInvalidTicketIsFatal`・`TestVerificationFailuresAreFatalWithTheirCodes` |
| `OnProbe`：最初の計測データから 3 秒後に `probe_result` | `TestProbeResultIsSentThreeSecondsAfterTheFirstProbe`・`TestProbeCountsTheWholeMessageIncludingTheHeader` |
| `OnStart`：準備・`status(awaiting_media)`・RTMPS の接続・設定のタグ・`publish_started`・`status(confirming)`・準備の失敗 | `TestStartProvisionsConnectsAndWritesTheDecoderConfigurationFirst`・`TestProvisioningFailuresEndTheBroadcast`・`TestProvisioningDoesNotBlockTheSession` |
| publish の失敗の検知（`ErrPublishRejected` → `publish_failed`） | `TestPublishRejectedIsAFailureOfTheConnectionNotTheEndOfTheBroadcast`・`TestPublishRejectedAfterTheAnnouncementInterruptsAndReconnects` |
| `OnMedia`：ゲート・`TimeGuard`・`IngressPolicer`・`MediaWatchdog`・`TimestampRebaser`・`Muxer`・`Publisher`、受信量の超過の切断と再接続の拒否 | `TestMediaIsForwardedWithoutReencodingAndRebasedToZero`・`TestMediaBeforeTheConfirmingStatusIsDiscarded`・`TestTimeRegressionIsDiscardedPerKind`・`TestExcessiveIngressWhileStreamingDisconnectsAbortsAndBans`・`TestABroadcastDisconnectedForExcessiveIngressIsRefusedUntilTheBanExpires` |
| 受領応答 0.5 秒・抑制指示 1.5 秒・上限 3 秒で送出失敗 | `TestAckIsSentEveryHalfSecondOnceBothKindsHaveArrived`・`TestThrottleIsSentWhenThePendingMediaExceedsOneAndAHalfSeconds`・`TestBufferLimitIsAPublishFailureAndTheConnectionIsReestablished` |
| `OnReport`・`OnEnd`、終了時に配信キーとバッファを破棄 | `TestBrowserReportIsCarriedByTheNextHeartbeatWithoutLosingEvents`・`TestEndDrainsThePublisherAndDiscardsTheKeyAndTheBuffers`・`TestEverythingTheSessionHeldIsDroppedWhenItEnds` |
| 心拍：2 秒・統計・停止の指示・通知の転送・`stale_epoch`・60 秒の喪失（59 秒では継続） | `TestHeartbeatIsSentEveryTwoSeconds`・`TestHeartbeatStopWithAnEndReasonStopsGracefully`・`TestHeartbeatNoticesAreForwardedAsStatus`・`TestHeartbeatStopForAStaleEpochAbortsAtOnce`・`TestSessionStopsWhenNoHeartbeatIsAnsweredForSixtySeconds` |
| 中断と復帰：ブラウザの切断 → RTMPS の保持 → 復帰（時刻が連続・映像と音声の補正が同一）／RTMPS の切断 → 再接続 → キーフレーム待ち／無通信 5 秒／中断の上限 75 秒／中継の再起動後 | `TestResumeAfterABrowserDisconnectContinuesTheTimelineWithTheSameCorrection`・`TestResumeWhenTheBrowserClockRestartsFromZero`・`TestRTMPSDisconnectInterruptsReconnectsAndWaitsForAKeyframe`・`TestFramesMissingForFiveSecondsInterruptTheSession`・`TestSessionClosesWhenTheInterruptionLimitPasses`・`TestARestartedRelayRebuildsTheSessionFromAResumeHello` |
| `Decode` → `TimeGuard` → `Rebaser` の結合（復帰・巻き戻りの復帰） | `TestOutputTimestampsNeverGoBackwardAcrossResumesAndClockRestarts`・`TestAudioAndVideoOfTheSameInstantStayInSyncAcrossAResume` |
| セッション台帳：`Register`・`Find`・`Count`・`CloseOthers`・`Remove`・`SwapSource`・ゴルーチン安全 | `TestRegisterFindCountRemove`・`TestCloseOthersClosesOnlyTheOtherSessionsOfTheAccount`・`TestAHelloOfANewBroadcastClosesTheAccountsOldSessionBeforeAccepting`・`TestANewerConnectionClosesTheOlderOneAtOnce`・`TestRegistryIsSafeForConcurrentUse` |
| ゴルーチンのリークが無い・ログに秘密値が出ない | 全テストの終了時の検査（`harness_test.go`）・`TestManySessionsRunIndependently`・`TestNoSecretIsLoggedOverAWholeBroadcast` |

## レビュー指摘（PR #49）への対応

| 指摘 | 確かめるテスト |
|---|---|
| R1：内部通信クライアント（`backend.Client`）が共有の秘密値を非公開の欄に持ち、`%+v`・`log.Printf`・`slog.Any` で出る | `TestFormattingTheClientNeverExposesTheSharedSecret`（値と `*Client`。`%v %+v %#v %s %q %x %d`・`Sprint`・`log`）・`TestTheClientPrintsOnlyAFixedText`・`TestTheClientDefinesEveryFormattingGuard`・`TestTheClientIsRedactedInStructuredLogs`（`slog` の Text・JSON）・`TestEncodingTheClientNeverExposesTheSharedSecret`・`TestStructsHoldingSecretsDefineFormatters`（機密を非公開の欄に持つ構造体が、整形のメソッドを持つ。ソースの走査）・`TestFormatterScannerFindsUnprotectedStructs` |
| R2：受信量の超過で切っている最中に、再接続の拒否が破れる | `TestAReconnectionWhileAnExcessiveSessionIsStillClosingIsRefused`（切断を止めた状態で hello を出し、`fatal(bitrate_exceeded)`）・`TestARetryAfterAClosingSessionChecksTheBanAgain`（待っている間に成立した禁止を、再試行で見直す） |
| R3：世代が決まる前の心拍が、世代 0 で送られ得る | `TestNoHeartbeatIsSentBeforeTheEpochIsKnown`・`TestEveryHeartbeatCarriesAPositiveEpoch`・`TestHeartbeatChecksItsArgumentsBeforeSending`（世代・連番が 1 未満なら、要求を送らず `ErrInvalidArgument`）・`TestHeartbeatAcceptsTheSmallestValidEpochAndSeq` |
| R7：本文の読み取りの失敗を捨てている。ログの出力先が nil だと黙って捨てる | `TestAResponseBodyThatCannotBeReadToTheEndIsUnavailable`・`TestCancellationWhileReadingTheBodyIsNotUnavailable`・`TestDependenciesAreRequired`（`Deps.Logger`）・`TestNewEventQueueChecksItsArguments`（ログの出力先） |
| R8：変更の範囲の検査が、作業ツリーの未コミットの変更に依存する | `scan_sources.py --self-test`（確認用リポジトリの 4 件） |

## 確かめられないこと

- 実際の YouTube の取り込み口・アプリケーション・WebSocket の接続（境界は疑似。#21 の結合テスト、#30 の結合で確かめる）。go-rtmp が YouTube のメッセージで止まらないか、無効または使用中のキーで YouTube が切断するか、`releaseStream`・`FCPublish` が無くても受理されるか、`onStatus` を待たずに送ったデータが受理されるかは、最初の実機で確かめる。
- 実時間のタイマー（`SystemClock`・`SystemWaiter`）の長い動作。ごく短い待機で、`Clock` の契約を満たすことだけを確かめている。

ユーザー（ブラウザ）から見える変更はありません（中継の内部部品で、起動経路にはまだ組み込まれていません。組み込みは #21）。
