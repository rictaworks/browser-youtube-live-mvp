# test/pr43

PR #43（issue #7「アプリケーション基盤: フロントエンドの確認・サーバー側セッション・CSRF・頻度制限・測定イベントの記録・ログの機密除外・口の分離」）のテストです。対象は開発サーバー（`scripts/dc.sh` 経由の docker compose の backend コンテナ）です。

実装担当が書いた RSpec（約 1,140 件）に加えて、実際のサーバー（Puma の 2 つの口）・本番の設定・ホストから見た口を、別の角度から確かめます。1 回で実行できます。

```bash
scripts/setup_dev_env.sh      # .env を生成します（済んでいれば何も変わりません）
scripts/dc.sh up -d --wait    # 起動します（済んでいれば何も変わりません）
test/pr43/run_all.sh
```

終了コード: 0 = すべて成功、1 = 失敗がある、2 = 準備ができていない（`.env` が無い）。各手順のログは、`mktemp` で作る一時ディレクトリに残ります（削除しません。場所は最初に表示します）。

並行して複数の環境を起動しているときは、`COMPOSE_PROJECT_NAME`・`BACKEND_PORT` を、その環境のものにします（例: `COMPOSE_PROJECT_NAME=bl-other BACKEND_PORT=13001 test/pr43/run_all.sh`）。テスト用 DB は `TEST_DB_NAME`（既定 `bl_test_issue7`）です。

| 手順 | 確かめること |
|---|---|
| 1 | `scripts/test_backend.sh --db`: この issue のスペックを実行します（RuboCop を含む）。BFF の確認・CSRF の評価の順・エラーの形・セッション・測定イベント・口の分離・ログの機密と IP の除外・頻度制限（スレッドの同時呼び出しを含む）・区分・Cookie の属性・本番の必須の環境変数・ホストの許可・ソースの規則（日本語の直書き・実時計・IP を読む場所・絵文字） |
| 2 | 手順 1 を、Rails の `eager_load` を有効にして（CI と同じ `CI=true`）実行します。`lib/`（once ローダー）と `app/`（main ローダー）のすべてのファイルが、eager load で読み込めること |
| 3 | RuboCop（omakase）を、この issue のアプリケーション・lib・config のファイルに掛けます |
| 4 | `bin/rails zeitwerk:check`: ファイル名と定数名の対応（`oauth_state_cookie.rb` が `OAuthStateCookie` を定義する規則を含む） |
| 5 | Brakeman: 警告 0 件 |
| 6 | `live_server_check.rb`: backend コンテナの中で、実際の Puma へ HTTP の要求を送ります（40 項目）。公開側の口（3001）と内部側の口（3101）で応答が分かれること（`puma.socket` から口を得ていること）、BFF の確認・CSRF の評価の順（403 forbidden → 403 csrf_invalid → 401 not_logged_in → 404）、エラーの形（契約の JSON・`Cache-Control: no-store`・`Set-Cookie` なし）、ホストの許可（`evil.example`・`127.0.0.1` は 403。`/up` は対象外）、BFF が付ける `X-Forwarded-Host` が許可の一覧に無くても拒否されないこと、ログ（`log/development.log`）に、IP（`X-Forwarded-For`・`Client-IP`）・認可コード・state・チケット・配信キー・`Authorization`・`Cookie`・不一致の秘密値が現れないこと。BFF の秘密値は、コンテナの環境変数から読み、出力しません |
| 7 | `check_host_ports.sh`: ホストから見た確認です。公開側の口の `/up` が 200、`/api/usage-events`（認証なし）が JSON のエラー（403）、`/internal` が 404、内部側の口（3101）がホストへ公開されていないこと。フロントエンド（`FRONTEND_PORT`。既定 3000）が起動していれば、同一オリジン中継（BFF）経由で、秘密値・転送ヘッダ（`X-Forwarded-Host`・`X-Forwarded-Proto`）・`Origin` の照合が期待どおりに働くこと（正しい `Origin` は 401 `not_logged_in`、違う `Origin`・`X-BL-Client` なしは 403 `csrf_invalid`、存在しない経路は 404）。起動していなければ省きます（SKIP） |
| 8 | `check_production.sh` と `production_stack_check.rb`: 本番（`RAILS_ENV=production`）の設定で Rails を起動します（コンテナの中。DB・外部サービスへは接続しません）。必須の環境変数が欠けていれば起動に失敗し、欠けた名前だけを書くこと（値は書かない）、ミドルウェアの順（`ForwardedHeaders` → `ListenerPort` → `HostAuthorization` → `AssumeSSL` → `SSL`）、`config.hosts`（`*.up.railway.app`・`*.railway.internal` だけ）、BFF の要求（`X-Forwarded-Host` が一覧に無い）が拒否されないこと、内部側の口の要求、ヘルスチェック、HSTS、Secure の Cookie |
| 9・10 | `scan_sources.py`: この issue のファイルと、このディレクトリに、絵文字・不可視の書式文字・削除系コマンド・機密の直書きが無く、UTF-8 として読めること。自己検査（`--self-test`）で、走査器が違反を見逃さず、違反でないものを誤検知しないことを確かめます |

## 安全上の約束

- 対象は開発サーバーだけです。本番（Railway・Vercel）・外部サービス（Google・YouTube・reCAPTCHA）へは接続しません。
- `.env` の値（`BFF_SHARED_SECRET` など）を、標準出力・引数へ出しません。コンテナの環境変数として、コンテナの中で読みます。
- ファイルを削除しません。ログのファイル（`log/development.log`）は、読み取りだけです。
- このテストのソースに、削除系コマンドの語・絵文字を、そのまま書きません（語は、部品から組み立てます）。

## ユーザーテスト手順（非エンジニア向け）

ユーザーから見える画面の変更はありません。次を確認します。

1. 開発者が `scripts/test_backend.sh` と `test/pr43/run_all.sh` を実行して、どちらも緑になること。
2. ブラウザで `http://localhost:3001/up` を開く。緑一色の画面のまま（これまでと同じ）であること。
3. ブラウザで `http://localhost:3001/api/usage-events`（ログインなし）を開く。画面に `{"error":{"code":"forbidden","details":{}}}` のような JSON が出て、HTML のエラーページにならないこと（ステータスは 403）。
4. ブラウザで `http://localhost:3001/internal/v1/verify` を開く。`{"error":{"code":"not_found","details":{}}}` が出ること（内部通信の経路は、公開側の口では応答しません）。

## 既知の限界

- 内部側の口（3101）の `/internal` の経路は、まだありません（#14 が足します）。ここでは、内部側の口が `/api`・`/admin`・`/up` に応答しないこと、公開側の口が `/internal` に応答しないことを確かめます。`/internal` が内部側の口で応答することは、ルーティングの制約（`InternalListener`）のスペックと、経路の構造のスペックが確かめます。
- ログインが要る API の実際のセッション・CSRF トークンの往復は、ログインの経路（#8）ができてから、ブラウザで確認できます。この issue では、スペック（`spec/requests/api/`）が確かめます。
- Railway の公開側のプロキシが付ける `X-Forwarded-Host`・`X-Forwarded-For` の挙動は、本番で確認します（開発では、プロキシが無いため、確かめられません）。
