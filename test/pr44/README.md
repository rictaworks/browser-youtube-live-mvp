# test/pr44

PR #44（issue #25「ブラウザ Domain Core（2）: 転送フレームの符号化・送信待ち・適応制御・回線計測」）のテストです。対象は開発サーバー（`scripts/dc.sh` 経由の docker compose の frontend・relay コンテナ）と、ホストの Node です。

実装担当が書いたテスト（`src/frontend/core/` の `transport`・`queue`・`governor`・`probe`・`report` の Jest）に加えて、実行で確かめられる受け入れ条件を、1 回で実行します。

```bash
scripts/setup_dev_env.sh          # .env を生成します（済んでいれば何も変わりません）
test/pr44/run_all.sh          # すべて
```

終了コード 0 は「失敗がない」ことです。**SKIP（確認できなかった項目）は、成功に数えません**。件数を、最後に表示します。

| 手順 | 確かめること |
|---|---|
| `scripts/test_frontend.sh core/transport core/queue core/governor core/probe core/report` | ESLint（5 ディレクトリのみ）と Jest。フレームの符号化・復号（共有ベクタの全件、64 ビットの時刻の境界、検証の順、本文の JSON の検証、base64）、送信待ち（映像を 1 枚でも破棄したら次のキーフレームまで全破棄・音声は破棄しない・滞留時間と受領応答の初期値・再接続中は積まない・安全弁）、適応制御の 7 条件（境界を表形式で）、回線の悪化と回復を模したシミュレーション、回線計測（ペース配分・タイムアウト）、状態報告（出来事を欠落なく 1 回ずつ）、契約の数値を直書きしないことの検知 |
| `check_acceptance_tests.cjs` | Jest の JSON の結果から、受け入れ条件 89 項目に対応するテストが、下限の件数以上、成功していること。スキップ・todo・失敗が 0 件であること。ディスクにあるテストのファイルがすべて実行されていること（題の変更・削除・スキップで、黙って検査されなくならない） |
| 型検査 | `tsc --noEmit`（プロジェクトの `tsconfig.json` を引き継ぎ、5 ディレクトリのソースとテストだけ。プロジェクト全体の型検査は CI の担当） |
| `lib/source-policy`（#22）・`core/domain-core-rules`（#24） | 日本語のリテラルを `messages/` の外に置かない・絵文字を使わない・`alert` 系を使わない。`core/` が、実時計・タイマ・DOM・`WebSocket`・React・`window` に依存しない |
| `scan_core_sources.cjs` | Jest の走査とは別に実装した走査。実時計・タイマ・乱数・DOM・入出力の大域の参照、相対でない `import`、日本語の文字列リテラル、`BigInt` のリテラル（`1n`。`target` が ES2017 のため型検査に失敗する）、モジュール直下の `let`、絵文字、削除系の語の実行形が無いこと。**適応制御の数値（`BitrateGovernor.ts`）と、フレームの構造の数値（`frameLayout.ts`）を直書きしていないこと**。走査器の自己検査つき |
| `check_vectors.cjs` | 共有ベクタ（`src/contracts/ws-frame-vectors.json`）を、Jest を使わず、TypeScript の実装へ独立に通す。さらに、仕様（`ws-protocol.md` の 2 章・4 章）から別に書いた参照実装（`reference_frame.cjs`）と、TypeScript の復号を、約 20 万通りの入力（ベクタの 1 バイトの書き換え・切り詰め・延長・種別の全 256 値・本文長の端の値・2 MB の境界・ランダム）で突き合わせ、結果とエラーの符号が完全に一致すること |
| `scripts/test_relay.sh ./core/frame/...` | 中継（Go。#18）が、**同じ共有ベクタ**を通すこと。ブラウザ（TypeScript）と中継（Go）のコーデックの互換を、両側から確かめる |
| `probe_codec_in_browser.cjs` | 実ブラウザ（Playwright の Chromium）で、本物の WebSocket と本物のタイマを使い、中継の代役（`routeWebSocket`。参照実装でフレームを読み書きする）と、一連の流れを通す（下の節） |

## 実ブラウザでの確認

`probe_codec_in_browser.cjs` は、core の TypeScript を、リポジトリの TypeScript でその場で JavaScript にして、ローカルの HTTP サーバー（127.0.0.1）からページへ配ります（成果物のファイルは作りません）。ページの中で、次を確かめます。

1. 共有ベクタの全件（valid 42 件・invalid 43 件）を、実ブラウザの `TextEncoder`・`TextDecoder`・`DataView`（BigInt）で通す
2. 64 ビットの時刻（2^64 - 1、2^53 + 1）が、丸めずに往復する。不正な UTF-8 と BOM の本文を拒否する。`Blob` とテキストのメッセージは復号しない（WebSocket は `binaryType = "arraybuffer"` にして使う）
3. 本物の WebSocket と本物のタイマで、接続通知（`hello`）→ 接続受理（`accepted`）→ 回線計測（3 秒間、68 個の計測データをペース配分して送り、中継の代役の規則「受けた量 × 8 ÷ 3,000」で得た 5,945 kbps を受け取る）→ プロファイルの選定（720p）→ 開始通知（`start`）→ 映像・音声 145 件（`SendQueue` を通し、中継の代役の受信と、バイト列まで一致）→ 受領応答（`ack`）→ 滞留時間の評価 → 適応制御 → 状態報告（`report`）→ 抑制指示・キーフレーム要求・状態通知・致命通知の受信・テキストのメッセージの拒否 → 終了通知（`end`）

**Linux の Chromium では、AAC のエンコードを使えません**。この検査は、符号化済みのデータを模した固定のバイト列を送ります（エンコーダは #27 の担当）。実際の中継（Go。#20・#21）との結合、実際の YouTube への送出は、確かめていません。

### Playwright の導入（初回だけ。リポジトリの外の、任意のディレクトリへ）

Playwright と Chromium が無いときは、この手順は **SKIP**（確認できなかった）になります。

```bash
mkdir -p "$HOME/.cache/issue25-playwright" && cd "$HOME/.cache/issue25-playwright"
npm init -y
npm install playwright
PLAYWRIGHT_BROWSERS_PATH="$PWD/browsers" npx playwright install chromium
```

実行は、導入したディレクトリを環境変数で指定します。

```bash
cd <リポジトリのルート>
ISSUE25_PLAYWRIGHT_DIR="$HOME/.cache/issue25-playwright" \
PLAYWRIGHT_BROWSERS_PATH="$HOME/.cache/issue25-playwright/browsers" \
test/pr44/run_all.sh
```

#24 の検査（`test/pr40`）で導入した Playwright（`ISSUE24_PLAYWRIGHT_DIR`）も、そのまま使えます。実ブラウザの検査だけを実行することもできます。

```bash
node test/pr44/probe_codec_in_browser.cjs --repo "$PWD" --playwright-dir "<Playwright を導入したディレクトリ>"
```

## 受け入れ条件との対応

| issue の受け入れ条件 | 主な確認 |
|---|---|
| フレームの符号化（`encode`・`decode`、ヘッダ 17 バイト、64 ビットの時刻、7 種と 7 種、JSON 本文の型付き） | `transport/frameLayout.test.ts`・`FrameCodec.test.ts`・`bodies.test.ts`、`check_vectors.cjs`、実ブラウザ |
| 共有ベクタの有効・無効をすべて通す（見つからなければ失敗）、型付きのエラー | `transport/FrameCodec.vectors.test.ts`（42 件・43 件）、`check_vectors.cjs`、Go の同じベクタ |
| 本文は UTF-8、`description_b64` の base64 の往復 | `transport/base64.test.ts`・`startBody.test.ts`・`FrameCodec.test.ts` |
| 送信待ち（`enqueue`・`backlogMs`・初期値の扱い、`dropVideoUntilNextKey`・`discardAllVideo`、音声は破棄しない、取り出しの順、再接続中は積まない、メモリの上限） | `queue/SendQueue.test.ts`（表形式の 100 件弱と、1,000 通りの性質の検査） |
| 適応制御（`evaluate`、7 条件の境界、1 秒あたり 1 回、引き下げ幅 > 引き上げ幅、抑制指示の優先、状態、時刻の逆行、決定的、シミュレーション） | `governor/BitrateGovernor.test.ts`・`BitrateGovernor.simulation.test.ts`・`BitrateGovernor.constants.test.ts` |
| 回線計測（`measure(channel, clock)`、3 秒・6,000 kbps・32 KB、ペースの計算は純粋、タイムアウト） | `probe/*.test.ts`、実ブラウザ（本物のタイマ） |
| 状態報告（出来事を欠落なく 1 回ずつ、`detail` は符号と数値のみ） | `report/ReportBuilder.test.ts` |
| すべて副作用なし、`core/` が DOM・WebSocket・React を参照しない、ESLint・`tsc`・Jest が緑 | `core/domain-core-rules`、`scan_core_sources.cjs`、型検査、ESLint |

## 前提

- Docker（`scripts/dc.sh`）と、ホストの Node 22（独立した検査・実ブラウザ）、`src/frontend/node_modules`（frontend コンテナが起動時に導入します）
- ネットワークは、Playwright の導入のときだけ使います。YouTube・Google・reCAPTCHA は呼びません
- `lib/source-policy/repository`（#22）は、フロントエンド全体を走査します。ほかの issue の変更が、その検査に違反している間は、その手順だけが失敗します（この PR の変更とは無関係です）

## ユーザー（ブラウザ）から見える変更

ありません。この PR は、画面に表示されない純粋な関数と型だけです（WebSocket・WebCodecs との接続は #27・#28、画面は #29）。開発者が `scripts/test_frontend.sh core/` と `test/pr44/run_all.sh` を実行して、失敗がないことを確かめます。
