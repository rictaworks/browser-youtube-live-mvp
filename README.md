# browser-youtube-live-mvp

ブラウザのタブを開くだけで、カメラ・マイク・画面共有を合成した映像を、自分の YouTube チャンネルへライブ配信する Web サービスの MVP（需要調査）です。仕様は [requirements.md](requirements.md) が正です。

現時点で実装済みなのは、開発環境（docker compose）と、3 層・DB の雛形（環境の判定とヘルスチェックだけ）です。配信の機能は、まだありません。

## 構成

| 層 | 技術 | 配置 | 開発環境のポート |
|---|---|---|---|
| フロントエンド | Next.js 16（TypeScript・App Router）・Node 22 | `src/frontend/` | 3000 |
| アプリケーション | Rails 8.1（Ruby 3.4） | `src/backend/` | 3001（公開側）・3101（内部通信。ホストへ公開しません） |
| 中継 | Gin（Go 1.27） | `src/relay/` | 3002 |
| DB | PostgreSQL 17 | docker compose の `db`（backend だけが接続します。ホストへ公開しません） | なし |

`src/contracts/` は、3 層の契約（列挙・制限値・HTTP API・内部通信・WebSocket の転送プロトコル・共有のテストベクタ）の置き場です。すべてのコンテナへ `/contracts` として、読み取り専用でマウントします。各層は、実行時には `src/contracts/` を読まず、自分の定数モジュール（`src/backend/app/domain/contract/`・`src/frontend/core/contract/`・`src/relay/core/contract/`）を持ち、テストで契約との一致を確かめます。

## 開発環境の起動

ホストに必要なのは、WSL2 上の Docker（Docker Engine と Docker Compose v2）だけです。Ruby・Node・Go・PostgreSQL は、すべてコンテナの中で動きます。

```bash
scripts/setup_dev_env.sh     # .env を生成します（不足している変数だけを追記します。何度実行しても同じです）
scripts/dc.sh up -d --wait   # db・backend・relay・frontend を起動し、すべて healthy になるまで待ちます
```

初回は、gem・npm パッケージ・Go モジュールの取得とビルドのため、数分かかります。起動したら、ヘルスチェックで確かめます。

```bash
curl http://localhost:3001/up        # backend（200）
curl http://localhost:3002/health    # relay（{"status":"ok"}）
curl http://localhost:3000/healthz   # frontend（{"status":"ok"}）
```

止めるときは `scripts/dc.sh stop` です（再開は `scripts/dc.sh up -d --wait`）。ログは `scripts/dc.sh logs --tail 100 backend` のように確認します。

### docker compose は scripts/dc.sh 経由で呼びます

`scripts/dc.sh` は `docker compose` の薄いラッパーです。

- ホストの UID・GID を `HOST_UID`・`HOST_GID` として渡します。コンテナはその UID・GID で動くため、コンテナが作るファイル（gem・`node_modules`・ビルド・ログ）の所有者は、ホストのユーザーになります。
- 削除につながる操作（`down`・`rm`・`prune`・`run --rm` など）は拒否します。止めるときは `stop` を使います。削除が必要な場合は、手動で行ってください。
- 起動中のコンテナでコマンドを実行するときは、`scripts/dc.sh exec -T backend bin/rails about` のように `exec` を使います。

### 並行して複数の環境を起動する

公開ポートとプロジェクト名は、環境変数で変えられます（既定は上の表の値です）。

```bash
COMPOSE_PROJECT_NAME=bl-other FRONTEND_PORT=13000 BACKEND_PORT=13001 RELAY_PORT=13002 scripts/dc.sh up -d --wait
```

プロジェクト名を変えると、コンテナ・ネットワーク・db のボリュームも分かれます。`RELAY_PORT` を変えたときは、`.env` の `RELAY_PUBLIC_URL` の口も合わせます（`scripts/setup_dev_env.sh` は、`RELAY_PORT` が環境変数か `.env` にあれば、その口で `RELAY_PUBLIC_URL` を書きます）。

## テストと lint

必要なサービスは、各スクリプトが起動します。どれも、緑なら終了コード 0、赤なら 0 以外を返します。

```bash
scripts/test_all.sh        # すべて（scripts のテストと、契約・下の 3 層）
scripts/test_contracts.sh  # 契約（src/contracts）のテスト（Node の node --test）
scripts/test_backend.sh    # RSpec の全件・RuboCop（omakase）・Brakeman・bundler-audit
scripts/test_frontend.sh   # ESLint・tsc --noEmit・Jest
scripts/test_relay.sh      # gofmt の差分なし・go vet・go test
```

テスト対象は、引数で絞れます。lint は、引数があるときは対象のパスだけを検査します。

```bash
scripts/test_backend.sh spec/requests              # RSpec のパス・オプションを渡します（RuboCop は対象のパスだけ）
scripts/test_backend.sh --no-db spec/domain        # Rails を使わない素の RSpec（spec_helper だけ）を、DB の準備なしで速く回します
scripts/test_backend.sh --db spec/models           # DB の準備を必ず行います
TEST_DB_NAME=bl_test_issue5 scripts/test_backend.sh spec/models   # テスト用 DB の名前を変えます
scripts/test_frontend.sh core/contract             # Jest の引数を渡します（ESLint は対象のパスだけ。tsc は行いません）
scripts/test_relay.sh ./core/...                   # go test の引数を渡します（gofmt・go vet は対象のパッケージだけ）
```

- backend のテストは、`RAILS_ENV=test` と、テスト用 DB の `DATABASE_URL` を明示して実行します。既定の DB 名は `bl_test` です。`TEST_DB_NAME` で別の名前にすると、その DB が無ければ作り、スキーマを読み込みます。開発 DB（`bl_development`）は、決して使いません（名前は、小文字・数字・アンダースコアで、`test` を 1 つの語として含むものに限ります）。
- `--db`・`--no-db` が無いときは、対象のパスの配下に `rails_helper` を読むスペックがあるときだけ、DB を準備します。`spec_helper` だけを読み込むスペックは、Rails を起動せず DB へ接続しません。
- コンテナの `RAILS_ENV` は `development` なので、`scripts/dc.sh exec backend bundle exec rspec` のように直接実行すると、ガード（`spec/support/test_environment_guard.rb`）が止めます。テストは `scripts/test_backend.sh` で実行します。
- `scripts/test_relay.sh` は、パッケージが 1 つも無いパターン（まだ Go のファイルが無い `./core/...` など）を、Go の仕様のとおり失敗として扱います（指定の誤りを見逃さないためです）。
- `.env` に `RAILS_ENV` を書かないでください（`scripts/setup_dev_env.sh` が、書かれていれば止めます）。

### ビルド

```bash
scripts/dc.sh exec -T frontend npm run build   # Next.js の本番ビルド
docker build --target production src/relay     # 中継の本番用イメージ（GIN_MODE=release）
```

## 依存パッケージの置き場

依存は、各層のディレクトリ内の、gitignore 済みの場所に置きます。

| 層 | 置き場 |
|---|---|
| backend | `src/backend/vendor/bundle`（gem）・`src/backend/.cache`（HOME・bundler の設定） |
| frontend | `src/frontend/node_modules` |
| relay | `src/relay/.cache`（HOME・Go のモジュールとビルドのキャッシュ・開発用のバイナリ） |

gem・npm パッケージを足したあとは、`scripts/dc.sh restart backend`（または `frontend`）で取り込みます。Dockerfile（`src/backend/Dockerfile`・`src/relay/Dockerfile`）を変えたあとは、`scripts/dc.sh up -d --wait --build` で、イメージを作り直して起動します。

## 環境変数

名前は [.env.example](.env.example) と requirements.md 29.4 にあります。値は `.env` に書きます（gitignore 済みです。コミットしません）。

- 開発用の `.env` は `scripts/setup_dev_env.sh` が生成します。乱数の値（`SESSION_SECRET` など）と、開発用の固定値を書き、`GOOGLE_*`・`RECAPTCHA_*` は空のままにします（開発・テストは疑似実装を使います）。
- 既存の値は上書きしません。ファイルも削除しません。
- `POSTGRES_PASSWORD` は、db のボリュームを最初に作るときに、db へ設定されます。あとから `.env` の値を変えると、既存のボリュームのパスワードと食い違い、backend が接続できなくなります。変えないでください（別の値で始めるときは、`COMPOSE_PROJECT_NAME` を変えて、新しい db のボリュームで起動します）。
- コミットの前に `git status` を実行し、`.env`・`config/master.key`・`*.pem` がステージされていないことを確かめてください。
- 本番の値は、Railway Variables と Vercel Environment Variables に設定します（リポジトリへ入れません）。

## API 一覧

現時点の API は、各層のヘルスチェックだけです。

| タイトル | メソッドと URL（開発環境） |
|---|---|
| アプリケーション（Rails）のヘルスチェック | `GET http://localhost:3001/up` |
| 中継（Gin）のヘルスチェック | `GET http://localhost:3002/health` |
| フロントエンド（Next.js）のヘルスチェック | `GET http://localhost:3000/healthz` |
