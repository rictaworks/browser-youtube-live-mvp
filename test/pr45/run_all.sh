#!/usr/bin/env bash
# PR #45（issue #9「アプリケーション: 利用枠・開始試行・割り当て台帳・転送量・設定の DB 実装」）のテスト一式。
# 対象は開発サーバー（scripts/dc.sh 経由の docker compose の backend コンテナと db コンテナ）。層をまたいで、1 回で実行する。
#
#    1. RSpec（spec/services のこの issue のスペック 11 ファイル。DB を使う。複数の接続による同時の操作・ランダムな操作列を含む）と、
#       そのスペックの RuboCop
#    2. RuboCop（app/services のこの issue のファイル）
#    3. Brakeman・bundler-audit（backend 全体）
#    4. Zeitwerk の検査（bin/rails zeitwerk:check。eager load で、すべての定数が読み込める）
#   4b. eager_load を有効にして（CI と同じ CI=true）、サービスのスペックの一部を実行する
#    5. 受け入れの確認（黒箱。acceptance.rb。公開の API だけで、issue の受け入れ条件を確かめる。SQL で台帳を独立に再計算）
#    6. 同時の操作の負荷確認（stress.rb。接続のプール 32・最大 24 スレッド。使い捨ての DB へ実際にコミットする）
#    7. サービスのソースの走査（scan_services.rb。Ruby の字句解析。実時計・日本語の直書き・契約の固定値の直書き など）
#    8. 成果物の走査（scan_sources.py。絵文字・削除系コマンドの語・資格情報の形式）
#    9. 既存の画面（3 層のヘルスチェック）が、影響を受けていない
#   10. （--with-mutation のときだけ。数分かかる）変異テスト（mutate_services.rb）。実装を 1 か所ずつ壊し、スペックが検出すること
#   11. コミット対象の db/structure.sql を書き換えていない
#
# 使い方: このスクリプトを実行する（作業ディレクトリは問わない）。
#   scripts/setup_dev_env.sh                   # .env の生成（済んでいれば不要）
#   <このディレクトリ>/run_all.sh [--with-mutation]
# 環境変数（任意）:
#   TEST_DB_NAME        1 に使うテスト用 DB の名前。既定は、実行のたびに新しい名前（bl_test_issue9_<日時>）。bl_test_ で始まる名前に限る
#   SCRATCH_DB_NAME     5・6 に使う使い捨ての DB の名前（既定 <TEST_DB_NAME>_scratch。実行のたびに新しい名前）
#   MUTATION_DB_NAME    10 に使う使い捨ての DB の名前（既定 <TEST_DB_NAME>_mut）
# 終了コード: 0 = すべて成功 / 1 = 失敗がある / 2 = 準備ができていない（.env が無い・引数の誤り・コンテナに入れない など）
# ハーネスの安全（.claude/TEST-HARNESS-SAFETY.md）: 自己再帰ガード・ulimit -u・各手順の timeout。ファイルも DB も削除しない
# （一時ファイルは mktemp の場所に残す。使い終わった bl_test_issue9_* の DB は、必要なら手動で削除する）。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
cd "$ROOT_DIR" || exit 2

if [[ -n "${ISSUE09_RUN_ALL_ACTIVE:-}" ]]; then
  echo "SKIP run_all.sh が自分自身を再帰的に起動しました。実行しません（TH1）"
  exit 0
fi
export ISSUE09_RUN_ALL_ACTIVE=1
ulimit -u 8192 2>/dev/null || {
  echo "FAIL プロセス数の上限（ulimit -u）を設定できません。中止します（TH3）"
  exit 2
}

with_mutation=0
for argument in "$@"; do
  case "$argument" in
    --with-mutation) with_mutation=1 ;;
    *)
      echo "FAIL 未知の引数です: $argument（使い方: run_all.sh [--with-mutation]）" >&2
      exit 2
      ;;
  esac
done

[[ -f "$ROOT_DIR/.env" ]] || {
  echo "FAIL .env がありません。先に scripts/setup_dev_env.sh を実行してください" >&2
  exit 2
}
command -v python3 > /dev/null 2>&1 || {
  echo "FAIL python3 がありません" >&2
  exit 2
}

# --- テスト用 DB の名前（開発 DB は使わない）---
RSPEC_DB="${TEST_DB_NAME:-bl_test_issue9_$(date +%Y%m%d%H%M%S)}"
SCRATCH_DB="${SCRATCH_DB_NAME:-${RSPEC_DB}_scratch}"
MUTATION_DB="${MUTATION_DB_NAME:-${RSPEC_DB}_mut}"
for name in "$RSPEC_DB" "$SCRATCH_DB" "$MUTATION_DB"; do
  [[ "$name" =~ ^bl_test_[a-z0-9_]{1,50}$ ]] || {
    echo "FAIL テスト用の DB の名前ではありません: $name（bl_test_ で始まる、小文字・数字・アンダースコアの名前に限ります）" >&2
    exit 2
  }
done
[[ "$RSPEC_DB" != "$SCRATCH_DB" && "$RSPEC_DB" != "$MUTATION_DB" && "$SCRATCH_DB" != "$MUTATION_DB" ]] || {
  echo "FAIL テスト用 DB の名前が重なっています" >&2
  exit 2
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/issue9.XXXXXX")"
STRUCTURE="$ROOT_DIR/src/backend/db/structure.sql"
STRUCTURE_SHA_BEFORE="$(sha256sum "$STRUCTURE" | cut -d' ' -f1)"
cp "$STRUCTURE" "$TMP_DIR/structure.before.sql" # 実行前のコピー（コミット対象のファイルが書き換わったときの、確認用）

# この issue のスペック（spec/services には、ほかの issue のスペックも入る。ここでは、この issue のものだけを実行する）
MY_SPECS="spec/services/settings_store_spec.rb spec/services/transfer_budget_spec.rb spec/services/transfer_budget_concurrency_spec.rb \
spec/services/daily_allowance_spec.rb spec/services/daily_allowance_concurrency_spec.rb spec/services/quota_ledger_reserve_spec.rb \
spec/services/quota_ledger_spend_spec.rb spec/services/quota_ledger_carry_release_spec.rb spec/services/quota_ledger_invariants_spec.rb \
spec/services/quota_ledger_concurrency_spec.rb spec/services/service_sources_spec.rb"
# この issue の app/services のファイル（backend コンテナの /app からの相対パス）
MY_APP_FILES="app/services/daily_allowance.rb app/services/quota_ledger.rb app/services/quota_ledger app/services/transfer_budget.rb \
app/services/settings_store.rb"
export ROOT_DIR HERE TMP_DIR RSPEC_DB SCRATCH_DB MUTATION_DB STRUCTURE STRUCTURE_SHA_BEFORE MY_SPECS MY_APP_FILES

# backend のコンテナの中で、使い捨てのテスト用 DB を相手に、コマンドを実行する。標準入力は、そのまま渡す。
#   in_scratch_db <DB 名> <コマンド>
# 開発 DB を相手にしないよう、DB 名を検査し、コンテナの DATABASE_URL が開発 DB を指していることを確かめてから、DB 名を差し替える。
# db:prepare は、スキーマを structure.sql へ書き出すことがある。コミット対象の db/structure.sql を書き換えないよう、
# 書き出し先（SCHEMA）を、いつも、コンテナの /tmp にする。
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
    export RAILS_ENV=test DATABASE_URL="${DATABASE_URL%/bl_development}/'"$db"'" SCHEMA=/tmp/issue9_scratch_structure.sql
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
  if timeout --kill-after=30 "${STEP_TIMEOUT:-900}" "$@"; then
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
# db・backend を起動する。healthy にならなくても（別の作業中の変更で、backend のヘルスチェックだけが赤いことがある）、
# コンテナに入れれば続行する（このスクリプトが確かめるのは、サービスと DB。ヘルスチェックは、手順 9 が確かめる）。
ensure_containers() {
  local log="$TMP_DIR/up.log"
  if scripts/dc.sh up -d --wait db backend > "$log" 2>&1; then
    return 0
  fi
  echo "WARN db・backend が healthy になりませんでした（ログ: $log）。コンテナに入れれば、続行します" >&2
  scripts/dc.sh exec -T backend true > /dev/null 2>&1 && scripts/dc.sh exec -T db true > /dev/null 2>&1
}

step_rspec() {
  # scripts/test_backend.sh と同じ、コンテナの中のスクリプト（テスト用 DB を作り、structure.sql を読み込み、RSpec と RuboCop を実行する）
  # shellcheck disable=SC2086
  scripts/dc.sh exec -T -e "TEST_DB_NAME=$RSPEC_DB" backend bash /scripts/test_backend.sh --db $MY_SPECS
}

step_rubocop() {
  # shellcheck disable=SC2086
  scripts/dc.sh exec -T backend bin/rubocop $MY_APP_FILES
}

step_brakeman() {
  scripts/dc.sh exec -T backend bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error
}

step_bundler_audit() {
  scripts/dc.sh exec -T backend bin/bundler-audit check --update
}

step_zeitwerk() {
  scripts/dc.sh exec -T backend bin/rails zeitwerk:check
}

# CI（GitHub Actions）は CI=true で、Rails の eager_load を有効にして RSpec を実行する。同じ条件で、サービスのスペックの一部を実行する
step_rspec_eager() {
  scripts/dc.sh exec -T -e CI=true -e "TEST_DB_NAME=$RSPEC_DB" backend bash /scripts/test_backend.sh --db \
    spec/services/settings_store_spec.rb spec/services/service_sources_spec.rb spec/services/quota_ledger_reserve_spec.rb
}

# 使い捨ての DB を作る（無ければ作り、structure.sql を読み込む）。受け入れの確認と負荷確認が、これを使う
step_prepare_scratch() {
  in_scratch_db "$SCRATCH_DB" "bin/rails db:prepare" > "$TMP_DIR/prepare_scratch.log" 2>&1 || { cat "$TMP_DIR/prepare_scratch.log"; return 1; }
  echo "ok   使い捨ての DB を用意しました（$SCRATCH_DB）"
}

step_acceptance() {
  in_scratch_db "$SCRATCH_DB" "bundle exec ruby -" < "$HERE/acceptance.rb"
}

step_stress() {
  scripts/dc.sh exec -T -e RAILS_MAX_THREADS=32 backend sh -c '
    case "$DATABASE_URL" in
      */bl_development) ;;
      *) echo "DATABASE_URL が開発 DB を指していません。中止します" >&2; exit 2 ;;
    esac
    export RAILS_ENV=test DATABASE_URL="${DATABASE_URL%/bl_development}/'"$SCRATCH_DB"'"
    bundle exec ruby -' < "$HERE/stress.rb"
}

step_scan_services() {
  scripts/dc.sh exec -T backend bundle exec ruby - < "$HERE/scan_services.rb"
}

step_scan_sources() {
  python3 -I "$HERE/scan_sources.py" "$ROOT_DIR"
}

# 既存の画面（3 層のヘルスチェック）が、従来どおり応答する。
step_existing_endpoints() {
  local failures=0 backend_port="${BACKEND_PORT:-3001}" frontend_port="${FRONTEND_PORT:-3000}" relay_port="${RELAY_PORT:-3002}" code target
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

step_mutation() {
  in_scratch_db "$MUTATION_DB" "bin/rails db:prepare" > "$TMP_DIR/prepare_mutation.log" 2>&1 || { cat "$TMP_DIR/prepare_mutation.log"; return 1; }
  scripts/dc.sh exec -T -e "ISSUE09_MUTATION_DB=$MUTATION_DB" backend ruby - < "$HERE/mutate_services.rb"
}

export -f ensure_containers step_rspec step_rubocop step_brakeman step_bundler_audit step_zeitwerk step_rspec_eager step_prepare_scratch step_acceptance
export -f step_stress step_scan_services step_scan_sources step_existing_endpoints step_mutation

# ------------------------------------------------------------------------------------------------
if ! ensure_containers; then
  echo "FAIL db・backend のコンテナに入れません（scripts/dc.sh up -d --wait db backend を確かめてください）" >&2
  exit 2
fi

printf 'テスト用 DB: %s（RSpec）／%s（受け入れの確認・負荷確認）／%s（変異テスト）\n' "$RSPEC_DB" "$SCRATCH_DB" "$MUTATION_DB"
printf '作業用の一時ファイル: %s（削除しません）\n' "$TMP_DIR"

run_function "1. RSpec（spec/services のこの issue のスペック。同時の操作を含む）と RuboCop" step_rspec
run_function "2. RuboCop（app/services のこの issue のファイル）" step_rubocop
run_function "3a. Brakeman（backend 全体）" step_brakeman
run_function "3b. bundler-audit" step_bundler_audit
run_function "4. Zeitwerk の検査（eager load で、すべての定数が読み込める）" step_zeitwerk
run_function "4b. eager_load を有効にして（CI と同じ CI=true）、サービスのスペックの一部を実行" step_rspec_eager
run_function "5a. 使い捨ての DB を用意する" step_prepare_scratch
run_function "5b. 受け入れの確認（黒箱。公開の API だけで、受け入れ条件を確かめる）" step_acceptance
STEP_TIMEOUT=1200 run_function "6. 同時の操作の負荷確認（接続のプール 32・最大 24 スレッド）" step_stress
run_function "7. サービスのソースの走査（Ruby の字句解析）" step_scan_services
run_function "8. 成果物の走査（絵文字・削除系コマンドの語・資格情報の形式）" step_scan_sources
run_function "9. 既存の画面（ヘルスチェック）" step_existing_endpoints

if [[ "$with_mutation" -eq 1 ]]; then
  STEP_TIMEOUT=2400 run_function "10. 変異テスト（実装を 1 か所ずつ壊し、スペックが検出すること）" step_mutation
else
  results+=("省略  10. 変異テスト（--with-mutation で実行。数分かかる）")
fi

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

printf '\n######## 結果（PR #45）\n'
printf '%s\n' "${results[@]}"
printf '作業用の一時ファイル: %s（削除しません）\n' "$TMP_DIR"
if [[ "$status" -ne 0 ]]; then
  printf '\nFAIL PR #45 のテストに失敗した項目があります\n'
  exit 1
fi
printf '\nPASS PR #45 のテストはすべて成功しました\n'
exit 0
