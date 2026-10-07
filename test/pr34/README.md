# test/pr34

PR #34（issue #2「CI（GitHub Actions）」）のテストです。`.github/workflows/ci.yml` を、**実行せずに**検査します。GitHub 上での実行結果は、PR の Checks で確認します（4 つの job：`backend`・`frontend`・`relay`・`hygiene`）。

## 実行

```bash
test/pr34/run_all.sh                 # すべて（変異テストを含む。数分かかります）
test/pr34/run_all.sh --no-mutation   # 構造と hygiene の動作の検査だけ
```

前提：ホストに `python3`（PyYAML 入り）・`perl`（`Unicode::UCD`。Perl 5.38 の Unicode 15.0 のデータを、絵文字の範囲の確認に使います）・`git`・`tar` があること。終了コードは、成功が 0、失敗が 1 です。作業用の一時ファイルは `mktemp` で作る場所に置きます（削除しません）。

## 内容

| ファイル | 確かめること |
|---|---|
| `check_ci.py` | **構造**：トリガー（`pull_request`・`push` の main）・`permissions: contents: read` のみ・サードパーティのアクションはメジャーバージョンを固定・全 job に `timeout-minutes`・長い実行コマンドに `timeout`・`concurrency`・各 job の手順の順序（backend＝bundle install → RuboCop → Brakeman → bundler-audit → `db:prepare` → RSpec、frontend＝`npm ci` → ESLint → 型検査 → Jest → `next build` → `npm audit --omit=dev`、relay＝gofmt → `go vet` → `go test -race`）・テスト用 DB 名・デプロイ／リリースの手順が無いこと。**hygiene の動作**：機密ファイル（`.env`・`config/master.key`・`*.pem`・`*.key`）の追跡、削除系コマンド、`src/` の絵文字を、一時の git リポジトリで、違反なら失敗・問題なければ成功になること（陽性・陰性の両方。Unicode の絵文字データでの範囲の確認を含む）。削除系の検査の**許可リスト**（ファイル単位・理由つき）の動作と内容（`test/pr33/lib/common.sh`・`test/pr33/lib/deletion_scan.sh` の 2 つだけ）、`::error::` に出すパスのエスケープも確かめます。実際のリポジトリ（HEAD に、`ci.yml` と `test/pr34/` の作業ツリーの版を重ねたもの）でも 3 つの検査が成功すること、`test/pr34/` 自身が削除系の検査に掛からないこと（許可リストに頼らない）も確かめます |
| `mutate_ci.py` | **変異テスト**：`ci.yml` を 1 か所ずつ壊し（許可リスト・エスケープの変異を含む）、`check_ci.py` が必ず失敗を報告すること（見逃し 0 件。FAIL の行を出さずに異常終了した場合も、見逃しとして数えます） |

## 安全上の約束

- 実際のリポジトリの git の状態は変えません（読み取りと、一時ディレクトリの中の `git init`・`git add` だけ）。
- ファイルを削除しません。ケースごとに新しい名前の一時ディレクトリを作ります。
- **このテストのソースに、削除系コマンドの語をそのまま書きません**（`test/pr33/lib/common.sh` の `W_*` と同じ方式）。違反の例のテストデータは、`check_ci.py` のクラス `W` の部品（`"r" "m"` のように、語を分けて書いた文字列）から組み立てます。絵文字の範囲の確認に使う文字も、`\uXXXX` の形か、コードポイント（`U+203C` など）の表記で書きます。CI の hygiene は `test/pr34/` も検査します。
- CI の hygiene の削除系の検査が除外するのは、`test/` 全体ではなく、`ci.yml` の許可リスト（`allowed_files`）の 2 つのファイルだけです。許可リストを増やすときは、理由を書き、`check_ci.py` の `F12` も直します。

## 既知の制約

- 公開鍵 `*.pub.key` も追跡できません（`.gitignore` は `!*.pub.key` で許していますが、CI の hygiene は issue のとおり `*.key` をすべて拒否します）。必要になったら、`ci.yml` の hygiene（secrets）へ除外を足します。

## ユーザーテスト手順（非エンジニア向け）

PR #34 の本文にあります（GitHub の PR 画面の Checks で、4 つの job が緑になることを確認します）。
