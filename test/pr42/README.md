# test/pr42

PR #42（issue #23「同一オリジン中継（BFF）・API クライアント・bot 判定・ランディング・アカウント画面」）のテストです。対象は開発サーバー（`scripts/dc.sh` 経由の docker compose の frontend・backend コンテナ。ホストの `localhost`）と、ホストの Node です。

実装担当が書いたテスト（`src/frontend/` の Jest）に加えて、実行で確かめられる受け入れ条件を、1 回で実行します。

```bash
scripts/setup_dev_env.sh          # .env を生成します（済んでいれば何も変わりません）
test/pr42/run_all.sh          # すべて（コンテナは、このスクリプトが起動します）
test/pr42/run_all.sh 5 6      # 工程 5 と 6 だけ
test/pr42/run_all.sh --strict # SKIP（確認できなかった）も、失敗として扱います
```

終了コード 0 は「失敗がない」ことです。**SKIP（確認できなかった項目）は、成功に数えません**。工程ごとの結果と、件数を、最後に表示します。

## 工程

| 工程 | 確かめること |
|---|---|
| 1. `scripts/test_frontend.sh`（この issue の範囲） | ESLint と Jest。同一オリジン中継（`app/api`）・API クライアント（`lib/api`）・bot 判定（`lib/recaptcha`）・ランディング（`components/landing`・`app/page`）・アカウント（`components/account`・`app/account`）・レイアウト（`app/layout`・`app/web-analytics`）・文言（`messages`）・文言の方針の走査（`lib/source-policy`） |
| 2. 型検査 | `tsc --noEmit`（プロジェクトの `tsconfig.json` を引き継ぎ、この issue の範囲と、その依存だけ。プロジェクト全体の型検査は CI の担当） |
| 3. 本番ビルド | `npm run build`。経路の表で、`/`・`/account`・`/api/[...path]`・`/healthz` が、要求のたびに描画される動的な経路（`ƒ`）であること（bot 判定のサイトキーを、要求ごとに読むため。静的に生成されると、サイトキーがビルド時に固定される）。ビルドは、プロジェクト全体を型検査します。**ほかの issue の作業中のファイルの型エラーで失敗し、この issue の範囲に型エラーが無いときは、SKIP（確認できなかった）にします**（失敗の原因のファイルを、範囲の内と外に分けて表示します。工程 4 も SKIP） |
| 4. 同一オリジン中継の結合（`lib/bff_e2e.cjs`） | frontend コンテナの中で、`next start`（本番の構成）と、使い捨てのスタブのバックエンドを起動し、素の HTTP で確かめます（終了時に、起動したものを止めます）。ヘッダの付与と除去（共有の秘密値・転送ヘッダの作り直し・偽のヘッダの除去・ホップ間ヘッダ）、`Set-Cookie` の複数、302 の透過、バックエンドのホストを指す `Location` の拒否、すべてのメソッド、圧縮・ストリーム・204、経路の拒否（`..`・エンコードされた区切り・`/api/internal`・`/api/admin`・本番の `/api/dev/`・`/internal`・`/admin`）と、拒否した要求がバックエンドへ届かないこと、本文の上限（64 KB）、設定エラー（欠けている変数の名前だけ）、バックエンド不達（502。アドレスを出さない）、共有の秘密値が、応答とログに出ないこと |
| 5. 開発サーバーへの curl（`lib/curl_smoke.sh`） | `/`・`/account` の HTML（文言の正本との一致・`robots`・外部ドメインの参照が無い・秘密値の名前が出ない）、`/?login_error=` の通知、`/api/...` の転送（実物のバックエンド。バックエンドが応答したこと、内部のヘッダを返さないこと）、すべてのメソッドが中継へ届くこと、中継が自分で拒否する要求、本文の上限、形の不正な Host |
| 6. 実ブラウザ（`lib/browser_check.cjs`） | Playwright の Chromium で、描画・フォーカス・外部ドメインへ通信しないこと・ログイン・確認のダイアログ・アクセシビリティ（下の節） |
| 7. ソースの走査（`lib/scan_sources.cjs`） | 削除系の語・絵文字・不可視の制御文字・秘密らしい文字列・`alert`/`confirm`/`prompt`・日本語の直書き・`fetch` と `process.env` の置き場・外部 URL の直書き・保存先（`localStorage` など）・HTML の差し込み・`console.log`・`core/contract` が変更されていないこと。走査器の自己検査つき |

## 実ブラウザの確認（工程 6）

ブラウザの API 呼び出し（`/api/*`）は、場面に応じて、ブラウザ側で疑似の応答にします（Playwright の `route`）。画面・スクリプト・スタイルは、開発サーバーの本物です。実物のバックエンドは、この時点では `/up` しか無いため、契約（`src/contracts/http-api.md`）のとおりの疑似の応答で、画面の動きを確かめます。疑似なしの場面では、実物のバックエンドへ、そのまま繋いだ現状（未実装の経路への 404）を確かめます。

- 描画: 見出し・制限の数値（`src/contracts/limits.json` の値と単位）・ボタン・通知が、文言の正本（`src/frontend/messages/`）と一致して出る。`body` の背景がトークン（`--bg`）と一致する。横にはみ出さない（デスクトップ 1280 px・モバイル 375 px）。画面が空白でない
- フォーカス: 最初の Tab がスキップリンク、ログインのボタンへ有限回で届く、フォーカスの見た目、Enter での操作、処理中の二重操作の遮断。確認のダイアログ（初期位置はキャンセル・Tab と Shift+Tab の循環・外へ出たフォーカスを戻す・背景の `inert`・Escape・押したボタンへの戻り先。**マウスで開いた場合も**。背景を `inert` にすると、ブラウザは押したボタンからフォーカスを外すため、jsdom の Jest では見つからない不具合が、実ブラウザでだけ起きます）
- 通信: すべての `page` の `request` を記録し、外部のドメインへ通信しないこと。ネイティブのダイアログ（`alert` など）を開かないこと。未処理の例外・想定外のコンソールのエラーが無いこと
- 操作と要求: ログイン・YouTube 接続・再確認・接続の解除・アカウントの削除・ログアウト。要求の本文（bot 判定のトークンだけ）・`X-BL-Client`・`X-CSRF-Token`（未ログインの要求には付けない）
- 失敗: ログインの失敗（429・403・500・契約に無い応答）の通知（`role`・題・本文）。**遷移を許さない認可 URL**（`javascript:`・外部のドメイン・Google を装った http・`/api/dev/` の外）へ遷移せず、一般的な失敗の通知を出すこと。未ログインの `/account` は `/` へ移ること。配信中は、接続の解除・再接続・アカウントの削除を無効にすること。再確認の制限
- 秘密: `.env` の秘密らしい値（`SECRET`・`PASSWORD`・`TOKEN` などを名前に含む変数）が、ブラウザの受け取る同一オリジンのすべての応答（HTML・スクリプト・スタイル・API）に含まれないこと。値は、メモリの中だけで比べ、出力しません（変数の名前だけを出します）
- アクセシビリティ: axe-core（`src/frontend/node_modules/axe-core`。無ければ、その確認だけ SKIP）で、違反が 0 件

bot 判定のサイトキー（`RECAPTCHA_SITE_KEY`）が `.env` で空のとき（開発の既定）、画面は疑似のトークン `dev-pass` を使います。値があるときは、Google のスクリプトを疑似に差し替えて確かめます（実際の Google へは通信しません）。スクリーンショットは、`ARTIFACT_DIR`（既定は、一時ディレクトリの中の `screenshots`）に残ります。

### Playwright の導入（初回だけ。リポジトリの外の、任意のディレクトリへ）

Playwright と Chromium が無いときは、工程 6 は **SKIP**（確認できなかった）になります。`PLAYWRIGHT_DIR`、`~/.npm/_npx/*/node_modules/playwright`（npx のキャッシュ）、`npm root -g` の順に探します。

```bash
mkdir -p "$HOME/.cache/issue-playwright" && cd "$HOME/.cache/issue-playwright"
npm init -y
npm install playwright
PLAYWRIGHT_BROWSERS_PATH="$PWD/browsers" npx playwright install chromium
```

実行は、導入したディレクトリを環境変数で指定します。

```bash
cd <リポジトリのルート>
PLAYWRIGHT_DIR="$HOME/.cache/issue-playwright/node_modules/playwright" \
PLAYWRIGHT_BROWSERS_PATH="$HOME/.cache/issue-playwright/browsers" \
test/pr42/run_all.sh 6
```

## 前提

- Docker（`scripts/dc.sh`）と、ホストの Node 22・`curl`。`src/frontend/node_modules`（frontend コンテナが起動時に導入します。走査と文言の正本の読み込みが、リポジトリの TypeScript を使います）
- 工程 1・2・3・4 は frontend コンテナを、工程 5・6 は開発サーバー（`http://localhost:3000`。`FRONTEND_PORT` で変更）を使います。backend コンテナ（`BACKEND_PORT`。既定 3001）が起動できないときは、実物のバックエンドへの転送の確認だけが SKIP になります
- 工程 4 は、工程 3 のビルド（`.next`）を使います。工程 4 だけを実行するときは、既存のビルドを使うため、先にビルドしてください
- 共有の作業ツリーでは、ほかの issue の作業中のファイルが、工程 3（ビルドは、プロジェクト全体を型検査します）と工程 1 の方針の走査（`lib/source-policy`。リポジトリ全体を走査します）に影響することがあります。PR のブランチ（この issue の変更だけがある状態）で実行してください
- 工程 4 の `bff_e2e.cjs` は、ホストの Node でも実行できます。`E2E_APP_DIR` に、ビルド済みの frontend のディレクトリ（`.next` と `node_modules` がある `src/frontend`）を指定すると、工程 3 の成否に依らず、そのディレクトリに対して実行します（ポートは、127.0.0.1 の 3201・3202・4010。変更は `BFF_E2E_NEXT_PORT`・`BFF_E2E_STUB_PORT`）。共有の作業ツリーでビルドできないとき、`git archive` で取り出した変更前の状態に、この issue のファイルを重ねたディレクトリで、ビルドと結合を確かめるために使えます

```bash
E2E_APP_DIR=<ビルド済みの src/frontend> test/pr42/run_all.sh 4
```

## 安全上の約束

- 対象は開発サーバーです。本番へ接続しません。YouTube・Google・reCAPTCHA の実物を呼びません（ブラウザの外部ドメインへの通信は、記録して、失敗にします）
- 削除系のコマンドを実行しません。一時ファイルは、新しいディレクトリ（`mktemp -d`）に作り、置いたままにします。起動したプロセスは、終了時に止めます（`scripts/dc.sh stop` で、コンテナを止められます）
- `.env` の値を、出力・コマンドの引数へ出しません（秘密の混入の確認で、メモリの中だけで比べます）。テストが使う値（トークン・秘密値）は、明らかなダミーです
- 認証情報（Cookie・トークン）を、実物のバックエンドへ送りません。実物へ送る要求は、存在しない経路（`/api/no-such-endpoint-for-test`）への、ダミーの本文だけです
- ハーネスの安全（`.claude/TEST-HARNESS-SAFETY.md`）: 自己再帰ガード（TH1）・`ulimit -u` と各工程の `timeout`（TH3）。1 工程の上限は `STEP_TIMEOUT`（既定 900 秒）で変更できます

## ユーザー（ブラウザ）から見える変更

ランディング（`/`）とアカウント（`/account`）が追加されます。手順は、PR の本文の「ユーザーテスト」にあります。開発者は、`test/pr42/run_all.sh` を実行して、失敗がないことを確かめます。
