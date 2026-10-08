# test/pr52

PR #52（issue #27「ブラウザ: 映像合成（ワーカー）と H.264／AAC エンコード（WebCodecs）」）のテストです。対象は開発サーバー（`scripts/dc.sh` 経由の docker compose の frontend コンテナ）と、ホストの Node です。

実装担当が書いたテスト（`src/frontend/lib/pipeline/`・`src/frontend/workers/pipeline/` の Jest）に加えて、実行で確かめられる受け入れ条件を、1 回で実行します。

```bash
scripts/setup_dev_env.sh      # .env を生成します（済んでいれば何も変わりません）
test/pr52/run_all.sh      # すべて
```

終了コード 0 は「失敗がない」ことです。**SKIP（確認できなかった項目）は、成功に数えません**。件数を、最後に表示します。

| 手順 | 確かめること |
|---|---|
| `scripts/test_frontend.sh lib/pipeline workers/pipeline` | ESLint と Jest。合成（`VideoCompositor`・`planFrame`: 出力は解像度に固定、縦横比を保って内接、余白は単色、ワイプは右下、スレートに文字なし、1 回の合成で 1 枚の完全なフレーム、ソースごとに最新の 1 枚だけ保持して古いフレームを即 `close()`）、映像のエンコード（`VideoEncoderPipeline`: H.264 Main／Constrained Baseline・固定ビットレート・低遅延・AVCC・60 フレームごとのキーフレーム・入力待ち 2 超で符号化前に破棄・`setBitrate`・`forceKeyframe`・復号器設定）、音声のエンコード（`AudioEncoderPipeline`: AAC-LC・累積サンプル数から時刻・連続性の検査）、型付きのメッセージ（`messages`: 検証・転送対象）、`PipelineHost`（プレビュー／クロック駆動・停止と再開・キーフレームから再開・故障の通知・資源の解放）、**遅れへの対処**（`LagGuard`: 音声のブロックの処理待ちの深さを推定し、待ちが積み上がっている間は合成を飛ばす。待ちのモデルの疑似で、合成が 400 ミリ秒・3 秒かかっても待ちが増え続けないこと）、`PipelineClient`（起動・要求の期限・異常終了の検知・解放）、`applySourceChange`（#26 の `SourceChange` との接続）、**クライアントとワーカーをメモリの中でつないだ結合**（`loopback.test.ts`: 実際の `PipelineClient`・`startPipelineWorker`・`PipelineHost`・`SourceManager` で、ワーカーの合成が選ぶレイアウトが `SourceChange.layout` と一致すること）、静的な検査（実時計・文字を描く API・トラックの停止・日本語の直書き） |
| 型検査 | `tsc --noEmit`（プロジェクトの `tsconfig.json` を引き継ぎ、`lib/pipeline`・`workers` のソースとテストだけ。プロジェクト全体の型検査は CI の担当） |
| `lib/source-policy`（#22） | 日本語のリテラルを `messages/` の外に置かない・絵文字を使わない・`alert` 系を使わない（`lib/` 全体を走査する。**`workers/` は、この検査の対象ディレクトリに入っていません**。`workers/pipeline` は、`pipeline-rules.test.ts` と `scan_pipeline_sources.cjs` が走査します） |
| `scan_pipeline_sources.cjs` | Jest の走査とは別に実装した字句の走査。実時計（`Date`・`performance`）・描画の周期・乱数が無い。大域のタイマは `timers.ts` だけ。文字を描く API・DOM・ネットワークが無い。`import.meta` は `defaultWorker.ts` だけ。**映像トラックを止めない**（止めるのは `SourceManager`）。日本語の文字列リテラルが無い。**メッセージの取り決め**（コマンド 16 種のすべてを `PipelineHost` が、イベント 7 種のすべてを `PipelineClient` が処理する）。絵文字・ネイティブのダイアログ・削除系の語の直書きが無い。走査器の自己検査つき |
| `probe_worker_bundle.cjs` | ワーカーが、Next.js（Turbopack）のバンドルで動く。`next build` + `next start`（本番）と `next dev`（開発）で、`new Worker(new URL(...), { type: "module" })` が別のワーカーのスクリプトとして出力され、`PipelineClient.start` が解決して `get_stats` の応答が返る |
| `probe_pipeline.cjs` | 実ブラウザ（Playwright の Chromium）での実測（下の節）。`--audio real` は、AAC の実エンコード（Windows・macOS の Chrome） |
| `probe_preview_method.cjs` | プレビューの方式の実測（下の節）。`<canvas>` を `transferControlToOffscreen` してワーカーへ渡す方式（製品）と、`ImageBitmap` を毎フレーム送る方式の比較 |
| `probe_hidden_tab.cjs` | 配信中のタブを本当に非表示にした実測（下の節）。生の CDP + 仮想ディスプレイ |

## 実ブラウザでの実測（probe_pipeline.cjs）

`lib/`・`core/`・`workers/` の TypeScript を、リポジトリの TypeScript でその場で JavaScript にして、ローカルの HTTP サーバー（127.0.0.1）からページへ配り（成果物のファイルは作りません）、**製品のコード**（`PipelineClient`・`AudioMixer`・ワーカーの本体 `startPipelineWorker`）を、そのまま Chromium で動かします。カメラは偽のデバイス（`--use-fake-device-for-media-stream`）、画面共有は、キャンバスから作る合成のトラック（画素が決まっていて、位置・色を確かめられる）です。場面ごとに、新しいブラウザを起動します。

- **A. レイアウトの画素**: 代替スレート（背景は単色・中央に図形・文字なし）・カメラのみ（640x480 を 960x720 に内接、左右 160 画素の黒い余白）・画面共有 + カメラ（赤が主映像・右下に青のワイプ、幅 282・外側の余白 32・角が丸く切り取られる）・ソースの喪失で戻る（画面共有の喪失 -> カメラのみ -> カメラの喪失 -> スレート）。**プレビューが、合成と同一の画素（差のある画素が 0）**。新しいフレームが届かなくても、最後のフレームを描き続ける。プレビューだけの間は、符号化しない（`VideoFrame` を作らない）
- **B. 全経路**: 偽のカメラ + 合成の画面共有 -> メインの `MediaStreamTrackProcessor` -> `readable` をワーカーへ転送 -> 合成 -> **実際の H.264 のエンコーダ**。標準 720p（`avc1.4D401F`）と、軽量 480p（`avc1.42E01F`）。確かめること: 復号器設定（`AVCDecoderConfigurationRecord`）の取得、**キーフレームの間隔が 2 秒（60 フレームごと）**、時刻が `videoTime(フレーム番号)` のグリッド上で単調増加、**AVCC 形式**（各 NAL の前に 4 バイトの長さ。フレームに SPS・PPS が無い）、**復号器設定で、すべてのチャンクが復号できる**（`VideoDecoder`）、音声の時刻が `audioTime(起点 + n × 1,024)` と一致、**フレームの解放漏れが無い**（受け取った数 = 閉じた数 + 保持している数。合成から作った `VideoFrame` も、作成数 = 閉じた数）、配信中はワーカーのタイマを使わない（音声の処理周期だけが駆動する）、実際の `configure` の内容（コーデック・解像度・固定ビットレート・低遅延・AVCC・30 fps）
- **C. 音声の停止と再開**: `AudioContext` の `suspend` で、合成が止まり（メディアクロックの累積サンプル数も進まない）、`resume` で、**キーフレームから**再開する
- **D. ビットレートの変更**: `setBitrate`（再設定）で、同じコーデック・解像度・固定ビットレート・低遅延・AVCC のまま、ビットレートだけが変わり、実績が追従する。**実測（Chromium 153）では、再設定でキーフレームも復号器設定も出ない**（キーフレームの間隔は、再設定があっても 2 秒を超えない）
- **E. ワーカーの異常終了**: 未処理の例外を検知して `worker_crashed` を 1 回だけ通知する。ワーカーのスクリプトの読み込みの失敗も、`start` の拒否になる
- **F. 合成が遅い環境**: ワーカーの合成（`drawImage`）を 1 回 150 ミリ秒（合成 1 回で約 300 ミリ秒）遅くして、GPU の無い環境・負荷の高い端末を、機械の負荷に依らず再現する。**ワーカーが遅れても、制御の応答（`get_stats`・`end_session`）が 2 秒未満で返り、処理待ちの深さ（統計の `audioBacklogMs`）が増え続けず、メディアクロックが実時間に追いつき、音声が途切れない**。遅れている間は合成を飛ばし（符号化の前に捨てる）、合成は止まらない

音声は、**疑似の AAC エンコーダ**です（Linux の Chromium は AAC の `AudioEncoder` を使えません）。疑似のエンコーダは、実際の `AudioData`（インターリーブの f32）を受け取って中身を読み、1,024 サンプルごとに 1 チャンクを出します。AAC の実エンコードは、この環境では**確認できていません**（下の「確認できないこと」）。

### 実測の結果の例（2026-10-08・この環境: WSL2 / Linux・Chromium 153（ヘッドレス）・GPU なし）

| 項目 | 結果 |
|---|---|
| 720p・Main | 6 秒で映像 180 チャンク（30.00 fps）・音声 259 チャンク・平均 234 kbps（動きが少ない映像のため、目標 4,500 kbps に届かない）・設定（最初の出力の取得）に 77 ms・キーフレームは 2,000,000 マイクロ秒ちょうど |
| 480p・Constrained Baseline | 5 秒で映像 150 チャンク（30.00 fps）・音声 216 チャンク・設定に 43 ms |
| ビットレートの変更 | 目標 4,500 kbps（実績 4,488）-> 3,000 kbps（実績 2,917）。再設定の直後 300 ミリ秒のキーフレーム 0 件・復号器設定 0 件 |
| 合成が遅い環境（F） | `get_stats` の往復は最大 約 0.3 秒、処理待ちの深さは最大 約 0.05 秒、メディアクロックの遅れは 0.0 秒。合成 32 枚・遅れで飛ばした 233 枚。音声は途切れず、終了に 約 0.3 秒 |
| 連続して実行 | 全体（92 件）を連続で成功（約 70 秒）。場面 F は 3 回連続 |

**環境の制約（実測）**: GPU の無いヘッドレスの Chromium（ソフトウェアの GL）では、ワーカーでの `drawImage(VideoFrame)` が、動く映像を 2 つ同時に描くと、数秒（約 7 秒）で遅くなり（1 フレーム 10 ミリ秒 -> 25 から 100 ミリ秒）、1 つだけでも約 12 秒で遅くなります（画面共有の取得の方法・キャンバスの種類・符号化・プレビューの有無を変えても同じ）。CPU に負荷がかかっていると、1 回 0.3 から 1 秒かかります。そのため、場面ごとに新しいブラウザを使い、各場面を 6 秒前後に収めています。ページを開いたままにすると、前の場面の描画が次の場面の負荷になります。**実機（GPU あり）の 720p の継続は、実機で確かめます**。

**この実測で見つかった問題と修正（遅れの検知）**: CPU に負荷をかけた状態（計算のループを 6 つ同時に動かす）で場面 B を繰り返したところ、10 回中 3 から 6 回が `request_timeout`（`end_session` などの応答が 10 秒返らない）で失敗しました。原因は、ワーカーが遅れたときの検知（`LagGuard`）でした。当初の検知は、ブロックの処理の間隔が小さい塊が映像 1 フレーム分（12 ブロック）続いたら遅れとしていましたが、遅れの原因である合成そのものが塊を断ち切る（合成は 11.5 ブロックごと）ため、一度も働かず、処理待ちが 10 秒まで積み上がっていました。**処理待ちの深さを推定する方式**（イベントの `timeStamp` の進みと、音声の累積サンプル数の進みの差。実測で、`timeStamp` は処理を始めた時刻であることを確かめています）に改め、待ちが 100 ミリ秒を超えたら合成を飛ばし、30 ミリ秒を下回ったら戻します。同じ負荷での再試験は 12 回中 0 回の失敗で、場面 F が、機械の負荷に依らず再現します（旧方式に戻すと、場面 F は `request_timeout` で失敗します）。

## プレビューの方式の実測（probe_preview_method.cjs）

プレビューは、`<canvas>` を `transferControlToOffscreen` してワーカーへ渡し、ワーカーが合成と同じ画素を直接描く方式です。代案の、`ImageBitmap` を毎フレーム送る方式と、同じ合成（1280x720・30 fps）で比べました。メインスレッドを 1.5 秒止めます（重い画面の更新・ガベージコレクションの疑似）。

| 方式 | 停止の間に、ワーカーの周期の処理が走った回数（30 fps なら約 45） | メインスレッドの作業 |
|---|---|---|
| `transferControlToOffscreen`（採用） | 45 | フレームごとの作業なし（0 回） |
| `ImageBitmap` を毎フレーム送る | **1**（ワーカーが、メインスレッドの停止に巻き込まれて止まる） | フレームごとに処理（平均 約 0.1 ミリ秒）。停止の直後に最初に描くフレームは 1.5 秒前のもの |

配信中のワーカーは、音声のブロックで駆動されます。ワーカーが止まると、音声のブロックが溜まり、映像が遅れます。メインスレッドの停止（重い画面の更新・非表示のタブ）に巻き込まれない方式を、採用しました。なお、停止の最中に表示が更新され続けること自体は、この環境では確かめられませんでした（スクリーンショットが、メインスレッドの停止が終わるまで返らないため）。

## 非表示のタブでの実測（probe_hidden_tab.cjs）

Playwright は、ページを常に表示中として扱う（可視状態を模擬する）ため、タブを本当には非表示にできません。そこで、ブラウザを自分で起動し（有頭。Linux では仮想ディスプレイ Xvfb の中。ブラウザの既定の動作を、そのまま受けます）、生の CDP でタブを操作して、別のタブを前面にします（`document.visibilityState` が `hidden` になることを確かめています）。配信（偽のカメラ + 合成の画面共有 -> 合成 -> 実際の H.264）を始めてから、タブを非表示にして、窓ごとにチャンクの数・到着の間隔・ワーカーの統計・メディアクロックを記録します。

- 判定: 非表示の間も、音声が理論値（43.07 チャンク/秒）の ±2%、映像が 27 チャンク/秒以上（30 fps の 9 割）かつ表示中の 9 割以上、メディアクロックが実時間に追従（差が 1% または 0.5 秒）、チャンクの到着の間隔が 500 ミリ秒以内、停止・故障・時刻の逆行が無い、遅れで合成を飛ばした割合が 2% 未満
- **Linux の仮想ディスプレイには、音声の出力デバイスが無く、`AudioContext` が進みません**。`--disable-audio-output`（偽の音声出力。実時間で進む）を付けて起動します（既定）。実機の確認では `--fake-audio-output 0` にして、本物の出力デバイスで動かします
- 画面共有の代わりの合成のトラックは、メインスレッドのタイマで描くので、非表示のタブでは、更新が間引かれます（約 1 秒に 1 回）。製品の経路（音声のブロック -> ワーカー -> 合成 -> 符号化 -> チャンク）は、メインスレッドのタイマに依存しません。カメラ（偽のデバイス）は、毎秒 30 フレームが届きます

実測（2026-10-08・Chromium 153・Xvfb・480p）:

| 長さ | 映像 | 音声 | メディアクロックと実時間の差 | 最大の到着間隔 |
|---|---|---|---|---|
| 非表示 30 秒（表示中の基準 10 秒・前面に戻して 10 秒） | 30.00 チャンク/秒（窓の最小 29.9） | 43.05 チャンク/秒（窓の最小 43.0） | -0.003 秒 | 映像 55 ms・音声 40 ms |
| **非表示 330 秒（5 分 30 秒。タブが `hidden` だった時間は 330.1 秒）**（表示中の基準 10 秒・前面に戻して 10 秒） | **30.00 チャンク/秒**（窓の最小 29.9。33 窓すべて 30） | **43.07 チャンク/秒**（窓の最小 43.0） | **0.005 秒**（330.13 秒のメディア時間） | 映像 117 ms・音声 102 ms。合成 9,903 枚・入力待ちの破棄 0・遅れで飛ばした 0・故障 0 |

実行の例:

```bash
# 既定（非表示 30 秒）
node test/pr52/probe_hidden_tab.cjs --repo "$PWD"
# 5 分以上（約 6 分かかる）
node test/pr52/probe_hidden_tab.cjs --repo "$PWD" --hidden-seconds 330
# run_all.sh から
ISSUE27_HIDDEN_SECONDS=330 test/pr52/run_all.sh
```

Xvfb が無い環境は **SKIP** です（`--display current` で、今の画面にウィンドウを開いて実行することもできます）。

## この環境では確認できないこと

実機で確かめます（「ユーザーから見える変更」の節の手順）。

- **AAC の実エンコード**: Linux の Chromium は AAC の `AudioEncoder` を使えません（`AudioEncoder.isConfigSupported` が偽）。Chrome の AAC は、Windows（N エディションを除く）・macOS・Android だけです。`probe_pipeline.cjs --audio real` は、この環境では **SKIP**（終了コード 3）になります。音声の経路は、疑似の AAC エンコーダ（実際の `AudioData` を渡す）と、疑似の `AudioEncoder`（Jest）で確かめています
- **実機のハードウェアのエンコーダ**（Windows の Media Foundation・macOS の VideoToolbox）での H.264（`avc` 形式・固定ビットレート・低遅延）の出力。この環境は、ソフトウェアのエンコーダ（OpenH264）です
- **GPU のある環境での 720p の継続**（上の「環境の制約」）
- **本物の音声出力デバイスでの、非表示のタブの継続**（上の節。仮想ディスプレイでは偽の音声出力）
- 実機のカメラ・画面共有。偽のデバイスと、合成のトラックで代えています
- YouTube への配信（#28 以降）

### Playwright の導入（初回だけ。リポジトリの外の、任意のディレクトリへ）

Playwright と Chromium が無いときは、実ブラウザの手順は **SKIP**（確認できなかった）になります。

```bash
mkdir -p "$HOME/.cache/issue27-playwright" && cd "$HOME/.cache/issue27-playwright"
npm init -y
npm install playwright
PLAYWRIGHT_BROWSERS_PATH="$PWD/browsers" npx playwright install chromium
```

実行は、導入したディレクトリを環境変数で指定します。

```bash
cd <リポジトリのルート>
ISSUE27_PLAYWRIGHT_DIR="$HOME/.cache/issue27-playwright" \
PLAYWRIGHT_BROWSERS_PATH="$HOME/.cache/issue27-playwright/browsers" \
test/pr52/run_all.sh
```

個別の実行（それぞれ、`--repo "$PWD"` が必要です）:

```bash
node test/pr52/probe_pipeline.cjs --repo "$PWD"                 # 約 1 分（場面ごとに新しいブラウザを起動）
node test/pr52/probe_pipeline.cjs --repo "$PWD" --only stream720 # 1 つの場面だけ（layouts・stream720・stream480・stall・bitrate・crash・overload）
node test/pr52/probe_preview_method.cjs --repo "$PWD"
node test/pr52/probe_worker_bundle.cjs --repo "$PWD"
```

調べるときは、環境変数 `ISSUE27_DEBUG=1` で、ページとワーカーの診断をコンソールへ出せます。

## 前提

- Docker（`scripts/dc.sh`）と、ホストの Node 22（走査と実ブラウザの実測。生の CDP は Node の `WebSocket` を使います）、`git`。`src/frontend/node_modules`（frontend コンテナが起動時に導入します）
- 非表示のタブの実測は、Linux では `Xvfb`
- ネットワークは、Playwright の導入のときだけ使います。YouTube・Google・reCAPTCHA は呼びません
- `probe_worker_bundle.cjs` は、作業用のディレクトリ（既定は OS の一時ディレクトリの下の `issue27-bundle-probe`）に、確認用のアプリと `core`・`lib`・`workers` の写しを置きます。`probe_hidden_tab.cjs` は、ブラウザのプロファイルを同じく一時ディレクトリに置きます。どちらも、手順の中で消しません。不要になったら、手動で削除してください

## ユーザー（ブラウザ）から見える変更

ありません。この PR は、画面に表示されない部品（映像の合成・H.264／AAC のエンコード・ワーカーとの受け渡し）だけです（画面は #29、配信の制御は #28）。

非エンジニア向けの確認手順:

1. 開発サーバー（`http://localhost:3000/`）を開き、既存のページが、これまでどおり表示されることを確かめます（この PR で画面は変わりません）
2. 開発者が、次の 2 つを実行して、どちらも失敗がないことを確かめます
   - `scripts/test_frontend.sh lib/pipeline workers/pipeline`
   - `test/pr52/run_all.sh`
3. **AAC のエンコードの実機確認**（Windows または macOS の Chrome。この環境では確認できません）。Node 22 と Playwright を導入したうえで、次を実行し、「N 件 ok / 0 件 FAIL」になることを確かめます
   - `node test/pr52/probe_pipeline.cjs --repo "$PWD" --audio real --channel chrome`
4. **非表示のタブの実機確認**（Windows または macOS の Chrome）。次を実行し、ウィンドウが開いて、配信用のタブが他のタブの後ろに隠れた状態で測られ、「N 件 ok / 0 件 FAIL」になることを確かめます
   - `node test/pr52/probe_hidden_tab.cjs --repo "$PWD" --browser-path "<Chrome の実行ファイルのパス>" --display current --fake-audio-output 0 --hidden-seconds 330`
