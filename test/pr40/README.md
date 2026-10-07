# test/pr40

PR #40（issue #24「ブラウザ Domain Core（1）: メディアクロック・レイアウト・能力検出・プロファイル選定・再接続・タブ間の排他・状態機械」）のテストです。対象は開発サーバー（`scripts/dc.sh` 経由の docker compose の frontend コンテナ）と、ホストの Node です。

実装担当が書いたテスト（`src/frontend/core/` の Jest）に加えて、実行で確かめられる受け入れ条件を、1 回で実行します。

```bash
scripts/setup_dev_env.sh      # .env を生成します（済んでいれば何も変わりません）
test/pr40/run_all.sh      # すべて
```

終了コード 0 は「失敗がない」ことです。**SKIP（確認できなかった項目）は、成功に数えません**。件数を、最後に表示します。

| 手順 | 確かめること |
|---|---|
| `scripts/test_frontend.sh core/` | ESLint（`core/`）と Jest（`core/` の全件）。メディアクロック（映像 1 フレーム = 音声 1,470 サンプル・128 サンプル単位の呼び出し・10 時間分の累積を BigInt を使わずに厳密に検査・停止と再開）、レイアウトと幾何（`resolveLayout`・`containRect`・`wipeRect`）、能力検出（`evaluateCapabilities`・`classifyBrowser`・`readBrowserCapabilities`。疑似の環境で、ワーカーのスクリプトを実際に実行する）、プロファイル選定（4,099・4,100・1,199・1,200 の境界）、再接続の待機（0.5 -> 1 -> 2 -> 4 -> 5 秒）と判断、タブ間の排他（疑似の Web Locks）、開始入力の検証と既定のタイトル（JST）と申告の記憶、スタジオ（25.3）とソース（25.5）の状態機械の遷移表の全行と、定義のない全組、`core/` の規則の走査 |
| 型検査 | `tsc --noEmit`（プロジェクトの `tsconfig.json` を引き継ぎ、`core/` のソースとテストだけ。プロジェクト全体の型検査は CI の担当） |
| `lib/source-policy`（#22） | 日本語のリテラルを `messages/` の外に置かない・絵文字を使わない・`alert` 系を使わない（`core/` も走査される） |
| `scan_core_sources.cjs` | Jest の走査とは別に実装した走査。実時計（`Date`・`performance`）・タイマ（`setTimeout` など）・乱数（`Math.random`）・DOM・`WebSocket`・`localStorage`・`fetch`・`React` の大域の参照、相対でない `import`、日本語の文字列リテラル、メディアクロックの `BigInt`、絵文字、削除系の語の実行形が、`core/` に無いこと。`core/contract`（#3 の契約）が変更されていないこと。走査器の自己検査つき |
| `probe_capabilities.cjs` | 実ブラウザ（Playwright の Chromium）で `readBrowserCapabilities(window)` を実行し、ブラウザの API を直接問い合わせた事実と突き合わせる。同じオリジンの複数のタブで、本物の `navigator.locks` に対する `TabLockGuard` の動作を確かめる（下の節） |

## 実ブラウザでの実測の再現

`probe_capabilities.cjs` は、core の TypeScript を、リポジトリの TypeScript でその場で JavaScript にして、ローカルの HTTP サーバー（127.0.0.1）からページへ配り、Chromium で次を確かめます（成果物のファイルは作りません）。

- `MediaStreamTrackProcessor` は Window にあるが、**ワーカー内では使えない**。`MediaStreamTrack` は**ワーカーへ転送できない**（`DataCloneError`）
- メインで作った `MediaStreamTrackProcessor` の `readable` を、ワーカーへ転送すると、ワーカーで `VideoFrame` を読める（#27 の構成）
- H.264（Main・Constrained Baseline）の `VideoEncoder.isConfigSupported`、AAC-LC の `AudioEncoder.isConfigSupported`
- 能力検出の結果（`report`）が、上の実測から導いた値と一致する。失敗の記録（`failures`）が空
- タブ間の排他：同じオリジンの 2 つのタブで、本物の `navigator.locks` に `TabLockGuard` を使い、最初のタブは取得できる（`true`）・別のタブは取得できない（`false`）・解放すると別のタブが取得できる・**保持しているタブを閉じる（解放しない）と、ブラウザがロックを解放し、別のタブが取得できる**。ロック API を渡さなければ `"unsupported"`
- CSP でワーカー（Blob URL）が禁じられたページ（`worker-src 'self'`）：検出は、応答の期限（5 秒）を待たずに終わり、ワーカー内の可否は偽（拒否側）、失敗の記録（`worker_probe`）が 1 件、他の検査は影響を受けない

**Linux の Chromium では、AAC のエンコードを使えません**（Chrome の AAC エンコードは Windows（N エディションを除く）・macOS・Android のみ）。そのため、Linux では `aacEncode` が偽、`canStart` が偽になります。これは設計どおり（「配信の開始を提供しない」）で、実測の再現として、`probe_capabilities.cjs` は Linux でこれを期待します。AAC の実エンコードの確認は、この環境では**できません**。Windows または macOS の Chrome での確認は、ユーザーテストの手順にあります。

### Playwright の導入（初回だけ。リポジトリの外の、任意のディレクトリへ）

Playwright と Chromium が無いときは、この手順は **SKIP**（確認できなかった）になります。

```bash
mkdir -p "$HOME/.cache/issue24-playwright" && cd "$HOME/.cache/issue24-playwright"
npm init -y
npm install playwright
PLAYWRIGHT_BROWSERS_PATH="$PWD/browsers" npx playwright install chromium
```

実行は、導入したディレクトリを環境変数で指定します。

```bash
cd <リポジトリのルート>
ISSUE24_PLAYWRIGHT_DIR="$HOME/.cache/issue24-playwright" \
PLAYWRIGHT_BROWSERS_PATH="$HOME/.cache/issue24-playwright/browsers" \
test/pr40/run_all.sh
```

`probe_capabilities.cjs` だけを実行することもできます。

```bash
node test/pr40/probe_capabilities.cjs --repo "$PWD" --json
```

### Windows・macOS の Chrome での AAC の確認（この環境（WSL2・Linux）ではできません）

Windows（N エディションを除く）・macOS の Google Chrome では、AAC のエンコードを使えるはずです。その環境に、このリポジトリと Playwright を用意して、インストール済みの Chrome を指定して実行します（Chromium の導入は要りません）。

```bash
node test/pr40/probe_capabilities.cjs --repo "$PWD" --playwright-dir "<Playwright を導入したディレクトリ>" --channel chrome --json
```

期待する結果は、`report.aacEncode` が `true`、`evaluation.canStart` が `true`（H.264 と他の能力もそろうとき）です。Linux 以外では、この手順は AAC の可否を固定して期待せず、ブラウザへ直接問い合わせた結果と、能力検出の結果が一致することだけを確かめます。この確認は、PR の作業では**行えていません**（確認できなかったこと）。

## 前提

- Docker（`scripts/dc.sh`）と、ホストの Node 22（走査と実ブラウザの実測）、`git`。`src/frontend/node_modules`（frontend コンテナが起動時に導入します）
- ネットワークは、Playwright の導入のときだけ使います。YouTube・Google・reCAPTCHA は呼びません

## ユーザー（ブラウザ）から見える変更

ありません。この PR は、画面に表示されない純粋な関数と状態機械だけです（画面は #29、配線は #28）。開発者が `test/pr40/run_all.sh` を実行して、失敗がないことを確かめます。
