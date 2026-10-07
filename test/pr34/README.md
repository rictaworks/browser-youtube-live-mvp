# test/pr34

PR #34（issue #2「CI（GitHub Actions）」）のテストです。`.github/workflows/ci.yml` を、**実行せずに**検査します。GitHub 上での実行結果は、PR の Checks で確認します（4 つの job：`backend`・`frontend`・`relay`・`hygiene`）。

## 実行

```bash
test/pr34/run_all.sh                 # すべて（変異テストを含む。数分かかります）
test/pr34/run_all.sh --no-mutation   # 構造と hygiene の動作の検査だけ
```

前提：ホストの `python3` に PyYAML があること。終了コードは、成功が 0、失敗が 1 です。作業用の一時ファイルは `mktemp` で作る場所に置きます（削除しません）。

## 内容

| ファイル | 確かめること |
|---|---|
| `check_ci.py` | **構造**：トリガー（`pull_request`・`push` の main）・`permissions: contents: read` のみ・サードパーティのアクションはメジャーバージョンを固定・全 job に `timeout-minutes`・長い実行コマンドに `timeout`・`concurrency`・各 job の手順の順序（backend＝bundle install → RuboCop → Brakeman → bundler-audit → `db:prepare` → RSpec、frontend＝`npm ci` → ESLint → 型検査 → Jest → `next build` → `npm audit --omit=dev`、relay＝gofmt → `go vet` → `go test -race`）・テスト用 DB 名・デプロイ／リリースの手順が無いこと。**hygiene の動作**：機密ファイル（`.env`・`config/master.key`・`*.pem`・`*.key`）の追跡、削除系コマンド、`src/` の絵文字を、一時の git リポジトリで、違反なら失敗・問題なければ成功になること（陽性・陰性の両方。Unicode の絵文字データでの範囲の確認を含む）。実際のリポジトリ（HEAD + `ci.yml`）でも成功すること |
| `mutate_ci.py` | **変異テスト**：`ci.yml` を 1 か所ずつ壊し（37 通り）、`check_ci.py` が必ず失敗を報告すること（見逃し 0 件） |

## 安全上の約束

- 実際のリポジトリの git の状態は変えません（読み取りと、一時ディレクトリの中の `git init`・`git add` だけ）。
- ファイルを削除しません。ケースごとに新しい名前の一時ディレクトリを作ります。
- このテストのソースには、削除系コマンドの語がテストデータとして含まれます。CI の hygiene は `test/` を除外しています（`ci.yml` の冒頭に根拠を明記）。

## ユーザーテスト手順（非エンジニア向け）

PR #34 の本文にあります（GitHub の PR 画面の Checks で、4 つの job が緑になることを確認します）。
