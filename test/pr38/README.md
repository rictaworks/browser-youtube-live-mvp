# test/pr38

PR #38（issue #4「アプリケーション: DB スキーマ（15 テーブル）・制約・モデル・所有権の絞り込み」）のテストです。対象は開発サーバー（`scripts/dc.sh` 経由の docker compose）です。

実装担当が書いたテスト（`src/backend/spec/models/` の RSpec 568 件）を、層をまたぐ確認（ソースの走査・`db/structure.sql` の検査・マイグレーションの往復・既存の画面の確認）と合わせて、1 回で実行します。

```bash
scripts/setup_dev_env.sh      # .env を生成します（済んでいれば何も変わりません）
test/pr38/run_all.sh      # すべて（数分かかります）
```

終了コードは、成功が 0、失敗が 1、前提を満たさない場合が 2 です。

## 手順

| 手順 | 確かめること |
|---|---|
| 1. RSpec と RuboCop（`spec/models`） | テスト用 DB を**実行のたびに新しい名前で作り**、`db/structure.sql` から読み込んで、568 件を実行します。15 テーブルの列・型・NULL 可否・主キー、`user_id` の分類（`information_schema` の走査）、一意制約と部分一意索引（終了していない配信は 1 アカウント 1 件。終了した配信は複数可）、列挙の CHECK 制約の符号と契約（`src/contracts/`）の一致、件数・量が負にならないこと、タイトルの寿命の CHECK、外部キーと連鎖削除・NULL 化、索引、`OwnerScope`（2 アカウントで、全 8 モデル）、機密の列の非出力（`inspect` と SQL のログ）、接続チケットの使用済みの印（同時の確保で、1 つだけが成功）、ファクトリ |
| 2. RuboCop | モデル・マイグレーション・テスト補助・ファクトリ |
| 3. Brakeman・bundler-audit | backend 全体（`factory_bot_rails` を足した Gemfile.lock を含む） |
| 4. `scan_sources.py` | この PR の成果物（モデル・マイグレーション・スペック・ファクトリ・`structure.sql`・このディレクトリ）に、絵文字・削除系コマンドの語・資格情報の形式が無い（CI の hygiene と同じ規則を、実行権限の無いファイルにも適用） |
| 5. `scan_ruby_sources.rb` | モデルとマイグレーションに、日本語の文字列リテラル（直書き）・実時計の参照（`Time.now` など）・ファイルを消す呼び出しが無い（Ruby の字句解析。コメントは対象外。検出の仕組み自体も、断片で確かめる） |
| 6. `check_structure_sql.py` | `db/structure.sql` を、ファイルとして、別の実装（Python）で検査します。15 テーブルの列（ER 図）・主キー・列挙の CHECK の符号と `enums.json`・`http-api.md` の一致・非負の CHECK・月の形・タイトルの寿命・索引 26 本（部分一意索引を含む）・外部キー 14 本と削除時の動作・`schema_migrations` の版と `db/migrate` の一致・データの INSERT が無いこと（130 項目） |
| 7. マイグレーションの往復 | 使い捨てのテスト用 DB で、上げる → 全部戻す（16 件。テーブルが残らない）→ 上げ直す（16 件）→ もう一度上げる（何も起きない＝冪等）。上げ直してできた `structure.sql` が、コミット済みの `db/structure.sql` と**一致**する |
| 8. 書き出し直し | `structure.sql` から読み込んだ DB（手順 1 の DB）を書き出し直しても、同じ `structure.sql` になる（`db:schema:load` が再現する） |
| 9. 開発 DB | `db:migrate:status` がすべて `up`。開発 DB から書き出したスキーマが、コミット済みの `db/structure.sql` と一致する（`migrate` のあとの `structure.sql` のコミット漏れの検知） |
| 10. 既存の画面 | 3 層のヘルスチェック（backend `/up`・frontend `/healthz`・relay `/health`）が 200 |
| 11. `structure.sql` の不変 | 実行の前後で、コミット対象の `db/structure.sql` が書き換わっていない |

## issue #4 の受け入れ条件との対応

| 受け入れ条件 | 確かめる手順 |
|---|---|
| 15 テーブル（列・型・NULL 可否・uuid 主キー・自然キー） | 1・6 |
| 制約（一意・部分一意・非負の CHECK・月の主キー・要約値の主キー） | 1・6・7 |
| 列挙の CHECK と契約の一致 | 1・6 |
| 外部キーと削除時の動作（連鎖・NULL 化） | 1・6 |
| 利用者に属するテーブルの `user_id`（`information_schema` の走査） | 1 |
| 接続チケットの要約値と、使用済みの印の原子的な確保 | 1（同時の確保を含む） |
| 部分一意索引・CHECK が `structure.sql` に保存され、`db:schema:load` で再現 | 1・6・7・8・9 |
| 期限監視・保持期間が引く列の索引 | 1・6 |
| モデル・関連・検証・`OwnerScope`・機密の非出力・タイトルの消去・ファクトリ | 1・3・5 |
| 削除系コマンド・絵文字・直書き・実時計が無い | 4・5 |

## 環境変数（任意）

| 変数 | 内容 |
|---|---|
| `TEST_DB_NAME` | 手順 1 と 8 のテスト用 DB の名前。既定は `bl_test_issue4_<日時>`（実行のたびに新しい名前）。`bl_test_` で始まる名前に限ります（開発 DB は使えません） |
| `ROUNDTRIP_DB_NAME` | 手順 7 の使い捨ての DB の名前（既定 `bl_test_issue4_roundtrip`）。毎回、全部戻してから使います |

## 安全上の約束

- ファイルも DB も削除しません。作業用の一時ファイルは `mktemp` の場所に残します（最後に場所を表示します）。使い終わった `bl_test_issue4_*` の DB は、必要なら手動で削除してください。
- 開発 DB（`bl_development`）には、読み取りだけ（`db:migrate:status` と、書き出し先を `/tmp` に向けた `db:schema:dump`）です。スキーマを書き出す Rails のコマンドは、すべて、書き出し先（`SCHEMA`）を `/tmp` に向けて実行し、コミット対象の `db/structure.sql` を書き換えません（手順 11 で確かめます）。
- テスト用 DB を相手にするコマンドは、DB 名が `bl_test_` で始まることと、コンテナの `DATABASE_URL` が開発 DB を指していることを確かめてから、DB 名を差し替えます。
- ハーネスの安全（`.claude/TEST-HARNESS-SAFETY.md`）: 自己再帰ガード（`ISSUE4_RUN_ALL_ACTIVE`）・`ulimit -u`・各手順の `timeout`。
- このディレクトリのソースに、削除系コマンドの語と絵文字を書きません（CI の hygiene が検査します。語を書く必要がある走査器は、語を分けて組み立てます）。

## ユーザーテスト手順（非エンジニア向け）

PR の本文にあります。この PR は、画面の変更がありません（DB のスキーマとモデルだけです）。確認することは、既存の画面が影響を受けていないことです。

1. 開発サーバーを起動します（`scripts/dc.sh up -d --wait`）。
2. ブラウザで `http://localhost:3000/terms` と `http://localhost:3000/privacy` を開き、従来どおり表示されることを確認します（ログインは、この PR にはまだありません）。
3. 開発者が `scripts/dc.sh exec -T backend bin/rails db:migrate` を実行し、`TEST_DB_NAME=bl_test_issue4 scripts/test_backend.sh spec/models` が緑になることを確認します。
