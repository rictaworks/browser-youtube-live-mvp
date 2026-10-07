# test/pr45

PR #45（issue #9「アプリケーション: 利用枠・開始試行・割り当て台帳・転送量・設定の DB 実装」）のテストです。対象は開発サーバー（`scripts/dc.sh` 経由の docker compose の backend コンテナと db コンテナ）です。

実装担当が書いた RSpec（`src/backend/spec/services/` の 11 ファイル・463 件。複数の接続による同時の操作を含む）に加えて、別の角度の確認（黒箱の受け入れ・多数のスレッドによる負荷・ソースの走査・変異テスト）を、1 回で実行します。

```bash
scripts/setup_dev_env.sh                   # .env を生成します（済んでいれば何も変わりません）
test/pr45/run_all.sh                   # 手順 1〜9・11（数分）
test/pr45/run_all.sh --with-mutation   # 手順 10（変異テスト。さらに数分）も実行します
```

終了コードは、成功が 0、失敗が 1、準備ができていない場合（`.env` が無い・引数の誤り・コンテナに入れない）が 2 です。作業用の一時ファイルは、`mktemp` の場所に残ります（場所は実行の最初と最後に表示します）。

## 手順

| 手順 | 確かめること |
|---|---|
| 1. RSpec と RuboCop | テスト用 DB を**実行のたびに新しい名前で作り**、`db/structure.sql` から読み込んで、この issue のスペック 11 ファイル（463 件）を実行します。`scripts/test_backend.sh` が呼ぶ、コンテナの中の同じスクリプトです（`up --wait` を経由しないので、他の作業で backend のヘルスチェックだけが赤くても、実行できます） |
| 2. RuboCop | `app/services` のこの issue のファイル（`daily_allowance.rb`・`quota_ledger.rb` と `quota_ledger/`・`transfer_budget.rb`・`settings_store.rb`） |
| 3. Brakeman・bundler-audit | backend 全体 |
| 4. Zeitwerk の検査 | `bin/rails zeitwerk:check`。eager load で、すべての定数（`QuotaLedger::Rows`・`QuotaLedger::Arguments` を含む）が読み込めること。CI（`CI=true` で eager load）と同じ条件の確認です |
| 4b. eager_load を有効にした RSpec | CI（GitHub Actions）と同じ `CI=true`（Rails の eager_load を有効にする）で、`settings_store_spec.rb`・`service_sources_spec.rb`・`quota_ledger_reserve_spec.rb` を実行します |
| 5. 受け入れの確認（`acceptance.rb`） | 黒箱です。RSpec を使わず、公開の API（`DailyAllowance`・`QuotaLedger`・`TransferBudget`・`SettingsStore`）だけを呼び、issue の受け入れ条件を 42 項目、1 つずつ確かめます。台帳の値は、モデルを介さない SQL で読み、**明細と配信の残額から独立に再計算した値**と比べます。各確認はトランザクションの中で行い、巻き戻します。公開メソッドの形（引数の名前・必須か任意か）も、issue の記述と照らします |
| 6. 負荷確認（`stress.rb`） | 接続のプールを 32 にして、**最大 24 スレッド**が同時に挑みます（実装担当のスペックは、既定のプール 5 に合わせた最大 4 スレッド）。24 本の同時の予約が 16 本だけ成功する・同じ配信への 24 本の消費が 1 回だけ・上限 3 回の開始試行に 4 つの配信が挑むと計上が合計 3 回・24 本の同時の付与が 1 つも失われない・共通枠 500 への 24 本の支出が 20 回だけ成功する・割り当て日をまたぐ 24 本の支出が予約を 1 回だけ移す・48 回の送出量の報告が 1 つも失われない・予約と支出（日をまたぐものを含む）と移し替えと解放と共通枠を入り混ぜた 480 回の操作が、デッドロックも例外もなく、台帳が整合する、ことを確かめます。使い捨ての DB へ実際にコミットします |
| 7. サービスの走査（`scan_services.rb`） | `app/services` のこの issue のファイルを、Ruby の字句解析で走査します（コメントは対象外）。日本語の文字列リテラル・実時計（`now:` の既定値の `Time.current` だけは許す）・契約の固定値（550・340・210・500・9,000・10,000・1 GB）の直書き・行やファイルを消す呼び出し・`requires_new`・グローバル変数・クラス変数・広い `rescue`・参加できない形のトランザクション・外部への入出力が無いこと。実装担当のスペック（`service_sources_spec.rb`）とは別の実装による、相互の確認です |
| 8. 成果物の走査（`scan_sources.py`） | この PR の成果物（サービス・スペック・スペックの補助・このディレクトリ）に、絵文字・削除系コマンドの語・資格情報の形式が無いこと。CI の hygiene と同じ規則を、実行権限の無いファイルにも適用します |
| 9. 既存の画面 | 3 層のヘルスチェック（backend `/up`・frontend `/healthz`・relay `/health`）が 200 |
| 10. 変異テスト（`mutate_services.rb`。`--with-mutation` のとき） | コンテナの `/tmp` にアプリケーションの複製を作り、サービスの実装を 25 通りに壊して、対応するスペックが失敗する（検出する）ことを確かめます。台帳の行や配信の行のロックを外す・消費済みの印を見ない・上限を見ない・加算を上書きにする・設定をキャッシュする・壊れた設定を既定値へ戻す・暦月を UTC にする・割り当て日を UTC の日付にする・時計のずれで予約を後戻りさせる・保存点を作る・実時計を読む・契約の固定値を直書きする、など。共有の作業ツリーは書き換えません |
| 11. `structure.sql` の不変 | 実行の前後で、コミット対象の `db/structure.sql` が書き換わっていないこと |

## issue #9 の受け入れ条件との対応

| 受け入れ条件 | 確かめる手順・スペック |
|---|---|
| `DailyAllowance.remaining`・`attempts_remaining`（下限 0。行が無ければ 0 件。行を作らない） | 1（`daily_allowance_spec.rb`）・5 |
| `DailyAllowance.consume!`（受理時の利用日に紐づく・二重に消費しない・利用枠が無ければ例外） | 1（`daily_allowance_spec.rb`・`daily_allowance_concurrency_spec.rb`）・5・6 |
| `DailyAllowance.count_attempt!`（準備の開始と同一のトランザクション・冪等・上限で例外） | 1・5・6 |
| `DailyAllowance.grant_extra!`（追加の 1 回と開始試行の 0 への復帰・upsert） | 1・5・6 |
| `DailyAllowance.ensure_for!`（受理が使う upsert。FOR UPDATE） | 1・5・6 |
| `QuotaLedger.reserve!`（上限 9,000 の境界・16 本・超過の日は予約しない・配信の枠 340/210 と割り当て日の設定） | 1（`quota_ledger_reserve_spec.rb`）・5・6 |
| `QuotaLedger.spend!`（該当する枠にだけ残額があれば可・終了・清算枠は settle 以外で取り崩さない・失敗でも実費を記帳） | 1（`quota_ledger_spend_spec.rb`）・5・6 |
| `QuotaLedger.spend_common!`（共通枠 500・尽きたら false） | 1・5・6 |
| `QuotaLedger.carry_over!`（割り当て日をまたいだ移し替え。予約中が負にならない。`spend!` が内部で行う） | 1（`quota_ledger_carry_release_spec.rb`）・5・6 |
| `QuotaLedger.release!`（冪等。二重に解放しない。呼ぶ時点は呼び出し側の責務） | 1・5・6 |
| `QuotaLedger.mark_exhausted!`（超過の日は予約しない。進行中の配信の記帳は続く） | 1（`quota_ledger_reserve_spec.rb`・`quota_ledger_spend_spec.rb`）・5 |
| 共通枠・安全余裕・予約の内訳は固定値（設定値にしない）。`daily_total` のみ設定値 | 1（予約額は 550 以外を拒否）・7 |
| `TransferBudget.add!`・`exceeded?`・`add_for_broadcast!`（同一のトランザクション。暦月は JST） | 1（`transfer_budget_spec.rb`・`transfer_budget_concurrency_spec.rb`）・5・6 |
| `SettingsStore.current`（キャッシュしない・壊れた値は例外）・`update!`（検証して upsert・未知のキー・範囲外・型違いは例外） | 1（`settings_store_spec.rb`）・5・6 |
| 並行性: 残りが 1 本分のとき同時の 2 本で 1 本だけ成功・同時 N 本で成功が 16 本を超えない・予約中が負にならない | 1（`quota_ledger_concurrency_spec.rb`）・6 |
| 並行性: 同じ配信への同時の消費・計上が 1 回だけ | 1（`daily_allowance_concurrency_spec.rb`）・6 |
| 台帳の整合: ランダムな操作列（固定のシード）のあとで、`used_units`・`reserved_units` が、明細と配信の残額から再計算した値と一致する | 1（`quota_ledger_invariants_spec.rb`）・5・6 |
| 台帳の明細に、トークン・配信キー・タイトルが含まれない（`method` は呼び出しの種別だけ） | 1（`quota_ledger_spend_spec.rb`）・5 |
| トランザクションの内側で使える（外側に参加する。`requires_new` を使わない。SAVEPOINT を作らない）。途中で失敗したら、すべて取り消される | 1（各スペックの「原子性」・`*_concurrency_spec.rb` の「途中で失敗したときの取り消し」）・7・10 |
| RSpec・RuboCop・brakeman が緑 | 1・2・3 |

## 実装担当のスペックの範囲（`src/backend/spec/services/`）

| ファイル | 件数 | 内容 |
|---|---|---|
| `settings_store_spec.rb` | 70 | 既定値・9 設定の型変換・キャッシュしない・壊れた値の例外（11 種）・`update!` の検証（18 種の不正な入力）・正規の形での保存・`intake_paused`・操作の記録を書かない |
| `transfer_budget_spec.rb` | 65 | 加算・予算の境界（10 GB = 100 億バイト。ちょうどで不可）・暦月の形の検証・JST の暦月の境目（利用日の 03:00 区切りではない）・配信と月次の同一のトランザクション |
| `transfer_budget_concurrency_spec.rb` | 9 | 同時の加算が失われない・月次の積算の失敗で配信の加算も取り消される・設定の同時の更新 |
| `daily_allowance_spec.rb` | 81 | 残りの計算（表）・`ensure_for!`・`consume!`（冪等・上限で例外・受理時の利用日・所有権）・`count_attempt!`・`grant_extra!` |
| `daily_allowance_concurrency_spec.rb` | 12 | 行ロックの持続・同時の付与・同じ配信への同時の消費と計上・2 つの配信の上限の競合・途中で失敗したときの取り消し |
| `quota_ledger_reserve_spec.rb` | 54 | 読み取り・予約（9,000 の境界の表・16 本・超過の日・前提を満たさない配信の例外・引数の検査・原子性）・超過の印 |
| `quota_ledger_spend_spec.rb` | 85 | 記帳（枠の分離・8.4 の単価表の最大の支出が収まる・失敗の実費・断られた支出・呼び出しの種別の形 27 種）・共通枠（500 の境界） |
| `quota_ledger_carry_release_spec.rb` | 52 | 移し替え（冪等・後戻りの拒否・新しい日の空きを検査しない）・日またぎの記帳（夏時間・標準時の境目。時計のずれ）・解放（冪等） |
| `quota_ledger_invariants_spec.rb` | 4 | ランダムな操作列（シード 3 つ。各 160 回）の各操作のあとで、台帳が再計算した値と一致し、配信ごとの保存則が成り立つ |
| `quota_ledger_concurrency_spec.rb` | 20 | 予約の上限（16 本・残り 1 本）・記帳の上限・解放・移し替え・日またぎの支出・入り混じった操作（デッドロックしない）・途中で失敗したときの取り消し |
| `service_sources_spec.rb` | 11 | ソースの規則（日本語の直書き・実時計・契約の固定値・消す呼び出し・`requires_new`・グローバル変数・広い `rescue`・トランザクションの形） |

補助は `spec/services/support/ledger_support.rb`（台帳の再計算・同時の実行・コミットする例の行の整理）です。

## 環境変数（任意）

| 変数 | 内容 |
|---|---|
| `TEST_DB_NAME` | 手順 1 のテスト用 DB の名前。既定は `bl_test_issue9_<日時>`（実行のたびに新しい名前）。`bl_test_` で始まる名前に限ります（開発 DB は使えません） |
| `SCRATCH_DB_NAME` | 手順 5・6 の使い捨ての DB の名前（既定 `<TEST_DB_NAME>_scratch`） |
| `MUTATION_DB_NAME` | 手順 10 の使い捨ての DB の名前（既定 `<TEST_DB_NAME>_mut`） |

## 安全上の約束

- ファイルも DB も削除しません。作業用の一時ファイルは `mktemp` の場所に、変異テストの複製はコンテナの `/tmp` に残します。使い終わった `bl_test_issue9_*` の DB は、必要なら手動で削除してください。実際にコミットする同時の操作のスペック（`*_concurrency_spec.rb`）だけは、各例の前後に、自分が作った行（アカウント・配信・台帳の行と明細・暦月の積算・設定の行）を、SQL で整理します。
- 開発 DB（`bl_development`）は使いません。テスト用 DB を相手にするコマンドは、DB 名が `bl_test_` で始まることと、コンテナの `DATABASE_URL` が開発 DB を指していることを確かめてから、DB 名を差し替えます。`db:prepare` の書き出し先（`SCHEMA`）は `/tmp` に向け、コミット対象の `db/structure.sql` は書き換えません（手順 11 で確かめます）。
- 実際の Google・YouTube は呼びません（この issue は DB だけを扱います）。
- ハーネスの安全（`.claude/TEST-HARNESS-SAFETY.md`）: 自己再帰ガード（`ISSUE09_RUN_ALL_ACTIVE`）・`ulimit -u`・各手順の `timeout`。
- このディレクトリのソースに、削除系コマンドの語と絵文字を書きません（CI の hygiene が検査します。語を書く必要がある走査器は、語を分けて組み立てます）。

## ユーザーテスト手順（非エンジニア向けの草案）

この PR は、画面の変更がありません（アプリケーション層の内部の部品と、その試験だけです）。ユーザーから見える変更は無く、確認することは、**既存の画面が影響を受けていないこと**と、**開発者の試験が緑になること**です。

1. 開発サーバーを起動します（`scripts/dc.sh up -d --wait`）。
2. ブラウザで `http://localhost:3000/` を開き、これまでと同じランディングが表示されることを確認します。続けて `http://localhost:3000/terms`（利用規約）と `http://localhost:3000/privacy`（プライバシーポリシー）を開き、従来どおり表示されることを確認します。ログインの画面と、YouTube への配信は、この PR では変わりません（配信の受付は後続の PR です）。
3. 開発者が `test/pr45/run_all.sh` を実行し、最後に `PASS PR #45 のテストはすべて成功しました` と表示されることを確認します（`scripts/test_backend.sh --db spec/services/quota_ledger_reserve_spec.rb` のように、スペックを個別に実行することもできます）。
