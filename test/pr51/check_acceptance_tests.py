#!/usr/bin/env python3
"""issue #21 の受け入れ条件に対応するテストが、すべて実行され、成功したことを確かめる（読み取りのみ）。

使い方: python3 -I check_acceptance_tests.py <go test -v ./internal/wsapi/... ./internal/server/... ./internal/config/... . の出力ファイル>

go test -v の出力を、パッケージごとに分け（パッケージの結果の行 "ok <パス>" が区切り）、受け入れ条件に対応するテストの名前が、
成功の行（--- PASS: <名前>）として存在することを確かめる。失敗・スキップの行があれば失敗にする。
テストの名前の変更・削除・スキップで、受け入れ条件が黙って検査されなくなることを防ぐ。
"""
import re
import sys

# パッケージ（src/relay からの相対パス。"." は main） -> 受け入れ条件に対応する、トップレベルのテストの名前
REQUIRED = {
    "internal/config": [
        # 設定：環境変数から読み込む。欠けていれば起動を失敗させる（名前だけを出す。値は出さない）
        "TestLoadReadsEveryVariable",
        "TestLoadUsesTheDefaultPortWhenPortIsNotSet",
        "TestLoadFailsWhenARequiredVariableIsMissing",
        "TestLoadRejectsAnUnknownEnvironmentAndAnInvalidPort",
        "TestFormattingTheConfigNeverExposesTheSecret",
        "TestVariableNamesMatchRequirements",
        "TestDefaultPortIs3002",
        # HTTP サーバーの制限（要求ヘッダの読み取り・keep-alive の無通信・ヘッダの大きさ）
        "TestHTTPServerLimits",
    ],
    "internal/server": [
        # ルーター・ログ・パニックの記録
        "TestHealthReturns200WithJSON",
        "TestOnlyHealthIsRoutedWithoutAWebSocketHandler",
        "TestTheWebSocketHandlerIsMountedOnGetWs",
        "TestAccessLogOmitsQueryStringAndClientIP",
        "TestAccessLogOfTheWebSocketPathOmitsQueryAndClientIP",
        "TestRecoveryLogsThePanicTypeWithoutTheValueOrRequestDetails",
        "TestRecoveryKeepsTheMessageOfRuntimeErrors",
        "TestRecoveryLogQuotesTheRequestPath",
        # 記録の出力先は必須（nil を、捨てる出力先へ差し替えない）
        "TestNewRouterRequiresTheLogOutputs",
        "TestRedirectThirdPartyLogsRequiresALoggerAndChangesNothingWithoutOne",
        # go-rtmp の記録（#19 のレビューの申し送り）
        "TestRedirectThirdPartyLogsRoutesLogrusIntoSlogAndSilencesItsOwnOutput",
        "TestRoutedThirdPartyInfoLinesAreBelowTheProductionLevel",
        "TestRoutedThirdPartyMessagesAreTruncated",
        # 結線・送出先の許可・正常停止
        "TestNewAppRejectsAnInvalidInternalConfigWithoutEchoingIt",
        "TestNewAppRequiresTheLogOutputsAndNeverSubstitutesThem",
        "TestAMissingLogOutputIsReportedBeforeAnInvalidConfig",
        "TestNewAppUsesTheProductionDefaultsForTheClockTheWaiterAndTheHTTPClient",
        "TestDestinationPolicyFollowsTheEnvironment",
        "TestNewAppRefusesAPolicyOverrideInProduction",
        "TestSessionsContextKeepsAReserveForTheEventFlush",
        "TestServeAnswersHealthAndStopsWhenTheContextIsDone",
        "TestServeReturnsAnErrorWhenTheListenerIsBroken",
        "TestShutdownCanBeCalledTwiceAndRefusesNewWebSocketsAtOnce",
        # HTTP サーバーの制限（Serve が作るサーバーで確かめる）
        "TestServeBuildsTheHTTPServerWithTheConfiguredLimits",
        "TestServeRefusesRequestHeadersLargerThanTheLimit",
        "TestAWebSocketUpgradeWorksThroughTheServedHTTPServer",
        "TestTheAppFormatsWithoutAnySecretOrAddress",
    ],
    ".": [
        # 起動：設定の読み込み・失敗・SIGTERM と SIGINT での正常停止
        "TestNewApp",
        "TestNewAppRequiresTheOutputsAndNeverSubstitutesThem",
        "TestStartupFailureNamesTheMissingVariablesButNeverShowsValues",
        "TestStartupFailureOfAnInvalidSecretNeverShowsTheValue",
        "TestTheAppServesHealthAndStopsGracefullyOnCancel",
        "TestRunStopsOnSIGTERMAndSIGINT",
        "TestRunFailsWhenThePortIsInUse",
        "TestEnvironmentVariableNamesAreTheOnesInRequirements",
    ],
    "internal/wsapi": [
        # WebSocket（GET /ws）：切り替え・Origin・バイナリのみ・大きさの上限（自前で数える）・破棄
        "TestAnyOriginMayConnect",
        "TestARequestThatIsNotAWebSocketUpgradeIsRefused",
        "TestOnlyGetIsServed",
        "TestBinaryMessagesReachTheSessionUnchangedAndInOrder",
        "TestEachMessageIsHandedOverInItsOwnBuffer",
        "TestTheMessageSizeLimitIsInclusive",
        "TestAnOversizeMessageIsReportedBeforeItIsFullyReceivedAndTheFatalComesFirst",
        "TestATextMessageIsReportedAndNeverHandedOverAsData",
        "TestMessagesAfterTheLinkStartedClosingAreNotHandedOver",
        "TestReadMessageReadsUpToTheLimit",
        "TestReadMessageReportsReadErrors",
        "TestReadMessageDoesNotAllocateTheLimitUpFront",
        "TestReadMessageKeepsTheDataAcrossTheGrowthSteps",
        "TestReadMessageGrowsStraightToTheLimitInTheLastStep",
        # 送信：直列化・上限・優先・ping／pong・閉じ方
        "TestSendWritesBinaryMessagesInOrder",
        "TestSendCopiesTheMessage",
        "TestAckAndThrottleAreSentAheadOfQueuedMessagesAndOnlyTheLatestIsKept",
        "TestAckAndThrottleNeverGrowTheQueue",
        "TestTheQueueOfImportantMessagesIsBounded",
        "TestFatalIsWrittenBeforeTheCloseFrameAndTheWriteSideIsShutAfterwards",
        "TestCloseIsIdempotentAndOnlyTheFirstCodeIsSent",
        "TestSendAfterCloseFails",
        "TestPendingAckAndThrottleAreDroppedWhenClosing",
        "TestTheLingerTimeoutClosesTheSocketWhenThePeerDoesNotFinishTheHandshake",
        "TestAStalledWriteDropsTheConnectionAfterTheWriteTimeout",
        "TestPingsAreSentAtTheInterval",
        "TestASilentPeerIsDroppedWhenTheIdleTimeoutPasses",
        "TestInboundTrafficKeepsTheLinkAlive",
        "TestPongsKeepAnIdleConnectionAlive",
        "TestASilentPeerIsClosedAfterTheIdleTimeout",
        "TestPingAndIdleDropWorkWithTheRealClock",  # 実時間の時計（SystemClock）でも、タイマーが動く
        "TestAWriteFailureDropsTheLink",
        "TestFinishStopsTheWriterTheTimersAndTheSocket",
        "TestSendAndCloseAreSafeToCallConcurrently",
        # 接続の終わり・接続数の上限・停止の手順・panic
        "TestACleanCloseByThePeerNotifiesTheSessionOnce",
        "TestAnAbruptCloseByThePeerNotifiesTheSessionOnce",
        "TestMessagesFromTheSessionReachThePeerInOrder",
        "TestTheNumberOfConnectionsIsLimited",
        "TestAcceptedCountsEveryConnectionThatReachedTheSessionRegistry",
        "TestNewConnectionsAreRefusedWhileDrainingAndExistingOnesKeepWorking",
        "TestARefusedSessionConnectionIsClosedAsGoingAway",
        "TestWaitReturnsOnceEveryConnectionHasEnded",
        "TestWaitClosesTheConnectionsByForceWhenTheContextExpires",
        "TestAPanicInTheSessionClosesOnlyThatConnectionAndIsNotLoggedWithItsValue",
        "TestAPanicInTheWriterIsContainedAndNotLoggedWithItsValue",
        "TestFormattingTheLinkShowsNoMessages",
        "TestOnlyAckAndThrottleKeepJustTheLatest",
        "TestTheHandlerShowsNoDetailsWhenFormatted",
        "TestOptionsDefaultsFollowTheContract",
        "TestOptionsRejectInvalidValues",
        "TestNewHandlerRequiresItsDependencies",
        # 結合：正常な流れ
        "TestAFullBroadcastFromHelloToEnd",
        "TestTheAccessLogRecords200ForAnEstablishedWebSocketAndTheRefusalStatusOtherwise",
        "TestAResumeHelloToARestartedRelayRebuildsTheSession",
        "TestAStopCommandFromTheApplicationEndsTheBroadcast",
        "TestNoticesFromTheApplicationAreForwardedToTheBrowser",
        # 結合：異常系
        "TestAnUnknownTicketIsFatalAndTheConnectionIsClosed",
        "TestATicketOfAnEndedBroadcastIsRefused",
        "TestAnUnreachableApplicationAtVerificationIsAnInternalErrorAndTheTicketIsNotConsumed",
        "TestNoHelloForTenSecondsClosesTheConnection",
        "TestAHelloInTimeCancelsTheHelloTimeout",
        "TestMessagesBeforeHelloAreDiscardedAndTheConnectionContinues",
        "TestASecondHelloIsAProtocolViolation",
        "TestATextFrameIsAProtocolViolation",
        "TestAMessageAtTheLimitIsAcceptedAndOneByteOverIsFatalWithCloseCode1009",
        "TestAnOversizeMessageThatNeverEndsIsCutAsSoonAsTheLimitIsPassed",
        "TestBrokenFramesAreDiscardedAndTheConnectionContinues",
        "TestAnOlderConnectionIsClosedAtOnceWhenANewerEpochConnects",
        "TestANewBroadcastOfTheSameAccountClosesTheOldOne",
        "TestABroadcastOfAnotherAccountIsNotClosed",
        "TestExcessiveIngressDisconnectsAndTheBroadcastCannotReconnect",
        "TestPreparationFailuresEndTheBroadcastWithTheirReason",
        "TestProvisionWithAStaleEpochClosesWithStaleEpoch",
        "TestHeartbeatLossStopsTheBroadcastAtSixtySecondsButNotBefore",  # 60 秒で止まる・59 秒では続く
        "TestMediaContinuesAndEventsAreResentWhileTheApplicationIsUnreachable",
        "TestBrowserDisconnectAndResumeKeepTheOutputTimelineContinuous",
        # 結合：負荷と停止
        "TestTwentyConcurrentBroadcastsAtThirtyFramesPerSecondScaleLinearly",
        "TestShutdownClosesEverySessionGracefullyAndFlushesTheEvents",
        "TestShutdownAbortsAStalledDrainWhenTheGraceIsExceeded",
        "TestServeStopsGracefullyWhenTheContextIsCancelled",
        "TestShutdownWithoutAnySessionIsImmediate",
        # 走査器と、ソースの規則
        "TestRulesScannerFindsViolations",
        "TestWsapiSourcesFollowTheRules",
        "TestServerSourcesFollowTheRules",
        "TestConfigSourcesFollowTheRules",
        "TestMainSourceFollowsTheRules",
        "TestCheckOriginIsExplicitAndExplained",
        "TestTheUpgraderIsBuiltInOnePlaceWithCheckOrigin",
    ],
}

if len(sys.argv) != 2:
    print("使い方: check_acceptance_tests.py <go test -v の出力>")
    sys.exit(2)

with open(sys.argv[1], encoding="utf-8") as handle:
    lines = handle.read().split("\n")


def package_key(path):
    """'ok <import path>' の import path を、REQUIRED のキーにする（モジュールの根は "."）。"""
    if "/relay/" in path:
        return path.split("/relay/", 1)[-1]
    if path.endswith("/relay"):
        return "."
    return path


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
        key = package_key(done.group(2))
        per_package[key] = current
        current = set()
        if done.group(1) == "FAIL":
            problems.append(f"パッケージが失敗しました: {key}")

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
