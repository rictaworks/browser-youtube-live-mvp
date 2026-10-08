#!/usr/bin/env python3
"""issue #20 の受け入れ条件に対応するテストが、すべて実行され、成功したことを確かめる（読み取りのみ）。

使い方: python3 -I check_acceptance_tests.py <go test -v ./internal/session/... ./internal/backend/... の出力ファイル>

go test -v の出力を、パッケージごとに分け（パッケージの結果の行 "ok <パス>" が区切り）、受け入れ条件に対応するテストの名前が、
成功の行（--- PASS: <名前>）として存在することを確かめる。失敗・スキップの行があれば失敗にする。
テストの名前の変更・削除・スキップで、受け入れ条件が黙って検査されなくなることを防ぐ。
"""
import re
import sys

# パッケージ（src/relay からの相対パス） -> 受け入れ条件に対応する、トップレベルのテストの名前
REQUIRED = {
    "internal/backend": [
        # 内部通信クライアント：4 つの呼び出し・ヘッダ・期限・リダイレクト・型付きの結果とエラー
        "TestNewClientChecksTheConfig",
        "TestDefaultTimeoutsFollowTheIssue",  # 心拍・事象 5 秒、準備 90 秒
        "TestEachCallHasItsOwnDeadline",
        "TestVerifySendsTheContractRequestAndParsesTheResult",
        "TestProvisionSendsTheContractRequestAndParsesTheResult",
        "TestHeartbeatSendsTheContractRequest",
        "TestEventSendsTheContractRequest",
        "TestCallFailuresAreTyped",  # 404 ticket_invalid・409 broadcast_not_attachable・409 stale_epoch ほか
        "TestRedirectsAreNotFollowed",
        "TestRedirectsAreNotFollowedEvenWithACustomHTTPClient",
        "TestClientDoesNotUseEnvironmentProxies",
        "TestTransportFailureIsUnavailable",
        "TestTimeoutIsUnavailableAndKeepsTheDeadlineCause",
        "TestCallerCancellationIsNotUnavailable",
        "TestTheSecretTravelsOnlyInTheHeader",
        # レビュー R3：世代が決まる前の心拍（世代 0・連番 0）を、送らない
        "TestHeartbeatChecksItsArgumentsBeforeSending",
        "TestHeartbeatAcceptsTheSmallestValidEpochAndSeq",
        # レビュー R7：本文を最後まで読めなかった応答は、ErrUnavailable（読み取りの失敗を捨てない）。呼び出し側の取り消しは別
        "TestAResponseBodyThatCannotBeReadToTheEndIsUnavailable",
        "TestCancellationWhileReadingTheBodyIsNotUnavailable",
        # 事象は保持して再送する（上限あり・指数的な待機・順序を保つ）
        "TestEventsAreSentInOrderOneAtATime",
        "TestEventsAreHeldAndResentWithExponentialBackoff",
        "TestTheQueueIsBoundedAndDropsTheOldest",
        "TestEnqueueNeverBlocksEvenWhenTheApplicationIsStuck",
        "TestNotFoundDropsThatBroadcastsEventsOnly",
        "TestShutdownWaitsForTheQueueToDrain",
        "TestTheWorkerStopsWhenTheQueueIsEmpty",
        "TestNewEventQueueChecksItsArguments",  # レビュー R7：ログの出力先は必須（nil を拒否する）
        # 秘密値・チケット・配信キー・取り込み先を、ログ・エラー・%v に出さない
        "TestSensitiveValuesAreRedactedWhenFormatted",
        "TestSensitiveValuesAreRedactedInJSONAndText",
        "TestSensitiveValuesAreRedactedInStructuredLogs",
        "TestErrorTextIsFixedVocabularyAndDoesNotEchoTheBody",
        "TestQueueLogsDoNotContainErrorText",
        # レビュー R1：内部通信クライアント自身を、書式化しても共有の秘密値が出ない（値でもポインタでも・fmt・log・slog）
        "TestFormattingTheClientNeverExposesTheSharedSecret",
        "TestTheClientPrintsOnlyAFixedText",
        "TestTheClientDefinesEveryFormattingGuard",
        "TestTheClientIsRedactedInStructuredLogs",
        "TestEncodingTheClientNeverExposesTheSharedSecret",
    ],
    "internal/session": [
        # 接続：hello の期限・照合・照合前の破棄・プロトコル違反・大きさの上限
        "TestHelloTimesOutAfterTenSeconds",
        "TestInvalidTicketIsFatal",
        "TestVerificationFailuresAreFatalWithTheirCodes",
        "TestMessagesBeforeHelloAreDiscarded",
        "TestMessagesDuringVerificationAreDiscarded",
        "TestSecondHelloIsAProtocolViolation",
        "TestTextMessageIsAProtocolViolation",
        "TestOversizeMessageIsFatalAndClosesWith1009",
        "TestInvalidFramesAreDiscardedAndTheConnectionContinues",
        # 計測・準備・送出の開始・メディア・受領応答・抑制指示・停止
        "TestProbeResultIsSentThreeSecondsAfterTheFirstProbe",
        "TestAbnormalProbeVolumeIsTreatedAsExcessiveIngress",
        "TestStartProvisionsConnectsAndWritesTheDecoderConfigurationFirst",
        "TestProvisioningDoesNotBlockTheSession",
        "TestProvisioningFailuresEndTheBroadcast",
        "TestRejectedDestinationIsNotRetried",
        "TestRedialAttemptsAreCapped",
        "TestMediaIsForwardedWithoutReencodingAndRebasedToZero",
        "TestMediaBeforeTheConfirmingStatusIsDiscarded",
        "TestTimeRegressionIsDiscardedPerKind",
        "TestAckIsSentEveryHalfSecondOnceBothKindsHaveArrived",
        "TestThrottleIsSentWhenThePendingMediaExceedsOneAndAHalfSeconds",
        "TestEndDrainsThePublisherAndDiscardsTheKeyAndTheBuffers",
        # 受信量の超過による切断と再接続の拒否
        "TestExcessiveIngressWhileStreamingDisconnectsAbortsAndBans",
        "TestIngressExactlyAtTheLimitIsNotExcessive",
        "TestABroadcastDisconnectedForExcessiveIngressIsRefusedUntilTheBanExpires",
        # レビュー R2：閉じている最中（切断が終わらない間）の再接続も、待っている間に成立した禁止も、受け付けない
        "TestAReconnectionWhileAnExcessiveSessionIsStillClosingIsRefused",
        "TestARetryAfterAClosingSessionChecksTheBanAgain",
        # 心拍：2 秒・統計・出来事の保持・指示・通知・60 秒の喪失（59 秒では継続）
        "TestHeartbeatIsSentEveryTwoSeconds",
        "TestNoHeartbeatIsSentBeforeTheEpochIsKnown",  # レビュー R3：世代が決まる前は、心拍を送らない（連番も使わない）
        "TestEveryHeartbeatCarriesAPositiveEpoch",
        "TestHeartbeatCarriesThePublishingFlagAndTheSentBytes",
        "TestUnansweredHeartbeatIsResentIdenticallyAndEventsAreNotLost",
        "TestBrowserReportIsCarriedByTheNextHeartbeatWithoutLosingEvents",
        "TestHeartbeatNoticesAreForwardedAsStatus",
        "TestHeartbeatStopWithAnEndReasonStopsGracefully",
        "TestHeartbeatStopForAStaleEpochAbortsAtOnce",
        "TestSessionStopsWhenNoHeartbeatIsAnsweredForSixtySeconds",
        "TestEventsAreHeldWhileTheApplicationIsUnreachableAndDeliveredInOrderAfterwards",
        # 中断と復帰
        "TestBrowserDisconnectInterruptsAndKeepsTheRTMPSConnection",
        "TestResumeAfterABrowserDisconnectContinuesTheTimelineWithTheSameCorrection",
        "TestResumeWhenTheBrowserClockRestartsFromZero",
        "TestRTMPSDisconnectInterruptsReconnectsAndWaitsForAKeyframe",
        "TestBufferLimitIsAPublishFailureAndTheConnectionIsReestablished",
        "TestPublishRejectedIsAFailureOfTheConnectionNotTheEndOfTheBroadcast",
        "TestFramesMissingForFiveSecondsInterruptTheSession",
        "TestSessionClosesWhenTheInterruptionLimitPasses",
        "TestARestartedRelayRebuildsTheSessionFromAResumeHello",
        "TestRepeatedQuickRTMPSFailuresBackOffAndEventuallyGiveUp",
        "TestOutputTimestampsNeverGoBackwardAcrossResumesAndClockRestarts",  # Decode → TimeGuard → Rebaser の結合
        "TestAudioAndVideoOfTheSameInstantStayInSyncAcrossAResume",
        # 世代・台帳・同一アカウントの排他
        "TestANewerConnectionClosesTheOlderOneAtOnce",
        "TestAConnectionWithAnOlderEpochIsRefused",
        "TestConcurrentHellosForTheSameBroadcastKeepOnlyTheNewestEpoch",
        "TestRegisterFindCountRemove",
        "TestCloseOthersClosesOnlyTheOtherSessionsOfTheAccount",
        "TestAHelloOfANewBroadcastClosesTheAccountsOldSessionBeforeAccepting",
        "TestRegistryIsSafeForConcurrentUse",
        "TestShutdownClosesAllSessionsGracefully",
        # 並行・資源・機密
        "TestTheLoopDoesNotSpinWhileItCannotAct",
        "TestAPanicInThePublisherIsRecoveredAndClosesOnlyThatSession",
        "TestClosingWhileDialingAbortsTheConnectionThatCompletesLater",
        "TestManySessionsRunIndependently",
        "TestNoSecretIsLoggedOverAWholeBroadcast",
        "TestOrdinaryTrafficProducesNoPerMessageLogs",
        "TestFormattingTheSessionStructuresNeverExposesSecrets",
        "TestEverythingTheSessionHeldIsDroppedWhenItEnds",
        "TestTheFactoryRejectsDestinationsThatAreNotYouTubeIngest",
        "TestDependenciesAreRequired",  # レビュー R7：ログの出力先は必須（nil を拒否する）
        # 走査器と、ソースの規則
        "TestScannerFindsViolations",
        "TestSessionSourcesFollowTheRules",
        "TestBackendSourcesFollowTheRules",
        # レビュー R1：機密を非公開の欄に持つ構造体は、整形のメソッドを持つ（取り込みセッション・台帳・接続・内部通信クライアント）
        "TestStructsHoldingSecretsDefineFormatters",
        "TestFormatterScannerFindsUnprotectedStructs",
    ],
}

if len(sys.argv) != 2:
    print("使い方: check_acceptance_tests.py <go test -v の出力>")
    sys.exit(2)

with open(sys.argv[1], encoding="utf-8") as handle:
    lines = handle.read().split("\n")

problems = []
per_package = {}
current = set()
for line in lines:
    match = re.match(r"^--- (PASS|FAIL|SKIP): (\S+)", line)  # トップレベルのテスト（行頭から）
    if match:
        status, name = match.groups()
        if status == "PASS":
            current.add(name)
        else:
            problems.append(f"{'失敗' if status == 'FAIL' else 'スキップ'}したテスト: {name}")
        continue
    sub = re.match(r"^\s+--- (FAIL|SKIP): (\S+)", line)  # サブテストの失敗・スキップ
    if sub:
        problems.append(f"{'失敗' if sub.group(1) == 'FAIL' else 'スキップ'}したサブテスト: {sub.group(2)}")
        continue
    done = re.match(r"^(ok|FAIL)\s+(\S+)", line)
    if done:
        package = done.group(2).split("/relay/", 1)[-1]
        per_package[package] = current
        current = set()
        if done.group(1) == "FAIL":
            problems.append(f"パッケージが失敗しました: {package}")

total = 0
for package, names in REQUIRED.items():
    passed = per_package.get(package)
    if passed is None:
        problems.append(f"パッケージの結果がありません: {package}")
        continue
    for name in names:
        total += 1
        if name not in passed:
            problems.append(f"成功の行がありません: {package} の {name}")

print(f"受け入れ条件に対応するテスト: {total} 件（{len(REQUIRED)} パッケージ）を確かめました")
if problems:
    print("問題:")
    for item in problems:
        print("  - " + item)
    sys.exit(1)
print("問題ありません（すべて成功しています）")
