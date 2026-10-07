#!/usr/bin/env bash
# pr33-timeout: 900
# テスト用 DB の保護（issue #1「テストは scripts/test_backend.sh が RAILS_ENV=test と専用の DATABASE_URL を明示して実行し、開発 DB を壊さない」）。
# テストが開発 DB（bl_development）を壊す事故を、3 つの層が防ぐ。各層を、実際の開発サーバーで確かめる。
#   層 1  scripts/test_backend.sh（ホスト）: テスト用ではない DB 名は、docker を呼ばずに、終了コード 2 で拒否する
#   層 2  scripts/container/test_backend.sh（コンテナの中）: DB 名・DATABASE_URL を確かめ、DB へ接続する前に、終了コード 2 で止まる
#   層 3  spec/rails_helper.rb のガード: コンテナの RAILS_ENV=development のまま RSpec を直接実行する事故を、RSpec が止める
# そのうえで、実際に scripts/test_backend.sh を（別の TEST_DB_NAME で）実行し、開発 DB のスキーマ・内容が変わらないことを確かめる。
#
# 後始末のために削除はしない。テスト用 DB は、専用の名前（bl_test_pr33）を使い、再実行すると同じ DB を再利用する。
# （この DB は開発用 PostgreSQL に残る。不要になったら、手動で削除してください）
set -uo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_tools docker jq grep wc tail sha256sum awk
SPY_DIR="$PR33_DIR/fixtures/spy_bin"
[[ -x "$SPY_DIR/docker" ]] || abort "fixtures/spy_bin/docker が実行できません"
require_stack_healthy

TEST_DB="bl_test_pr33"
work="$(new_tmpdir testdb)"
SPY_LOG="$work/spy.log"
: >"$SPY_LOG"

# db_query <SQL> [DB 名]: backend のコンテナの中で psql を実行し、結果（タブ区切りの値だけ）を返す。
# 接続先は、DATABASE_URL（開発 DB）。DB 名を指定すれば、同じサーバーのその DB。SQL は標準入力で渡す（引用符の入れ子を避ける）。
# 資格情報は、コンテナの中の DATABASE_URL から読まれ、ホストへは出ない
db_query() {
  in_container backend sh -c 'if [ -n "$1" ]; then exec psql "${DATABASE_URL%/*}/$1" -tA; else exec psql "$DATABASE_URL" -tA; fi' sh "${2:-}" <<<"$1" 2>/dev/null | tr -d '\r'
}

# 開発 DB のスキーマ・メタデータの指紋（列・索引・制約・ar_internal_metadata・schema_migrations の内容）。
# pg_dump の出力は、実行のたびに変わる乱数（\restrict）を含むため、使わない
FINGERPRINT_SQL="
select 'column', table_name, column_name, data_type, is_nullable from information_schema.columns where table_schema = 'public' order by 2, 3;
select 'index', indexname, indexdef from pg_indexes where schemaname = 'public' order by 2;
select 'constraint', conname, pg_get_constraintdef(oid) from pg_constraint where connamespace = 'public'::regnamespace order by 2;
select 'metadata', key, value from ar_internal_metadata order by 2;
select 'migration', version from schema_migrations order by 2;
"
dev_db_fingerprint() {
  db_query "$FINGERPRINT_SQL"
}
dev_db_tables() {
  db_query "select count(*) from information_schema.tables where table_schema = 'public'"
}
dev_db_environment() {
  db_query "select value from ar_internal_metadata where key = 'environment'"
}
fingerprint_before="$(dev_db_fingerprint)"
tables_before="$(dev_db_tables)"
if [[ -n "$fingerprint_before" && "$tables_before" =~ ^[0-9]+$ ]] && grep -q '^metadata' <<<"$fingerprint_before"; then
  pass "開発 DB（bl_development）のスキーマ・メタデータ（$(wc -l <<<"$fingerprint_before") 行）とテーブル数（${tables_before}）を記録した（以後の比較の基準）"
else
  abort "開発 DB のスキーマ・メタデータを取得できませんでした"
fi
# 前後の比較。違いがあれば、差分を示す（スキーマの情報だけで、秘密値を含まない）
expect_same_dev_db() {
  local label="$1" now
  now="$(dev_db_fingerprint)"
  if [[ "$now" == "$fingerprint_before" ]]; then
    pass "$label"
  else
    fail "$label（差分: $(diff <(echo "$fingerprint_before") <(echo "$now") | head -n 6 | tr '\n' ' ')）"
  fi
}

# --- 層 1: ホストのスクリプト ---
section "層 1: scripts/test_backend.sh は、テスト用ではない DB 名を、docker を呼ばずに拒否する"
run_host_script() {
  # run_host_script <TEST_DB_NAME の値> [引数...]: 偽の docker を PATH の先頭に置いて scripts/test_backend.sh を実行する
  local name="$1"
  shift
  local before after
  before="$(wc -l <"$SPY_LOG")"
  HOST_OUT="$(TEST_DB_NAME="$name" PATH="$SPY_DIR:$PATH" PR33_SPY_LOG="$SPY_LOG" "$ROOT_DIR/scripts/test_backend.sh" "$@" 2>&1)"
  HOST_STATUS=$?
  after="$(wc -l <"$SPY_LOG")"
  HOST_CALLS=$((after - before))
}
refused_names=(
  "bl_development"
  "BL_DEVELOPMENT"
  "postgres"
  "template0"
  "template1"
  "bl_production"
  "bl_development; DROP DATABASE bl_development; --"
  "bl_test;echo x"
  "bl_test\$(echo x)"
  "bl test"
  "../bl_test"
)
for name in "${refused_names[@]}"; do
  run_host_script "$name"
  if [[ "$HOST_STATUS" -eq 2 && "$HOST_CALLS" -eq 0 ]] && grep -q 'TEST_DB_NAME' <<<"$HOST_OUT"; then
    pass "TEST_DB_NAME=「${name}」は、docker を呼ばずに、終了コード 2 で拒否される"
  else
    fail "TEST_DB_NAME=「${name}」は、docker を呼ばずに、終了コード 2 で拒否される（終了コード ${HOST_STATUS}。docker の呼び出し ${HOST_CALLS} 回）"
  fi
done
# 対照: テスト用の名前は拒否されない（偽の docker まで進み、そこで失敗する）
for name in "bl_test" "bl_test_pr33" "issue5_test"; do
  run_host_script "$name"
  if [[ "$HOST_STATUS" -eq 97 && "$HOST_CALLS" -ge 1 ]]; then
    pass "対照: TEST_DB_NAME=「${name}」（テスト用の名前）は拒否されず、docker の呼び出しまで進む"
  else
    fail "対照: TEST_DB_NAME=「${name}」（テスト用の名前）は拒否されず、docker の呼び出しまで進む（終了コード ${HOST_STATUS}。docker の呼び出し ${HOST_CALLS} 回）"
  fi
done
HOST_OUT="$(env -u TEST_DB_NAME PATH="$SPY_DIR:$PATH" PR33_SPY_LOG="$SPY_LOG" "$ROOT_DIR/scripts/test_backend.sh" 2>&1)"
HOST_STATUS=$?
expect_eq "対照: TEST_DB_NAME が未設定なら、既定のテスト用 DB（bl_test）で、docker の呼び出しまで進む" "97" "$HOST_STATUS"

# --- 層 2: コンテナの中のスクリプト（DB へ接続する前に止まる） ---
section "層 2: コンテナの中の scripts/container/test_backend.sh は、DB へ接続する前に、終了コード 2 で止まる"
container_check() {
  # container_check <説明> <期待する語> <docker compose exec の引数...>
  local label="$1" expected_word="$2"
  shift 2
  local out status
  out="$("$DC" exec -T "$@" backend bash /scripts/test_backend.sh 2>&1)"
  status=$?
  if [[ "$status" -eq 2 ]] && grep -q "$expected_word" <<<"$out"; then
    pass "$label（終了コード 2）"
  else
    fail "$label（終了コード ${status}。出力: $(head -c 150 <<<"$out" | tr '\n' ' ')）"
  fi
}
container_check "TEST_DB_NAME=bl_development は拒否される" "テスト用の DB 名として使えません" -e TEST_DB_NAME=bl_development
container_check "TEST_DB_NAME が渡されていなければ拒否される" "TEST_DB_NAME が渡されていません" -e TEST_DB_NAME=
container_check "DATABASE_URL が開発 DB（.../bl_development）を指していなければ拒否される（テスト用の URL を組み立てる元が不正）" "DATABASE_URL" \
  -e TEST_DB_NAME="$TEST_DB" -e DATABASE_URL=postgres://dummy:dummy@db:5432/postgres

# --- 層 3: RSpec のガード ---
section "層 3: コンテナの RAILS_ENV=development のまま RSpec を直接実行する事故を、RSpec が止める"
rspec_guard_check() {
  # rspec_guard_check <説明> <期待する語> <docker compose exec の環境変数オプション...>
  local label="$1" expected_word="$2"
  shift 2
  local out status
  out="$("$DC" exec -T "$@" backend bundle exec rspec spec/config/database_spec.rb 2>&1)"
  status=$?
  if [[ "$status" -ne 0 ]] && grep -q "$expected_word" <<<"$out" && grep -q '0 examples, 0 failures' <<<"$out" && grep -q 'error occurred outside of examples' <<<"$out"; then
    pass "$label（終了コード ${status}。例外で止まり、1 つのテストも実行されない: 0 examples）"
  else
    fail "$label（終了コード ${status}。出力: $(head -c 150 <<<"$out" | tr '\n' ' ')）"
  fi
}
rspec_guard_check "RAILS_ENV=development（コンテナの既定）のまま RSpec を直接実行すると、RSpec が止める" "RAILS_ENV=development"
rspec_guard_check "RAILS_ENV=test でも、DATABASE_URL が開発 DB を指したままなら、RSpec が止める（開発 DB のスキーマを作り直さない）" "not a test database name" -e RAILS_ENV=test

# --- 開発 DB は無傷 ---
section "ここまでの拒否・事故の再現のあとも、開発 DB（bl_development）は変わらない"
expect_same_dev_db "開発 DB のスキーマ・メタデータ（列・索引・制約・ar_internal_metadata・schema_migrations）が同じ"
expect_eq "開発 DB のテーブル数が同じ" "$tables_before" "$(dev_db_tables)"

# --- 実際に scripts/test_backend.sh を実行する（別の TEST_DB_NAME） ---
section "実際に TEST_DB_NAME=${TEST_DB} scripts/test_backend.sh を実行する（テスト用 DB は、無ければ作り、スキーマを読み込む）"
real_out="$(TEST_DB_NAME="$TEST_DB" "$ROOT_DIR/scripts/test_backend.sh" spec/config/database_spec.rb 2>&1)"
real_status=$?
if [[ "$real_status" -eq 0 ]]; then
  pass "scripts/test_backend.sh spec/config/database_spec.rb が成功した（終了コード 0）"
else
  fail "scripts/test_backend.sh spec/config/database_spec.rb が成功した（終了コード ${real_status}。出力の末尾: $(tail -n 8 <<<"$real_out" | tr '\n' ' ')）"
fi
if grep -q "テスト用 DB: ${TEST_DB}（RAILS_ENV=test）" <<<"$real_out"; then pass "テストは、RAILS_ENV=test・専用のテスト用 DB（${TEST_DB}）で実行された（スクリプトの表示）"; else fail "テストは、RAILS_ENV=test・専用のテスト用 DB（${TEST_DB}）で実行された"; fi
if grep -qE '6 examples, 0 failures' <<<"$real_out"; then pass "database_spec の 6 件が成功した（テスト用 DB に接続し、current_database が ${TEST_DB}）"; else fail "database_spec の 6 件が成功した（出力: $(grep -E 'examples,' <<<"$real_out" | head -n 1)）"; fi
databases="$(db_query "select datname from pg_database where not datistemplate order by 1" | tr '\n' ' ' | sed 's/ $//')"
if grep -qw "$TEST_DB" <<<"$databases" && grep -qw bl_development <<<"$databases"; then
  pass "テスト用 DB（${TEST_DB}）が、開発 DB とは別に作られている（データベース: ${databases}）"
else
  fail "テスト用 DB（${TEST_DB}）が、開発 DB とは別に作られている（データベース: ${databases}）"
fi
expect_eq "テスト用 DB の ar_internal_metadata の環境は test" "test" "$(db_query "select value from ar_internal_metadata where key = 'environment'" "$TEST_DB")"
expect_same_dev_db "実際のテストの実行のあとも、開発 DB のスキーマ・メタデータが同じ"
expect_eq "実際のテストの実行のあとも、開発 DB のテーブル数が同じ" "$tables_before" "$(dev_db_tables)"
expect_eq "実際のテストの実行のあとも、開発 DB の環境の記録は development" "development" "$(dev_db_environment)"
if stack_is_healthy; then pass "実際のテストの実行のあとも、4 サービスが running・healthy"; else fail "実際のテストの実行のあとは、4 サービスが running・healthy ではない"; fi

finish
