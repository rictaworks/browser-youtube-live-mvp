# test/pr37

PR #37（issue #18「中継 Domain Core: フレームの符号化・検証・時刻の再基準化・受信量の監視・回線計測・無通信の検出」）のテストです。対象は開発サーバー（`scripts/dc.sh` 経由の docker compose の relay コンテナ）です。

実装担当が書いた Go のテスト（`src/relay/core/**/*_test.go`）を、1 回で実行し、そのうえで、受け入れ条件がすべて検査されていること（空振りでないこと）を確かめます。

```bash
scripts/setup_dev_env.sh   # .env を生成します（済んでいれば何も変わりません）
test/pr37/run_all.sh
```

| 手順 | 確かめること |
|---|---|
| `go build ./...` | 中継の全パッケージがビルドできる |
| `scripts/test_relay.sh ./core/...` | gofmt の差分なし・`go vet`・`go test`（表形式のテスト、固定のシードの乱数列によるプロパティ風のテスト、参照実装との突き合わせ） |
| `scripts/test_relay.sh -race -count=1 ./core/...` | 競合検出つき（CI と同じ形。キャッシュを使わない） |
| `scripts/test_relay.sh -fuzz=FuzzDecode -fuzztime=20s ./core/frame` | `Decode` が、任意のバイト列でパニック・過大な確保をせず、参照実装と一致する。失敗する入力が見つかると `src/relay/core/frame/testdata/fuzz/` に保存されます（削除せず、そのまま残します） |
| `check_vector_coverage.py` | 共有ベクタ（`src/contracts/ws-frame-vectors.json`）の有効・無効の全件が、1 件ずつ実行され、成功している（黙って一部をスキップしていない） |
| `check_acceptance_tests.py` | 受け入れ条件に対応するテスト（70 件の名前）が、すべて実行され、成功している |
| `scan_core_sources.py --self-test` | 走査器そのものが、違反を見逃さず、違反でないものを誤検知しない |
| `scan_core_sources.py` | `src/relay/core` と、このディレクトリに、絵文字・削除系の記述が無い。Domain Core のソースが、`time.Now` などの実時計・`net`・`net/http`・gorilla・gin・`os`・`log` を参照せず、グローバル変数・日本語の直書きを持たない。`src/relay` の変更が `src/relay/core` の下だけ（契約 `core/contract` と `go.mod`・`go.sum` は変更なし） |

終了コード 0 が成功です（1 = 失敗がある、2 = `.env` が無いなど前提の不足）。

## 受け入れ条件との対応

| 受け入れ条件（issue #18） | 確かめるテスト |
|---|---|
| フレーム：`Decode`・`Encode`・`EncodeControl`、ヘッダ 17 バイト、14 種の種別、方向の検証 | `TestSharedVectorsValid`・`TestEncodeMatchesSharedVectors`・`TestDecodeHeaderFieldSweeps`・`TestEncodeControl`・`TestRoundTripRandomFrames` |
| 検証の失敗の型付きエラー 7 種、2,097,152 バイト超は `too_large`、本文長の不一致 | `TestSharedVectorsInvalid`・`TestDecodeLengthBoundaries`・`TestDecodeTruncatedHeader`・`TestErrorCodes` |
| 共有ベクタの有効・無効のすべて（見つからなければ失敗） | `TestSharedVectors*`・`TestLocateContractsDirFailsWhenMissing`・`check_vector_coverage.py` |
| 時刻の整合（`TimeGuard`）：逆行は破棄・前方への飛びは可・種別ごとに独立 | `TestTimeGuardAdmit`・`TestTimeGuardIgnoresControlFrames` |
| ファジング：パニック・過大な確保をしない | `FuzzDecode`・`TestDecodeMatchesTheOracleOnMutatedInputs`・`TestDecodeAllocationIsIndependentOfDeclaredLength` |
| 時刻の再基準化：接続ごとに 0 起点・復帰で欠落を詰める・映像と音声に同一の補正量・単調 | `TestRebase`（表形式）・`TestRebaseProperties`（固定のシードの乱数列）・`TestNoDriftOverTenHours` |
| 受信量の監視：直近 10 秒の平均・映像ビットレートの上限の 1.5 倍（720p は 9,000 kbps・480p は 3,750 kbps）・窓の境界・開始直後の誤検知なし | `TestBitrateKbps`・`TestExceedsThresholds`・`TestExceedsAtTheWindowBoundary`・`TestNoFalsePositiveOnARealisticStreamAtTheProfileMaximum`・`TestDetectsAFloodWhenTheWindowAverageExceedsTheLimit` |
| 回線計測：3 秒・受領量から kbps・データなしはエラー・異常な値の扱い | `TestDueThreeSecondsAfterTheFirstData`・`TestThroughputKbps`・`TestNoDataIsAnError`・`TestAbnormalValuesAreAnError` |
| 無通信の検出：5 秒・開始前と復帰待ちは判定しない | `TestStalledWhenNoFrameArrivesAfterArming`・`TestNotArmedNeverStalls`・`TestArmAndDisarm` |
| 送出待ちバッファ：1.5 秒で抑制・3 秒で送出失敗・目標は 70%・下限・1 秒に 1 回 | `TestEvaluate`・`TestThrottleTarget`・`TestNextThrottleSendsAtMostOncePerSecond` |
| 心拍の応答喪失：60 秒・59.9 秒は偽・成功で復帰 | `TestStopsSixtySecondsAfterTheLastResponse`・`TestASuccessResetsTheCount` |
| 品質：副作用なし・`time.Now`・`net`・`net/http`・gorilla・gin を参照しない（`core/` の走査）・`gofmt`・`go vet`・`-race` | `TestCoreSourcesFollowTheDomainCoreRules`・`scan_core_sources.py`・上の手順 2・3 |

ユーザー（ブラウザ）から見える変更はありません。PR の本文に、開発者向けの確認手順があります。
