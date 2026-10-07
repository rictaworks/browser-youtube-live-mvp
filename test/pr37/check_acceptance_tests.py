#!/usr/bin/env python3
"""issue #18 の受け入れ条件に対応するテストが、すべて実行され、成功したことを確かめる（読み取りのみ）。

使い方: python3 -I check_acceptance_tests.py <go test -v ./core/... の出力ファイル>

go test -v の出力を、パッケージごとに分け（パッケージの結果の行 "ok <パス>" が区切り）、受け入れ条件に対応するテストの名前が、
成功の行（--- PASS: <名前>）として存在することを確かめる。失敗・スキップの行があれば失敗にする。
テストの名前の変更・削除・スキップで、受け入れ条件が黙って検査されなくなることを防ぐ。
"""
import re
import sys

# パッケージ（src/relay からの相対パス） -> 受け入れ条件に対応する、トップレベルのテストの名前
REQUIRED = {
    "core/frame": [
        "TestSharedVectorsValid",  # 共有ベクタ（有効）の全件
        "TestSharedVectorsInvalid",  # 共有ベクタ（無効）の全件
        "TestSharedVectorsCoverTheContract",  # 14 種の種別・7 種のエラーのすべてをベクタが持つ（空振りの防止）
        "TestEncodeMatchesSharedVectors",  # 符号化がベクタと一致
        "TestLocateContractsDirFailsWhenMissing",  # ベクタが見つからなければ失敗（黙ってスキップしない）
        "TestDecodeHeaderFieldSweeps",  # 種別・版・識別子・属性・時刻
        "TestDecodeTruncatedHeader",
        "TestDecodeLengthBoundaries",  # 2,097,152 バイトの境界・too_large と length_mismatch の順
        "TestDecodeDoesNotCopyOrModifyTheMessage",
        "TestDecodeAllocationIsIndependentOfDeclaredLength",  # 過大な確保をしない
        "TestEncode",
        "TestEncodeControl",
        "TestRoundTripRandomFrames",
        "TestErrorCodes",
        "TestBodyIsNeverExposedInErrorsOrStrings",  # 本文（接続チケット）をログへ出さない
        "TestDecodeMatchesTheOracleOnMutatedInputs",  # 参照実装との突き合わせ（固定のシード）
        "TestDecodeMatchesTheOracleAroundTheSizeLimit",
        "FuzzDecode",  # ファジング用の Fuzz 関数（シードの実行）
        "TestTimeGuardAdmit",  # 時刻の整合（逆行は破棄・前方への飛びは可・種別ごとに独立）
        "TestTimeGuardIgnoresControlFrames",
        "TestTimeGuardErrorDetail",
        "TestTimeGuardAdmitsARealisticInterleavedStream",
        "TestConcurrentUseOfIndependentInstances",
    ],
    "core/rebase": [
        "TestNominalFrameInterval",
        "TestRebase",  # 新しい接続で 0 起点・復帰（空白 10 秒・30 秒）・映像と音声に同一の補正量
        "TestRebaseErrors",
        "TestRebaseIsDeterministicAndInstancesAreIndependent",
        "TestRebaseProperties",  # ランダムな入力列（固定のシード）：単調・連続・相対差の保持
        "TestNoDriftOverTenHours",  # 差分を積み上げない（丸め誤差なし）
    ],
    "core/policer": [
        "TestLimitKbps",  # 720p は 9,000 kbps・480p は 3,750 kbps・未確定は 720p
        "TestBitrateKbps",  # 直近 10 秒の平均・窓の境界
        "TestExceedsThresholds",
        "TestExceedsAtTheWindowBoundary",
        "TestExceedsRejectsAnInvalidProfile",
        "TestNoFalsePositiveOnARealisticStreamAtTheProfileMaximum",  # 開始直後の誤検知なし
        "TestDetectsAFloodWhenTheWindowAverageExceedsTheLimit",
        "TestRecordErrors",
        "TestQueriesDoNotChangeState",
        "TestEntriesAreBounded",
        "TestRegressionErrorTextDoesNotDependOnTheLocation",  # エラーの文面が、環境（タイムゾーン）に依存しない
    ],
    "core/probe": [
        "TestNoDataIsAnError",  # 計測データなしはエラー
        "TestDueThreeSecondsAfterTheFirstData",  # 最初の受信から 3 秒
        "TestThroughputKbps",
        "TestDataAfterTheWindowIsNotCounted",
        "TestAbnormalValuesAreAnError",  # 上限を超える異常な値
        "TestAddErrors",
        "TestRealisticBrowserPacing",
        "TestRegressionErrorTextDoesNotDependOnTheLocation",  # エラーの文面が、環境（タイムゾーン）に依存しない
    ],
    "core/watchdog": [
        "TestNotArmedNeverStalls",  # 送出の開始前は判定しない
        "TestStalledWhenNoFrameArrivesAfterArming",  # 5 秒
        "TestEachKindIsWatchedSeparately",  # 映像または音声
        "TestArmAndDisarm",  # 復帰待ちの間は判定しない
        "TestOnFrameErrors",
        "TestRegressionErrorTextDoesNotDependOnTheLocation",  # エラーの文面が、環境（タイムゾーン）に依存しない
    ],
    "core/buffer": [
        "TestEvaluate",  # 1.5 秒を超えたら抑制・3 秒に達したら送出失敗
        "TestThrottleTarget",  # 現在の目標の 70%・下限を下回らない
        "TestNextThrottleSendsAtMostOncePerSecond",  # 1 秒に 1 回まで
        "TestSkippedCallsDoNotPostponeTheNextThrottle",
        "TestAThrottlingSession",
        "TestNextThrottleErrors",
        "TestRegressionErrorTextDoesNotDependOnTheLocation",  # エラーの文面が、環境（タイムゾーン）に依存しない
    ],
    "core/liveness": [
        "TestNothingObservedNeverStops",
        "TestStopsSixtySecondsAfterTheLastResponse",  # 59.9 秒は偽・60 秒で真
        "TestStopsSixtySecondsAfterTheFirstObservationWhenNeverSucceeded",
        "TestASuccessResetsTheCount",  # 成功で復帰
        "TestFailuresAfterASuccessDoNotMoveTheCount",
        "TestObserveErrors",
        "TestRegressionErrorTextDoesNotDependOnTheLocation",  # エラーの文面が、環境（タイムゾーン）に依存しない
    ],
    "core": [
        "TestScannerFindsViolations",  # 走査器が違反を見逃さない
        "TestCoreSourcesFollowTheDomainCoreRules",  # time.Now・net・net/http・gorilla・gin・グローバル変数・日本語の直書き
    ],
}

if len(sys.argv) != 2:
    print("使い方: check_acceptance_tests.py <go test -v ./core/... の出力>")
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
        if package == done.group(2):  # モジュールのルート直下（"…/relay"）などは対象外
            package = done.group(2).rsplit("/", 1)[-1]
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
