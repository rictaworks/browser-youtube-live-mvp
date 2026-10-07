#!/usr/bin/env bash
# PR #39（issue #5 アプリケーション Domain Core（1）: 利用日・割り当て日・設定値・開始受付判定・割り当ての予約と記帳・
# 転送量の判定）のテスト一式。対象は開発サーバー（scripts/dc.sh 経由の docker compose の backend コンテナ）。
#
#   1. Rails を起動しない RSpec（この issue のスペックと、契約のスペック。RuboCop を含む）
#   2. RuboCop（app/domain のこの issue のファイル）
#   3. Rails を起動する RSpec との同居（Rails のローダーが app/domain を管理する実行。DB を使う）
#   4. 同じ実行を、Rails の eager_load を有効にして（CI と同じ CI=true）
#   5. 受け入れの確認（黒箱。acceptance.rb。issue の受け入れ条件を、公開の API だけで確かめる）
#   6. 暦の差分検査（differential_calendar.rb。UsageCalendar を、libc のタイムゾーン処理を基準にした独立の算出と、多数の時刻で突き合わせる）
#   7. Domain Core の規則の走査（scan_domain.rb。実時計・入出力の型・日本語の直書き・契約の固定値の直書き）
#   8. ソース走査器の自己検査（scan_sources.py --self-test。合成したソースで、違反を見逃さず、違反でないものを誤検知しないこと）
#   9. ソースの走査（scan_sources.py。削除系コマンド・標準ライブラリの自動削除（ブロック形式の一時ディレクトリなど）・絵文字・不可視の書式文字）
#  10. requirements.md の変更が、8 章の表の 1 行の追記だけであること（check_requirements_diff.py）
#  11. （--with-mutation のときだけ。数分かかる）変異テスト（mutate_domain.rb）。実装を 1 か所ずつ壊し、スペックが検出すること
#
# 使い方: test/pr39/run_all.sh [--with-mutation]
# 終了コード: 0 = すべて成功 / 1 = 失敗がある / 2 = 準備ができていない（.env が無い・引数の誤りなど）
# 環境変数: TEST_DB_NAME（テスト用 DB の名前。既定 bl_test_issue5。手順 3・4 だけが DB を使う）
# ハーネスの安全（.claude/TEST-HARNESS-SAFETY.md）: 自己再帰ガード・ulimit -u・各手順の timeout。ファイルは削除しない。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
cd "$ROOT_DIR" || exit 1

if [[ -n "${ISSUE05_RUN_ALL_ACTIVE:-}" ]]; then
  echo "SKIP run_all.sh が自分自身を再帰的に起動しました。実行しません（TH1）"
  exit 0
fi
export ISSUE05_RUN_ALL_ACTIVE=1
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

export TEST_DB_NAME="${TEST_DB_NAME:-bl_test_issue5}"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/issue05.XXXXXX")"
echo "各手順のログの置き場（削除しません）: $LOG_DIR"

# この issue のスペック（spec/domain の直下。ほかの issue のスペックは含めない）
MY_SPECS=(
  spec/domain/domain_loader_spec.rb
  spec/domain/usage_calendar_spec.rb
  spec/domain/settings_spec.rb
  spec/domain/transfer_budget_policy_spec.rb
  spec/domain/quota_policy_spec.rb
  spec/domain/quota_policy_simulation_spec.rb
  spec/domain/account_snapshot_spec.rb
  spec/domain/admission_spec.rb
  spec/domain/start_admission_input_spec.rb
  spec/domain/start_admission_spec.rb
  spec/domain/domain_rules_spec.rb
  spec/domain/domain_core_rules_spec.rb
  spec/domain/app_domain_loading_spec.rb
)
# この issue の app/domain のファイル（backend コンテナの /app からの相対パス）
MY_APP_FILES=(
  app/domain/preconditions.rb
  app/domain/usage_calendar.rb
  app/domain/settings.rb
  app/domain/settings
  app/domain/transfer_budget_policy.rb
  app/domain/quota_policy.rb
  app/domain/quota_policy
  app/domain/account_snapshot.rb
  app/domain/admission.rb
  app/domain/admission
  app/domain/start_admission.rb
  app/domain/start_admission
)
# Rails を起動するスペック（rails_helper を読む）。Rails のローダーが app/domain を管理する実行をつくる
RAILS_SPECS=(spec/config/application_spec.rb)

results=()
status=0
step=0

# execute <ログ> <コマンド...>: コマンドを timeout つきで実行し、出力をログへも残す。STDIN_FILE があれば標準入力へ渡す
execute() {
  local log="$1"
  shift
  if [[ -n "${STDIN_FILE:-}" ]]; then
    timeout --kill-after=30 "${STEP_TIMEOUT:-900}" "$@" <"$STDIN_FILE" 2>&1 | tee "$log"
  else
    timeout --kill-after=30 "${STEP_TIMEOUT:-900}" "$@" 2>&1 | tee "$log"
  fi
}

run() {
  local label="$1"
  shift
  step=$((step + 1))
  local log="$LOG_DIR/step${step}.log"
  printf '\n######## %d. %s\n' "$step" "$label"
  local summary
  if execute "$log" "$@"; then
    summary="$(grep -hE 'examples?, [0-9]+ failures?|[0-9]+ files? inspected|^PASS|^確認した項目|^問題ありません|^[0-9]+ ファイルを' "$log" | tail -2 | tr '\n' ' ')"
    results+=("成功  $label  [$summary]")
  else
    summary="$(grep -hE 'examples?, [0-9]+ failures?|^FAIL|^問題' "$log" | tail -2 | tr '\n' ' ')"
    results+=("失敗  $label  [$summary]")
    status=1
  fi
}

run "Rails を起動しない RSpec（この issue のスペックと契約のスペック。RuboCop を含む）" \
  scripts/test_backend.sh --no-db spec/domain/contract "${MY_SPECS[@]}"

run "RuboCop（app/domain のこの issue のファイル）" \
  scripts/dc.sh exec -T backend bin/rubocop "${MY_APP_FILES[@]}"

run "Rails を起動するスペックとの同居（Rails のローダーが app/domain を管理する実行。DB を使う）" \
  scripts/test_backend.sh --db "${RAILS_SPECS[@]}" "${MY_SPECS[@]}"

run "同じ実行を、Rails の eager_load を有効にして（CI と同じ CI=true）" \
  scripts/dc.sh exec -T -e CI=true -e "TEST_DB_NAME=$TEST_DB_NAME" backend bash /scripts/test_backend.sh --db "${RAILS_SPECS[@]}" "${MY_SPECS[@]}"

STDIN_FILE="$HERE/acceptance.rb" run "受け入れの確認（黒箱。公開の API だけで、受け入れ条件を確かめる）" \
  scripts/dc.sh exec -T backend bundle exec ruby -

STDIN_FILE="$HERE/differential_calendar.rb" run "暦の差分検査（UsageCalendar を、libc のタイムゾーン処理を基準にした独立の算出と、夏時間・日付の境界の近傍を含む多数の時刻で突き合わせる）" \
  scripts/dc.sh exec -T backend bundle exec ruby -

STDIN_FILE="$HERE/scan_domain.rb" run "Domain Core の規則の走査（実時計・入出力の型・日本語の直書き・契約の固定値の直書き）" \
  scripts/dc.sh exec -T backend bundle exec ruby -

run "ソース走査器の自己検査（合成したソースで、違反を見逃さず、違反でないものを誤検知しないこと）" \
  python3 -I "$HERE/scan_sources.py" --self-test

run "ソースの走査（削除系コマンド・標準ライブラリの自動削除・絵文字・不可視の書式文字・UTF-8）" \
  python3 -I "$HERE/scan_sources.py" "$ROOT_DIR"

run "requirements.md の変更が、8 章の表への 1 行の追記だけであること" \
  python3 -I "$HERE/check_requirements_diff.py" "$ROOT_DIR"

if [[ "$with_mutation" -eq 1 ]]; then
  STEP_TIMEOUT=1800 STDIN_FILE="$HERE/mutate_domain.rb" run "変異テスト（実装を 1 か所ずつ壊し、スペックが検出すること）" \
    scripts/dc.sh exec -T backend ruby -
else
  results+=("省略  変異テスト（--with-mutation で実行。数分かかる）")
fi

printf '\n######## 結果（PR #39）\n'
printf '%s\n' "${results[@]}"
if [[ "$status" -ne 0 ]]; then
  printf '\nFAIL PR #39 のテストに失敗した項目があります（ログ: %s）\n' "$LOG_DIR"
  exit 1
fi
printf '\nPASS PR #39 のテストはすべて成功しました\n'
exit 0
