#!/usr/bin/env bash
# PR #38（issue #4「アプリケーション: DB スキーマ（15 テーブル）・制約・モデル・所有権の絞り込み」）のテスト一式。
# 対象は開発サーバー（scripts/dc.sh 経由の docker compose）。層をまたいで、1 回で実行する。
#
#    1. RSpec（spec/models。テスト用 DB を新しく作り、db/structure.sql から読み込む）と、spec/models の RuboCop
#    2. RuboCop（モデル・マイグレーション・テスト補助・ファクトリ）
#    3. Brakeman・bundler-audit（backend 全体）
#    4. 走査: 絵文字・削除系コマンドの語・資格情報の形式（成果物すべて。scan_sources.py）
#    5. 走査: 日本語の文字列リテラル・実時計の参照・ファイルを消す呼び出し（Ruby の字句解析。scan_ruby_sources.rb）
#    6. db/structure.sql をファイルとして検査（列・型・NULL 可否・符号と契約の一致・索引・外部キー・版。check_structure_sql.py）
#    7. マイグレーションの往復（上げる→全部戻す→上げる→もう一度上げる）。できた structure.sql が、コミット済みと一致する
#    8. structure.sql から読み込んだテスト用 DB を書き出し直しても、同じ structure.sql になる（db:schema:load が再現する）
#    9. 開発 DB が最新で、書き出したスキーマが、コミット済みの structure.sql と一致する
#   10. 既存の画面（3 層のヘルスチェック）が、影響を受けていない
#
# 使い方: このスクリプトを実行する（作業ディレクトリは問わない）。
#   scripts/setup_dev_env.sh   # .env の生成（済んでいれば不要）
#   <このディレクトリ>/run_all.sh
# 環境変数（任意）:
#   TEST_DB_NAME        1 と 8 に使うテスト用 DB の名前。既定は、実行のたびに新しい名前（bl_test_issue4_<日時>）。
#                       bl_test_ で始まる名前に限る（開発 DB は使えない）
#   ROUNDTRIP_DB_NAME   7 に使う使い捨ての DB の名前（既定 bl_test_issue4_roundtrip。毎回、全部戻してから使う）
# 終了コード: 0 = すべて成功 / 1 = 失敗がある / 2 = 前提を満たさない
# ハーネスの安全（.claude/TEST-HARNESS-SAFETY.md）: 自己再帰ガード・ulimit -u・各手順の timeout。ファイルも DB も削除しない
# （一時ファイルは mktemp の場所に残す。使い終わった bl_test_issue4_* の DB は、必要なら手動で削除する）。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
cd "$ROOT_DIR" || exit 2

if [[ -n "${ISSUE4_RUN_ALL_ACTIVE:-}" ]]; then
  echo "SKIP run_all.sh が自分自身を再帰的に起動しました。実行しません（TH1）"
  exit 0
fi
export ISSUE4_RUN_ALL_ACTIVE=1
ulimit -u 8192 2>/dev/null || {
  echo "FAIL プロセス数の上限（ulimit -u）を設定できません。中止します（TH3）"
  exit 2
}
[[ -f "$ROOT_DIR/.env" ]] || {
  echo "FAIL .env がありません。先に scripts/setup_dev_env.sh を実行してください" >&2
  exit 2
}
command -v python3 >/dev/null 2>&1 || {
  echo "FAIL python3 がありません" >&2
  exit 2
}

# --- テスト用 DB の名前（開発 DB は使わない）---
FRESH_DB="${TEST_DB_NAME:-bl_test_issue4_$(date +%Y%m%d%H%M%S)}"
ROUNDTRIP_DB="${ROUNDTRIP_DB_NAME:-bl_test_issue4_roundtrip}"
for name in "$FRESH_DB" "$ROUNDTRIP_DB"; do
  [[ "$name" =~ ^bl_test_[a-z0-9_]{1,50}$ ]] || {
    echo "FAIL テスト用の DB の名前ではありません: $name（bl_test_ で始まる、小文字・数字・アンダースコアの名前に限ります）" >&2
    exit 2
  }
done
[[ "$FRESH_DB" != "$ROUNDTRIP_DB" ]] || {
  echo "FAIL TEST_DB_NAME と ROUNDTRIP_DB_NAME が同じです" >&2
  exit 2
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/issue4.XXXXXX")"
STRUCTURE="$ROOT_DIR/src/backend/db/structure.sql"
STRUCTURE_SHA_BEFORE="$(sha256sum "$STRUCTURE" | cut -d' ' -f1)"
cp "$STRUCTURE" "$TMP_DIR/structure.before.sql" # 実行前のコピー（コミット済みのファイルが書き換わったときの、確認用）
export ROOT_DIR HERE TMP_DIR FRESH_DB ROUNDTRIP_DB STRUCTURE STRUCTURE_SHA_BEFORE

# コミット済みの db/structure.sql が、実行前と同じであること。違えば、以後の比較は意味を持たないので、中止する。
assert_structure_unchanged() {
  if [[ "$(sha256sum "$STRUCTURE" | cut -d' ' -f1)" != "$STRUCTURE_SHA_BEFORE" ]]; then
    echo "FAIL db/structure.sql が、実行の途中で書き換わりました（実行前のコピー: $TMP_DIR/structure.before.sql）"
    return 1
  fi
}
export -f assert_structure_unchanged

# backend のコンテナの中で、テスト用の使い捨て DB を相手に、コマンドを実行する。標準入力は、そのまま渡す。
#   in_scratch_db <DB 名> <コマンド>
# 開発 DB を相手にしないよう、DB 名を検査し、コンテナの DATABASE_URL が開発 DB を指していることを確かめてから、DB 名を差し替える。
# db:migrate・db:rollback・db:prepare は、実行のたびに、スキーマを structure.sql へ書き出す。コミット済みの db/structure.sql を
# 書き換えないよう、書き出し先（SCHEMA）を、いつも、コンテナの /tmp にする（個別に指定したときは、そちらが優先する）。
in_scratch_db() {
  local db="$1" command="$2"
  [[ "$db" =~ ^bl_test_[a-z0-9_]{1,50}$ ]] || {
    echo "FAIL テスト用の DB の名前ではありません: $db" >&2
    return 2
  }
  scripts/dc.sh exec -T backend sh -c '
    case "$DATABASE_URL" in
      */bl_development) ;;
      *) echo "DATABASE_URL が開発 DB を指していません。中止します" >&2; exit 2 ;;
    esac
    export RAILS_ENV=test DATABASE_URL="${DATABASE_URL%/bl_development}/'"$db"'" SCHEMA=/tmp/issue4_scratch_structure.sql
    '"$command"
}
export -f in_scratch_db

results=()
status=0

# 外部コマンドを、時間制限つきで実行する。
run() {
  local label="$1"
  shift
  printf '\n######## %s\n' "$label"
  if timeout --kill-after=30 900 "$@"; then
    results+=("成功  $label")
  else
    results+=("失敗  $label")
    status=1
  fi
}

# 関数を、時間制限つきで実行する（export -f した関数を、bash -c で呼ぶ）。
run_function() {
  local label="$1" function_name="$2"
  run "$label" bash -c "$function_name"
}

# ------------------------------------------------------------------------------------------------
step_rspec() {
  TEST_DB_NAME="$FRESH_DB" scripts/test_backend.sh --db spec/models
}

step_rubocop() {
  scripts/dc.sh exec -T backend bin/rubocop app/models db spec/support spec/factories spec/models
}

step_brakeman() {
  scripts/dc.sh exec -T backend bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error
}

step_bundler_audit() {
  scripts/dc.sh exec -T backend bin/bundler-audit check --update
}

step_ruby_scan() {
  scripts/dc.sh exec -T backend ruby - /app < "$HERE/scan_ruby_sources.rb"
}

# マイグレーションの往復。使い捨ての DB（ROUNDTRIP_DB）で、上げる→全部戻す→上げる→もう一度上げる。
# structure.sql の書き出し先は、SCHEMA で、コンテナの /tmp へ向ける（コミット済みのファイルを書き換えない）。
step_migration_roundtrip() {
  local log="$TMP_DIR/roundtrip.log" count tables
  in_scratch_db "$ROUNDTRIP_DB" "bin/rails db:create" || return 1
  in_scratch_db "$ROUNDTRIP_DB" "bin/rails db:migrate" > "$log" 2>&1 || { cat "$log"; return 1; }
  echo "ok   上げる"

  assert_structure_unchanged || return 1
  in_scratch_db "$ROUNDTRIP_DB" "bin/rails db:migrate VERSION=0" > "$log" 2>&1 || { cat "$log"; echo "FAIL 全部戻せません"; return 1; }
  assert_structure_unchanged || return 1
  count="$(grep -cE '^== [0-9]+ .*: reverted' "$log")"
  [[ "$count" == "16" ]] || { cat "$log"; echo "FAIL 戻したマイグレーションが 16 件ではありません（$count 件）"; return 1; }
  tables="$(in_scratch_db "$ROUNDTRIP_DB" "bin/rails runner -" <<'RUBY'
puts (ActiveRecord::Base.connection.tables - [ "schema_migrations", "ar_internal_metadata" ]).sort.join(",")
RUBY
)"
  [[ -z "$tables" ]] || { echo "FAIL 全部戻したのに、テーブルが残っています: $tables"; return 1; }
  echo "ok   全部戻す（16 件を戻し、テーブルが残らない）"

  in_scratch_db "$ROUNDTRIP_DB" "SCHEMA=/tmp/issue4_roundtrip.sql bin/rails db:migrate" > "$log" 2>&1 || { cat "$log"; return 1; }
  assert_structure_unchanged || return 1
  count="$(grep -cE '^== [0-9]+ .*: migrated' "$log")"
  [[ "$count" == "16" ]] || { cat "$log"; echo "FAIL 上げ直したマイグレーションが 16 件ではありません（$count 件）"; return 1; }
  in_scratch_db "$ROUNDTRIP_DB" "cat /tmp/issue4_roundtrip.sql" > "$TMP_DIR/roundtrip_structure.sql" || return 1
  echo "ok   上げ直す（16 件）"

  if diff -u "$STRUCTURE" "$TMP_DIR/roundtrip_structure.sql" > "$TMP_DIR/roundtrip.diff"; then
    echo "ok   往復でできた structure.sql が、コミット済みの db/structure.sql と一致する"
  else
    head -40 "$TMP_DIR/roundtrip.diff"
    echo "FAIL 往復でできた structure.sql が、コミット済みの db/structure.sql と違います（開発 DB で bin/rails db:migrate を実行して、更新してください）"
    return 1
  fi

  in_scratch_db "$ROUNDTRIP_DB" "bin/rails db:migrate" > "$log" 2>&1 || { cat "$log"; return 1; }
  if grep -qE '^== [0-9]+ ' "$log"; then
    cat "$log"
    echo "FAIL もう一度 db:migrate を実行したら、マイグレーションが実行されました（冪等ではありません）"
    return 1
  fi
  assert_structure_unchanged || return 1
  echo "ok   もう一度 db:migrate を実行しても、何も起きない（冪等）"
}

# structure.sql から読み込んだテスト用 DB（FRESH_DB。1 で db:prepare が作った）を、書き出し直しても、同じ structure.sql になる。
step_schema_load_roundtrip() {
  in_scratch_db "$FRESH_DB" "SCHEMA=/tmp/issue4_fresh_dump.sql bin/rails db:schema:dump" > "$TMP_DIR/fresh_dump.log" 2>&1 || { cat "$TMP_DIR/fresh_dump.log"; return 1; }
  in_scratch_db "$FRESH_DB" "cat /tmp/issue4_fresh_dump.sql" > "$TMP_DIR/fresh_structure.sql" || return 1
  if diff -u "$STRUCTURE" "$TMP_DIR/fresh_structure.sql" > "$TMP_DIR/fresh.diff"; then
    echo "ok   structure.sql から作ったテスト用 DB（$FRESH_DB）を書き出し直すと、同じ structure.sql になる"
  else
    head -40 "$TMP_DIR/fresh.diff"
    echo "FAIL structure.sql から作った DB を書き出し直すと、違う内容になります（db:schema:load が再現していません）"
    return 1
  fi
}

# 開発 DB（bl_development）。読み取りだけ（db:migrate:status と、スキーマの書き出し先を /tmp へ向けた db:schema:dump）。
step_dev_database() {
  local log="$TMP_DIR/dev_status.log"
  scripts/dc.sh exec -T backend bin/rails db:migrate:status > "$log" 2>&1 || { cat "$log"; return 1; }
  if grep -qE '^\s+down\s' "$log"; then
    cat "$log"
    echo "FAIL 開発 DB に、未適用のマイグレーションがあります（scripts/dc.sh exec -T backend bin/rails db:migrate を実行してください）"
    return 1
  fi
  [[ "$(grep -cE '^\s+up\s' "$log")" -ge 16 ]] || { cat "$log"; echo "FAIL 適用済みのマイグレーションが 16 件に満たない"; return 1; }
  echo "ok   開発 DB のマイグレーションは、すべて up"

  scripts/dc.sh exec -T backend sh -c 'SCHEMA=/tmp/issue4_dev_dump.sql bin/rails db:schema:dump >/dev/null 2>&1; cat /tmp/issue4_dev_dump.sql' > "$TMP_DIR/dev_structure.sql" || return 1
  if diff -u "$STRUCTURE" "$TMP_DIR/dev_structure.sql" > "$TMP_DIR/dev.diff"; then
    echo "ok   開発 DB から書き出したスキーマが、コミット済みの db/structure.sql と一致する"
  else
    head -40 "$TMP_DIR/dev.diff"
    echo "FAIL 開発 DB のスキーマと、db/structure.sql が違います（bin/rails db:migrate のあとの structure.sql を、コミットしてください）"
    return 1
  fi
}

# 既存の画面（3 層のヘルスチェック）が、従来どおり応答する。
step_existing_endpoints() {
  local failures=0 backend_port="${BACKEND_PORT:-3001}" frontend_port="${FRONTEND_PORT:-3000}" relay_port="${RELAY_PORT:-3002}" code
  scripts/dc.sh up -d --wait > /dev/null 2>&1 || {
    echo "FAIL docker compose の 4 サービスが、healthy になりません"
    return 1
  }
  for target in "backend|http://localhost:${backend_port}/up" "frontend|http://localhost:${frontend_port}/healthz" "relay|http://localhost:${relay_port}/health"; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "${target#*|}" 2>/dev/null || echo 000)"
    if [[ "$code" == "200" ]]; then
      echo "ok   ${target%%|*} のヘルスチェックが 200（${target#*|}）"
    else
      echo "FAIL ${target%%|*} のヘルスチェックが 200 ではありません（$code）"
      failures=$((failures + 1))
    fi
  done
  [[ "$failures" -eq 0 ]]
}

export -f step_rspec step_rubocop step_brakeman step_bundler_audit step_ruby_scan step_migration_roundtrip
export -f step_schema_load_roundtrip step_dev_database step_existing_endpoints

# ------------------------------------------------------------------------------------------------
scripts/dc.sh up -d --wait db backend > /dev/null 2>&1 || {
  echo "FAIL db・backend が起動しません（scripts/dc.sh up -d --wait を確かめてください）" >&2
  exit 2
}

printf 'テスト用 DB: %s（RSpec と、書き出し直しの確認）／%s（マイグレーションの往復）\n' "$FRESH_DB" "$ROUNDTRIP_DB"

run_function "1. RSpec（spec/models）と RuboCop（spec/models）" step_rspec
run_function "2. RuboCop（モデル・マイグレーション・テスト補助・ファクトリ）" step_rubocop
run_function "3a. Brakeman（backend 全体）" step_brakeman
run_function "3b. bundler-audit" step_bundler_audit
run "4. 走査: 絵文字・削除系コマンドの語・資格情報の形式" python3 -I "$HERE/scan_sources.py" "$ROOT_DIR"
run_function "5. 走査: 日本語の文字列リテラル・実時計・ファイルを消す呼び出し（Ruby の字句解析）" step_ruby_scan
run "6. db/structure.sql をファイルとして検査" python3 -I "$HERE/check_structure_sql.py" "$ROOT_DIR"
run_function "7. マイグレーションの往復と冪等" step_migration_roundtrip
run_function "8. structure.sql から作った DB の書き出し直し" step_schema_load_roundtrip
run_function "9. 開発 DB" step_dev_database
run_function "10. 既存の画面（ヘルスチェック）" step_existing_endpoints

# この実行が、コミットされるファイルを書き換えていないこと
printf '\n######## 11. db/structure.sql を書き換えていない\n'
if [[ "$(sha256sum "$STRUCTURE" | cut -d' ' -f1)" == "$STRUCTURE_SHA_BEFORE" ]]; then
  echo "ok   db/structure.sql は、実行の前後で同じ"
  results+=("成功  11. db/structure.sql を書き換えていない")
else
  echo "FAIL db/structure.sql が、実行の途中で書き換わりました（実行前のコピー: $TMP_DIR/structure.before.sql）"
  results+=("失敗  11. db/structure.sql を書き換えていない")
  status=1
fi

printf '\n######## 結果（PR #38）\n'
printf '%s\n' "${results[@]}"
printf '作業用の一時ファイル: %s（削除しません）\n' "$TMP_DIR"
if [[ "$status" -ne 0 ]]; then
  printf '\nFAIL PR #38 のテストに失敗した項目があります\n'
  exit 1
fi
printf '\nPASS PR #38 のテストはすべて成功しました\n'
exit 0
