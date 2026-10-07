#!/usr/bin/env bash
# PR #43（issue #7 アプリケーション基盤: フロントエンドの確認・サーバー側セッション・CSRF・頻度制限・測定イベントの記録・
# ログの機密除外・口の分離）のテスト一式。対象は開発サーバー（scripts/dc.sh 経由の docker compose の backend コンテナ）。
#
#   1. backend の RSpec と RuboCop（この issue のスペック。DB を使う）
#   2. 同じスペックを、Rails の eager_load を有効にして（CI と同じ CI=true）
#   3. RuboCop（この issue のアプリケーション・lib・config のファイル）
#   4. Zeitwerk の読み込み検査（lib/ の once ローダーと、app/ のローダーが、衝突せず、すべて読み込めること）
#   5. Brakeman（静的解析。警告 0 件）
#   6. 実サーバー（Puma）への確認（live_server_check.rb）: 口の分離・BFF の確認・CSRF の評価の順・エラーの形・ホストの許可・ログに IP と機密が無いこと
#   7. ホストから見た口の確認（check_host_ports.sh）: 公開側の口の応答と、内部側の口がホストへ公開されていないこと
#   8. 本番の起動の検査（check_production.sh）: 必須の環境変数・ミドルウェアの順・ホストの許可・BFF の要求が拒否されないこと
#   9. ソース走査器の自己検査（scan_sources.py --self-test）
#  10. ソースの走査（scan_sources.py）: 絵文字・不可視の文字・削除系コマンド・機密の直書きが無く、UTF-8 として読めること
#
# 使い方: test/pr43/run_all.sh
# 終了コード: 0 = すべて成功 / 1 = 失敗がある / 2 = 準備ができていない（.env が無いなど）
# 環境変数: TEST_DB_NAME（テスト用 DB の名前。既定 bl_test_issue7）。BACKEND_PORT（公開側の口。既定 3001）。
#           並行して複数の環境を起動しているときは、COMPOSE_PROJECT_NAME・BACKEND_PORT を、その環境のものにする
# ハーネスの安全（.claude/TEST-HARNESS-SAFETY.md）: 自己再帰ガード・ulimit -u・各手順の timeout。ファイルは削除しない。
# 外部サービス（Google・YouTube・reCAPTCHA）・本番へは接続しない。秘密値（.env）は、画面へ出さない。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
cd "$ROOT_DIR" || exit 1

if [[ -n "${ISSUE07_RUN_ALL_ACTIVE:-}" ]]; then
  echo "SKIP run_all.sh が自分自身を再帰的に起動しました。実行しません（TH1）"
  exit 0
fi
export ISSUE07_RUN_ALL_ACTIVE=1
ulimit -u 8192 2>/dev/null || {
  echo "FAIL プロセス数の上限（ulimit -u）を設定できません。中止します（TH3）"
  exit 2
}
[[ -f "$ROOT_DIR/.env" ]] || {
  echo "FAIL .env がありません。先に scripts/setup_dev_env.sh を実行してください" >&2
  exit 2
}

export TEST_DB_NAME="${TEST_DB_NAME:-bl_test_issue7}"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/issue07.XXXXXX")"
echo "各手順のログの置き場（削除しません）: $LOG_DIR"

# この issue のスペック（ほかの issue のスペックは含めない。spec/services/settings_store_spec.rb など）
MY_SPECS=(
  spec/lib
  spec/controllers
  spec/sources
  spec/requests/up_spec.rb
  spec/requests/listener_isolation_spec.rb
  spec/requests/api/bff_verification_spec.rb
  spec/requests/api/csrf_spec.rb
  spec/requests/api/error_format_spec.rb
  spec/requests/api/log_hygiene_spec.rb
  spec/requests/api/session_spec.rb
  spec/requests/api/usage_events_spec.rb
  spec/config/required_environment_spec.rb
  spec/config/allowed_hosts_spec.rb
  spec/config/initializers_spec.rb
  spec/config/locales_spec.rb
  spec/config/filter_parameters_logging_spec.rb
  spec/services/bff_guard_spec.rb
  spec/services/bucketizer_spec.rb
  spec/services/browser_class_spec.rb
  spec/services/browser_usage_event_spec.rb
  spec/services/client_ip_spec.rb
  spec/services/cookies_spec.rb
  spec/services/csrf_token_spec.rb
  spec/services/oauth_state_cookie_spec.rb
  spec/services/public_origin_spec.rb
  spec/services/rate_limit_policy_spec.rb
  spec/services/rate_limiter_spec.rb
  spec/services/session_store_spec.rb
  spec/services/system_clock_spec.rb
  spec/services/usage_recorder_spec.rb
)
# この issue のアプリケーション・lib・config のファイル（RuboCop の対象）
MY_APP_FILES=(
  app/controllers/application_controller.rb
  app/controllers/api
  app/services/bff_guard.rb
  app/services/bucketizer.rb
  app/services/browser_class.rb
  app/services/browser_usage_event.rb
  app/services/client_ip.rb
  app/services/cookie_policy.rb
  app/services/csrf_token.rb
  app/services/derived_keys.rb
  app/services/oauth_state_cookie.rb
  app/services/public_origin.rb
  app/services/rate_limit_policy.rb
  app/services/rate_limiter.rb
  app/services/session_cookie.rb
  app/services/session_store.rb
  app/services/system_clock.rb
  app/services/usage_recorder.rb
  app/services/verified_bff_request.rb
  lib
  config/allowed_hosts.rb
  config/required_environment.rb
  config/application.rb
  config/routes.rb
  config/environments/development.rb
  config/initializers/filter_parameter_logging.rb
  config/initializers/inflections.rb
  config/initializers/listener_ports.rb
  config/initializers/request_pipeline.rb
  config/initializers/required_environment.rb
)

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
    summary="$(grep -hE 'examples?, [0-9]+ failures?|[0-9]+ files? inspected|No warnings found|[0-9]+ 件を確認しました|^問題ありません|^自己検査|^すべて成功' "$log" | tail -2 | tr '\n' ' ')"
    results+=("成功  $label  [$summary]")
  else
    summary="$(grep -hE 'examples?, [0-9]+ failures?|^FAIL|[0-9]+ 件失敗|違反' "$log" | tail -2 | tr '\n' ' ')"
    results+=("失敗  $label  [$summary]")
    status=1
  fi
}

run "backend の RSpec と RuboCop（この issue のスペック。DB を使う。テスト用 DB: $TEST_DB_NAME）" \
  scripts/test_backend.sh --db "${MY_SPECS[@]}"

run "同じスペックを、Rails の eager_load を有効にして（CI と同じ CI=true）" \
  scripts/dc.sh exec -T -e CI=true -e "TEST_DB_NAME=$TEST_DB_NAME" backend bash /scripts/test_backend.sh --db "${MY_SPECS[@]}"

run "RuboCop（この issue のアプリケーション・lib・config のファイル）" \
  scripts/dc.sh exec -T backend bin/rubocop "${MY_APP_FILES[@]}"

run "Zeitwerk の読み込み検査（lib/ の once ローダーと app/ のローダー。eager load ですべて読み込める）" \
  scripts/dc.sh exec -T -e RAILS_ENV=test -e "TEST_DB_NAME=$TEST_DB_NAME" backend \
  sh -c 'export DATABASE_URL="${DATABASE_URL%/bl_development}/${TEST_DB_NAME}"; bin/rails zeitwerk:check'

run "Brakeman（静的解析。警告 0 件）" \
  scripts/dc.sh exec -T backend bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error

STDIN_FILE="$HERE/live_server_check.rb" run "実サーバー（Puma）への確認（口の分離・BFF の確認・CSRF の評価の順・エラーの形・ホストの許可・ログに IP と機密が無いこと）" \
  scripts/dc.sh exec -T backend ruby -

run "ホストから見た口の確認（公開側の口の応答。内部側の口がホストへ公開されていないこと）" \
  bash "$HERE/check_host_ports.sh"

run "本番の起動の検査（必須の環境変数・ミドルウェアの順・ホストの許可・BFF の要求が拒否されないこと）" \
  bash "$HERE/check_production.sh"

run "ソース走査器の自己検査（合成したソースで、違反を見逃さず、違反でないものを誤検知しないこと）" \
  python3 -I "$HERE/scan_sources.py" --self-test

run "ソースの走査（絵文字・不可視の文字・削除系コマンド・機密の直書き・UTF-8）" \
  python3 -I "$HERE/scan_sources.py" "$ROOT_DIR"

printf '\n######## 結果（PR #43）\n'
printf '%s\n' "${results[@]}"
if [[ "$status" -ne 0 ]]; then
  printf '\nFAIL PR #43 のテストに失敗した項目があります（ログ: %s）\n' "$LOG_DIR"
  exit 1
fi
printf '\nPASS PR #43 のテストはすべて成功しました\n'
exit 0
