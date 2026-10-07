# test/pr39

PR #39（issue #5「アプリケーション Domain Core（1）: 利用日・割り当て日・設定値・開始受付判定・割り当ての予約と記帳・転送量の判定」）のテストです。対象は開発サーバー（`scripts/dc.sh` 経由の docker compose の backend コンテナ）です。

実装担当が書いた RSpec（Rails も DB も使わない純粋な Ruby のスペック）に加えて、別の角度の確認（黒箱の受け入れ・規則の走査・要件の差分・変異テスト）を、1 回で実行します。

```bash
scripts/setup_dev_env.sh                 # .env を生成します（済んでいれば何も変わりません）
test/pr39/run_all.sh                     # 手順 1〜10（数分）
test/pr39/run_all.sh --with-mutation     # 手順 11（変異テスト。さらに数分）も実行します
```

終了コード: 0 = すべて成功、1 = 失敗がある、2 = 準備ができていない（`.env` が無い・引数の誤り）。各手順のログは、`mktemp` で作る一時ディレクトリに残ります（削除しません。場所は実行の最初と最後に表示します）。

| 手順 | 確かめること |
|---|---|
| 1 | `scripts/test_backend.sh --no-db`: この issue のスペック 13 ファイルと、契約（#3）のスペックを、Rails を起動せずに実行します（RuboCop を含む）。契約のスペックの補助（素の Zeitwerk のローダー）と、`spec/domain/support/domain_loader.rb` が、ランダムな順序でも衝突しないことの確認を兼ねます |
| 2 | RuboCop（omakase）を、`app/domain` のこの issue のファイルに掛けます |
| 3 | `spec/config/application_spec.rb`（`rails_helper` を読み、Rails が `app/domain` を管理する）と、この issue のスペックを同じ実行にします。Rails のローダーが先に `app/domain` を管理しても、`DomainLoader` が衝突せず、スペックが通ること（DB を使います。`TEST_DB_NAME` 既定 `bl_test_issue5`） |
| 4 | 手順 3 を、Rails の `eager_load` を有効にして（CI と同じ `CI=true`）実行します。`app/domain` のすべてのファイルが、Rails の eager load で読み込めること |
| 5 | `acceptance.rb`: 黒箱の受け入れの確認です。issue の受け入れ条件（日付の算出・設定値・開始受付判定・割り当て台帳・転送量）を、公開の API だけで、37 項目確かめます |
| 6 | `differential_calendar.rb`: 暦の差分検査です。`UsageCalendar`（TZInfo のタイムゾーン定義）の 6 つの関数を、OS の libc のタイムゾーン処理（`TZ` 環境変数と `Time.local`）を基準にした独立の算出と、約 3.3 万の時刻（乱数と、夏時間の切り替え・日付の境界の前後 2 時間）で突き合わせます。固定の時差の誤りを、広い範囲で検出します（`ISSUE05_DIFF_SAMPLES` で乱数の時刻の数を変えられます。既定 2 万） |
| 7 | `scan_domain.rb`: `app/domain` のすべてのファイルを、Ruby の字句解析（Ripper）で走査します。入出力・環境の型（`Rails`・`ActiveRecord`・`ENV`・`File` など）、実時計（`Time.now`・`Date.today`・`Time.current` など）、グローバル変数、出力・乱数・待機、文字列リテラルの日本語、契約の固定値（500・550・340・210・9,000・10,000）の数値の直書きが無いこと |
| 8 | `scan_sources.py --self-test`: ソース走査器の自己検査です。合成した小さなソース（58 件）で、走査器が、違反を見逃さず（削除系の語・ブロック形式の一時ディレクトリの作成・絵文字・不可視の書式文字）、違反でないもの（ブロックなしの作成・コメント・別の名前）を誤検知しないことを確かめます |
| 9 | `scan_sources.py`: `app/domain`・`spec/domain`・このディレクトリに、削除系コマンド・標準ライブラリが自動でファイル・ディレクトリを削除する呼び出し（ブロック形式の `Dir.mktmpdir`・`Tempfile`。一時ディレクトリは、ブロックなしで作り、後始末は OS に任せます）・絵文字・不可視の書式文字（ゼロ幅スペースなど）が無く、UTF-8 として読めること（CI の hygiene と同じ規則を、コメントも含めて適用します） |
| 10 | `check_requirements_diff.py`: `requirements.md` の変更が、8 章の制限値の表への「bot 判定のスコアの閾値」の 1 行の追記だけ（追記 1 行・削除 0 行）で、20.4 の設定 9 件・19 章の設定の画面と矛盾しないこと |
| 11 | `mutate_domain.rb`（`--with-mutation`）: 実装を 1 か所ずつ壊し（42 種。割り当て日を UTC-8 や UTC-7 の固定にする、判定順を入れ替える、境界の不等号を変える、枠の取り崩しを許す、不正な設定を既定値へ戻す、など）、スペックが必ず失敗することを確かめます。コンテナの `/tmp` に複製を作ります（削除しません） |

## ユーザーから見える変更

ありません。Domain Core（入出力に依存しない純粋な Ruby）と、`requirements.md` の 1 行の追記だけです。画面・API の挙動は変わりません。確認は、開発者が `scripts/test_backend.sh --no-db spec/domain` を実行して、緑になることです。

## 実装担当のスペックの範囲（`src/backend/spec/domain/`）

| ファイル | 内容 |
|---|---|
| `usage_calendar_spec.rb` | 利用日（JST 03:00 区切り）・割り当て日（太平洋時間。夏時間の切り替え 2026-03-08・2026-11-01 の前後。固定の UTC-8・UTC-7 では誤る時刻を含む）・次の区切り・暦月 |
| `settings_spec.rb` | 9 設定・既定値（契約）・文字列の型変換・範囲外と型違いの例外 |
| `transfer_budget_policy_spec.rb` | 積算が予算に達した月は不可（1 GB = 10 億バイト） |
| `quota_policy_spec.rb`・`quota_policy_simulation_spec.rb` | 予約（9,000 の境界・17 本目・割り当て超過の日）・記帳（準備・確認枠と終了・清算枠の分離）・共通枠・割り当て日をまたぐ移し替え・解放・8.4 の単価表のシミュレーション |
| `account_snapshot_spec.rb`・`admission_spec.rb`・`start_admission_input_spec.rb` | 現況・結果（受理・拒否）・入力の検証 |
| `start_admission_spec.rb` | 開始受付判定: 14 の拒否理由・判定順（91 組の 2 つの組み合わせのうち 88 組）・遅延評価の呼び出し回数・境界値・暦との結合 |
| `domain_rules_spec.rb`・`domain_core_rules_spec.rb`・`app_domain_loading_spec.rb`・`domain_loader_spec.rb` | Domain Core の規則の走査器とその適用・Zeitwerk の規則での読み込み・読み込みの補助 |

## 補足

- `spec/domain/support/domain_loader.rb` は、`app/domain` を Zeitwerk で読み込む補助です。ローダーの設定は、スイートの開始時（`before(:suite)`）に行うため、スペックの読み込み中（`describe` の本体）では、Domain Core の定数を参照できません（`it`・`let`・`before` の中で参照します）。
- 外部サービス（Google・YouTube・reCAPTCHA）は呼びません。この issue は、DB へ書き込みません（Domain Core のみ）。
