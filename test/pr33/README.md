# test/pr33

PR #33（issue #1「開発環境の整備: docker compose・環境変数の生成・3 層と DB の雛形」）のテストです。対象は**開発サーバー**（`scripts/dc.sh` 経由の docker compose。ホストの `localhost`）で、本番（Railway・Vercel）や実際の YouTube・Google には接続しません。

実装担当が書いた単体テスト（`scripts/tests/`・RSpec・Jest・`go test`）は `scripts/test_all.sh` が実行します。ここには、それらと重複しない**システム・受け入れ・結合のテスト**を置いています。

## 実行

```bash
scripts/setup_dev_env.sh          # .env を生成します（済んでいれば何も変わりません）
test/pr33/run_all.sh              # すべて（初回は、イメージとパッケージの取得のため数分かかります）
test/pr33/run_all.sh 15_ 16_      # 名前に「15_」か「16_」を含むチェックだけ
test/pr33/run_all.sh --stop       # 最後に scripts/dc.sh stop で止めます
```

終了コードは、成功が 0、失敗が 1 です（`SKIP` は失敗にしません。集計に出ます）。各チェックの上限時間は、ファイルの 2 行目の `# pr33-timeout: 秒` です。

## チェックの一覧

| チェック | 確かめること |
|---|---|
| `checks/10_stack_up.sh` | `.env` の権限・gitignore、`up -d --wait` で 4 サービスが healthy になること、もう一度 `up` してもコンテナを作り直さないこと（冪等）、公開ポートが 3000・3001・3002 だけであること |
| `checks/15_user_test_steps.sh` | PR 本文のユーザーテスト手順 1〜5（`/healthz`・`/up`・`/health` が 200、`3101` がホストから届かない、存在しないパスが 404。PR #33 の時点では `/` も 404 でしたが、ページの追加で変わるため存在しないパスで確かめます）と、db のポートが公開されていないこと（curl 版） |
| `checks/16_user_test_browser.sh` | 同じ手順を実ブラウザ（Playwright の Chromium）で描画して確かめます（緑一色・存在しないパスの 404 の画面）。Playwright か Chromium が無ければ SKIP |
| `checks/20_setup_dev_env.sh` | `scripts/setup_dev_env.sh` が、必要な変数をすべて作ること・冪等・既存の値を上書きしない・値を出力しない・`RAILS_ENV` を拒否すること（一時ディレクトリの別の `ENV_FILE` で。実際の `.env` には触れません） |
| `checks/21_setup_compose_contract.sh` | 生成した `.env` と `docker-compose.yml` の必須変数の整合（欠ける・空だと起動前に失敗する。任意の変数が欠けても起動できる） |
| `checks/30_compose_config.sh` | `docker compose config` の検査（サービス・ポート・`user`・`/contracts` の読み取り専用・環境変数が層ごとに必要なものだけ・秘密値の直書きが無い・特権なし） |
| `checks/31_runtime_isolation.sh` | 動いているコンテナの実行時の検査（UID・GID・環境変数・`/contracts` に書けない・3101 は compose のネットワークの中だけ・db への接続・環境の判定・各ツールの版） |
| `checks/40_file_ownership.sh` | コンテナが作ったファイル（依存・ビルド・ログ）がホストのユーザー所有であること（root 所有が無い） |
| `checks/50_dc_guard.sh` | `scripts/dc.sh` が削除につながる操作を拒否すること（偽の docker で、呼ばれないことを確認）と、通してよい操作を誤って拒否しないこと |
| `checks/51_test_db_protection.sh` | テストが開発 DB（`bl_development`）を壊さない 3 つの層（ホストの拒否・コンテナ内のガード・`rails_helper` のガード）と、別の `TEST_DB_NAME` での実行 |

## 安全上の約束

- 接続先のホスト名は `localhost` に固定です（変えられるのはポート番号だけ）。
- 削除系のコマンドを実行しません。後始末が要る場面でも削除せず、新しい名前の一時ディレクトリを使います。このテストのソース自体にも、削除系コマンドの語をそのまま書きません（`lib/common.sh` の `W_*` から組み立てます）。
- `.env` の値を、標準出力・標準エラー・コマンドの引数へ出しません。
- git の状態を変えません（読み取りのみ）。
- 自己再帰ガード・`ulimit -u`・チェックごとの `timeout` を設定してから実行します（`.claude/TEST-HARNESS-SAFETY.md`）。
- `51_test_db_protection.sh` は、開発用の PostgreSQL にテスト用 DB `bl_test_pr33` を作ります（再実行すると再利用します）。不要になったら、手動で削除してください。

## ユーザーテスト手順（非エンジニア向け）

PR #33 の本文に、ブラウザだけで確認できる手順を書いています（`/healthz`・`/up`・`/health` の表示と、`3101` が開けないこと）。上の `15_`・`16_` が、その自動版です。
