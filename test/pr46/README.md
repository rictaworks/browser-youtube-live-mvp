# test/pr46

PR #46（issue #26「ブラウザ: ソースの取得（カメラ・マイク・画面共有・共有音声）と音声の混合（音声の処理周期でクロックを駆動）」）のテストです。対象は開発サーバー（`scripts/dc.sh` 経由の docker compose の frontend コンテナ）と、ホストの Node です。

実装担当が書いたテスト（`src/frontend/lib/sources/`・`src/frontend/lib/audio/` の Jest）に加えて、実行で確かめられる受け入れ条件を、1 回で実行します。

```bash
scripts/setup_dev_env.sh      # .env を生成します（済んでいれば何も変わりません）
test/pr46/run_all.sh      # すべて
```

終了コード 0 は「失敗がない」ことです。**SKIP（確認できなかった項目）は、成功に数えません**。件数を、最後に表示します。

| 手順 | 確かめること |
|---|---|
| `scripts/test_frontend.sh lib/sources lib/audio public/worklets` | ESLint と Jest。ソースの取得（`SourceManager` の全状態遷移・拒否・取り消し・デバイスなし・型付きのエラー・トラックの終了・再取得・解除・要求中の解除・デバイスの変更・購読・破棄・診断にデバイス名を出さないこと）、デバイスの一覧、取得の制約（エコー除去・雑音抑制・`getDisplayMedia({video: true, audio: true})`）、**`getDisplayMedia` が、利用者のクリックの直後に、最初の非同期呼び出しとして、同期的に呼ばれること**（クリックの外では `InvalidStateError` になる疑似で）、音声の混合（`MixerCore` の数値・位相・上限・無音・ゲインの変更・ブロック境界。**Worklet のファイルを疑似の `AudioWorkletGlobalScope` で実行して、`MixerCore` の出力と、1 ビットも違わないこと**）、`AudioMixer`（疑似の `AudioContext`・`AudioWorkletNode` で、グラフの接続・出力先へつながないこと・音量・停止と再開の通知・開始の失敗）、`AudioMixer` と Worklet のメッセージの取り決めの結合、`MediaClock` の駆動、ソースの実装の静的な検査（実時計・折り返し再生） |
| 型検査 | `tsc --noEmit`（プロジェクトの `tsconfig.json` を引き継ぎ、`lib/sources`・`lib/audio` のソースとテストだけ。プロジェクト全体の型検査は CI の担当） |
| `lib/source-policy`（#22） | 日本語のリテラルを `messages/` の外に置かない・絵文字を使わない・`alert` 系を使わない（`lib/` 全体を走査し、`public/worklets` の JavaScript の絵文字も検査される） |
| 開発サーバーが Worklet を配る | `next dev` が、`/worklets/stream-mixer-processor.js` を、200・JavaScript の MIME 型・ファイルと同じ内容で返す（`AudioWorklet.addModule` が読み込める） |
| `scan_media_sources.cjs` | Jest の走査とは別に実装した字句の走査。`lib/audio`・Worklet に、実時計（`Date`・`performance`）・タイマ・乱数が無い。`lib/audio`・`lib/sources` に、出力先（`destination`）への接続・`<audio>`・`play`・`srcObject` が無い（配信者自身への折り返し再生をしない）。`lib/sources` が音声のグラフを作らない。Worklet が自己完結（`import`・`export`・`fetch` が無い）で、数値処理の定数が `MixerCore` と同じ。絵文字・ネイティブのダイアログ・削除系の語の直書きが無い。走査器の自己検査つき |
| `probe_media.cjs` | 実ブラウザ（Playwright の Chromium）での実測（下の節） |

## 実ブラウザでの実測

`probe_media.cjs` は、`lib/`・`core/` の TypeScript を、リポジトリの TypeScript でその場で JavaScript にして、ローカルの HTTP サーバー（127.0.0.1）からページへ配り（成果物のファイルは作りません）、Worklet は `/worklets/stream-mixer-processor.js` で、そのまま配って、Chromium で次を確かめます。カメラ・マイク・画面共有は、偽のデバイス（`--use-fake-device-for-media-stream`・`--use-fake-ui-for-media-stream`）です。

- **A. 混合**: `AudioContext` が 44,100 Hz で作られる。ソースが 1 つも無い間も、128 サンプルのブロックを途切れなく出し続ける（累積サンプル数が 0 から連続し、実時間と合う）。マイク（直流 0.5）・共有音声（直流 0.25）の追加・解除・音量の変更で、出力が 0.5・0.65（= 0.5 + 0.25 × 0.6）・0.75・0.25・0 になる（共有音声は 0.6 倍）。過大な入力（1.0 + 1.0 × 0.6）が、上限（1）を超えず、1 付近に収まる。異なる周波数のソース（別の `AudioContext` から作ったトラック）が、混合の段で変換される
- **B. ワーカーへの直接の送出**: 転送した `MessagePort` で、メインスレッドを経由せず、ワーカーへブロックが届く。メインスレッドを 1.5 秒占有しても、ブロックは途切れない（タブが非表示で、メインスレッドのタイマが間引かれた状態の代わり）
- **C. メディアクロックの駆動**: ブロックで `MediaClock` が進む（映像 1 フレーム = 1,470 サンプル）。`AudioContext` の `suspend`・`resume` で、停止・再開が通知され、再開後の最初の合成がキーフレームになる。停止をまたいでも、累積サンプル数が連続する
- **D. ソースの取得**: `SourceManager` が、本物の `MediaDevices` で、カメラ・マイク・画面共有・共有音声を取得する。マイクは、エコー除去・雑音抑制が適用される（トラックの設定が `true`）。存在しないデバイスの識別子は、別のデバイスへ黙って切り替えず、未取得（`device_not_found`）になる。トラックの終了で喪失になり、混合から外れる（混合は止まらない）。破棄でトラックが止まる。`<audio>`・`<video>` の要素を作らない。診断にデバイス名を出さない
- **E. 画面共有の選択画面が使えない環境**（偽の UI なし）: `attach("screen")` が、要求中のまま止まらず、未取得へ戻る（Chromium の headless では、`NotSupportedError` から、型付きのエラー `unsupported`）

**この環境では確認できないこと**（実機は、画面ができる #29 のユーザーテストで行います）:

- 実機のカメラ・マイク・画面共有（利用者の許可・選択画面）。偽のデバイスで代えています
- 一時的なアクティベーション（クリック）が無いときの `InvalidStateError`。偽の UI では、この検査が省かれるため、疑似の `getDisplayMedia`（Jest）で保証しています
- 5 分以上、タブを非表示にしたときの継続（公式の保証の記述が無い。実機で、30 fps と音声の周期の維持を確かめます）。B の「メインスレッドの占有」は、その代わりの確認です
- 配信者自身への折り返し再生が起きないこと（耳で確かめます）。ソースの静的な検査と、グラフの接続の検査（Jest）で保証しています
- AAC のエンコード（Linux の Chromium では使えません。#27・#28 の範囲）

### Playwright の導入（初回だけ。リポジトリの外の、任意のディレクトリへ）

Playwright と Chromium が無いときは、この手順は **SKIP**（確認できなかった）になります。

```bash
mkdir -p "$HOME/.cache/issue26-playwright" && cd "$HOME/.cache/issue26-playwright"
npm init -y
npm install playwright
PLAYWRIGHT_BROWSERS_PATH="$PWD/browsers" npx playwright install chromium
```

実行は、導入したディレクトリを環境変数で指定します。

```bash
cd <リポジトリのルート>
ISSUE26_PLAYWRIGHT_DIR="$HOME/.cache/issue26-playwright" \
PLAYWRIGHT_BROWSERS_PATH="$HOME/.cache/issue26-playwright/browsers" \
test/pr46/run_all.sh
```

`probe_media.cjs` だけを実行することもできます（Playwright の Chromium は、約 20 秒で終わります）。

```bash
node test/pr46/probe_media.cjs --repo "$PWD" --json
```

## 前提

- Docker（`scripts/dc.sh`）と、ホストの Node 22（走査と実ブラウザの実測）、`git`。`src/frontend/node_modules`（frontend コンテナが起動時に導入します）
- ネットワークは、Playwright の導入のときだけ使います。YouTube・Google・reCAPTCHA は呼びません

## ユーザー（ブラウザ）から見える変更

ありません。この PR は、画面に表示されない部品（ソースの取得・音声の混合・Worklet）だけです（画面は #29、配線は #27・#28）。開発者が `test/pr46/run_all.sh` を実行して、失敗がないことを確かめます。
