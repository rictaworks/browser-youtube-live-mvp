#!/usr/bin/env bash
# PR #48（issue #8「認証: Google ログイン（OIDC・PKCE）・bot 判定・再登録の保留・開発環境の疑似 Google」）のテスト一式。
# 対象は開発サーバー（scripts/dc.sh 経由の docker compose の backend・frontend コンテナ。ホストの localhost）。
# あわせて、#7 のレビューの提案 P1（ログインの方針の宣言）・P5（本番の SSL・Secure の Cookie）・コールバックの公開オリジンの確認も含む。
#
#    1. backend の RSpec と RuboCop（この issue のスペックと、#7 の基盤のスペック。DB を使う）
#    2. 同じスペックを、Rails の eager_load を有効にして（CI と同じ CI=true）
#    3. RuboCop（この issue のアプリケーション・config のファイル）
#    4. Zeitwerk の読み込み検査（app/gateways を含む。eager load ですべて読み込める）
#    5. Brakeman（静的解析。警告 0 件）
#    6. bundler-audit（jwt・webmock を足した Gemfile.lock）
#    7. 実サーバー（Puma）への確認（live_server_check.rb）: 疑似の Google でのログインの全体の流れ・セッション固定化の防止・ログアウト・頻度制限・ログに機密が無いこと
#    8. curl での確認（curl_bff_check.sh）: フロントエンドの同一オリジン中継（http://localhost:3000）を通した、ログインの流れ
#    9. 実ブラウザの確認（browser_flow_check.cjs。Playwright の Chromium。無ければ SKIP）: LOG IN WITH GOOGLE から /studio まで・戻る操作の再選択・Cookie の属性
#   10. 本番の起動の検査（check_production.sh）: 実物の選択・疑似は構築できない・疑似の経路が 404・Secure の Cookie・コールバックの Location は公開オリジン
#   11. 変異の確認（mutation_check.sh）: アプリケーションの 1 か所を壊すと、該当するスペックが落ちること（既定は key の一覧。MUTATION_SET=all で全部）
#   12. ソース走査器の自己検査（scan_sources.py --self-test）
#   13. ソースの走査（scan_sources.py）: 絵文字・不可視の文字・削除系コマンド・機密の直書き・秘密鍵のファイル
#
# 使い方: test/pr48/run_all.sh（場所は、このファイル自身から解決する。番号は、PR の番号に改名・置換されたあとのもの）
# 終了コード: 0 = すべて成功（SKIP は成功に数えず、件数を表示する） / 1 = 失敗がある / 2 = 前提の不備（.env が無いなど）
# 環境変数: TEST_DB_NAME（テスト用 DB の名前。既定 bl_test_issue8）・MUTATION_SET（key|all。既定 key）・PLAYWRIGHT_DIR（playwright のディレクトリ。
#           無ければ、npx のキャッシュなどから探す）・ARTIFACT_DIR（スクリーンショットの置き場）・FRONTEND_PORT（既定 3000）・STEP_TIMEOUT（1 手順の上限の秒数。既定 900）
# ハーネスの安全（.claude/TEST-HARNESS-SAFETY.md）: 自己再帰ガード（TH1）・ulimit -u と各手順の timeout（TH3）。ファイルは削除しない
# （一時ファイルは、置いたままにする）。外部サービス（Google・YouTube・reCAPTCHA）・本番へは接続しない。秘密値（.env）は、画面へ出さない。
# 共有の開発環境: backend が古いコード（app/gateways が無いなど）で動いているときだけ、手順 7 の前に backend を再起動する（healthy になるまで待つ）。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
cd "$ROOT_DIR" || exit 2

# TH1: 自己再帰ガード
if [[ -n "${ISSUE08_RUN_ALL_ACTIVE:-}" ]]; then
  echo "SKIP run_all.sh が自分自身を再帰的に起動しました。実行しません（TH1）"
  exit 0
fi
export ISSUE08_RUN_ALL_ACTIVE=1
# TH3: プロセス数の上限
ulimit -u 8192 2>/dev/null || {
  echo "FAIL プロセス数の上限（ulimit -u）を設定できません。中止します（TH3）"
  exit 2
}
[[ -f "$ROOT_DIR/.env" ]] || {
  echo "FAIL .env がありません。先に scripts/setup_dev_env.sh を実行してください" >&2
  exit 2
}
for tool in curl python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "FAIL ${tool} が見つかりません（ホストに必要です）" >&2
    exit 2
  }
done

export TEST_DB_NAME="${TEST_DB_NAME:-bl_test_issue8}"
if [[ ! "$TEST_DB_NAME" =~ ^bl_test_[a-z0-9_]{1,50}$ ]]; then
  echo "FAIL テスト用の DB の名前ではありません: $TEST_DB_NAME（bl_test_ で始まる、小文字・数字・アンダースコアの名前に限ります）" >&2
  exit 2
fi
export STEP_TIMEOUT="${STEP_TIMEOUT:-900}"
export FRONTEND_PORT="${FRONTEND_PORT:-3000}"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/issue08.XXXXXX")"
echo "各手順のログの置き場（削除しません）: $LOG_DIR"

# この issue のスペックと、変更した #7 の基盤のスペック（ほかの issue のスペック（spec/services の利用枠・台帳など）は含めない）
MY_SPECS=(
  spec/gateways
  spec/controllers
  spec/requests
  spec/sources
  spec/config
  spec/lib
  spec/services/account_registry_spec.rb
  spec/services/login_procedure_spec.rb
  spec/services/bff_guard_spec.rb
  spec/services/client_ip_spec.rb
  spec/services/cookies_spec.rb
  spec/services/csrf_token_spec.rb
  spec/services/oauth_state_cookie_spec.rb
  spec/services/public_origin_spec.rb
  spec/services/rate_limit_policy_spec.rb
  spec/services/rate_limiter_spec.rb
  spec/services/session_store_spec.rb
  spec/services/usage_recorder_spec.rb
)
# この issue のアプリケーション・config のファイル（RuboCop の対象）
MY_APP_FILES=(
  app/gateways
  app/services/account_registry.rb
  app/services/login_procedure.rb
  app/controllers
  config/routes.rb
  config/environments/development.rb
  config/initializers/locale.rb
  Gemfile
)

results=()
status=0
step=0

# execute <ログ> <コマンド...>: コマンドを timeout つきで実行し、出力をログへも残す。STDIN_FILE があれば標準入力へ渡す
execute() {
  local log="$1"
  shift
  if [[ -n "${STDIN_FILE:-}" ]]; then
    timeout --kill-after=30 "${STEP_LIMIT:-$STEP_TIMEOUT}" "$@" <"$STDIN_FILE" 2>&1 | tee "$log"
  else
    timeout --kill-after=30 "${STEP_LIMIT:-$STEP_TIMEOUT}" "$@" 2>&1 </dev/null | tee "$log"
  fi
  return "${PIPESTATUS[0]}"
}

# 出力から、結果の要約の行を拾う
summarize() {
  grep -hE 'examples?, [0-9]+ failures?|[0-9]+ files? inspected|No warnings found|No vulnerabilities found|件を確認しました|^すべて成功|^自己検査|^問題ありません|^PASS|^すべての変異|^All is good' "$1" | tail -2 | tr '\n' ' '
}

# run <ラベル> <コマンド...>: 終了コード 0 = 成功、3 = 確認できなかった（SKIP）、それ以外 = 失敗
run() {
  local label="$1"
  shift
  step=$((step + 1))
  local log="$LOG_DIR/step${step}.log"
  printf '\n######## %d. %s\n' "$step" "$label"
  local code summary
  execute "$log" "$@"
  code=$?
  summary="$(summarize "$log")"
  case "$code" in
    0) results+=("成功  $step. $label  [$summary]") ;;
    3) results+=("SKIP  $step. $label  [確認できなかった]") ;;
    *)
      results+=("失敗  $step. $label  [終了コード $code。$(grep -hE '^FAIL|failures?|違反' "$log" | tail -2 | tr '\n' ' ')]")
      status=1
      ;;
  esac
}

echo "######## 0. コンテナの起動（scripts/dc.sh up -d --wait）"
if ! timeout --kill-after=30 "$STEP_TIMEOUT" scripts/dc.sh up -d --wait db backend frontend </dev/null; then
  echo "FAIL db・backend・frontend が healthy になりません。scripts/dc.sh logs --tail 100 backend を確認してください" >&2
  exit 2
fi

run "backend の RSpec と RuboCop（この issue と #7 の基盤のスペック。テスト用 DB: $TEST_DB_NAME）" \
  scripts/test_backend.sh --db "${MY_SPECS[@]}"

run "同じスペックを、Rails の eager_load を有効にして（CI と同じ CI=true）" \
  scripts/dc.sh exec -T -e CI=true -e "TEST_DB_NAME=$TEST_DB_NAME" backend bash /scripts/test_backend.sh --db "${MY_SPECS[@]}"

run "RuboCop（この issue のアプリケーション・config のファイル）" \
  scripts/dc.sh exec -T backend bin/rubocop "${MY_APP_FILES[@]}"

run "Zeitwerk の読み込み検査（app/gateways・app/controllers/dev を含む。eager load ですべて読み込める）" \
  scripts/dc.sh exec -T -e RAILS_ENV=test -e "TEST_DB_NAME=$TEST_DB_NAME" backend \
  sh -c 'export DATABASE_URL="${DATABASE_URL%/bl_development}/${TEST_DB_NAME}"; bin/rails zeitwerk:check'

run "Brakeman（静的解析。警告 0 件）" \
  scripts/dc.sh exec -T backend bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error

run "bundler-audit（jwt・webmock を足した Gemfile.lock。既知の脆弱性が無い）" \
  scripts/dc.sh exec -T backend bin/bundler-audit check --update

# --- 開発サーバーの確認の前に、backend が、この issue のコードで動いていることを確かめる（古ければ、再起動する） ---
echo
echo "######## 準備: backend がこの issue のコード（認証の経路・疑似の Google）で動いているか"
probe="$(scripts/dc.sh exec -T backend sh -c 'curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:3001/api/auth/login/start -H "X-BFF-Secret: $BFF_SHARED_SECRET" -H "X-BL-Client: web" -H "Content-Type: application/json" -d "{}"' </dev/null 2>/dev/null || echo 000)"
if [[ "$probe" == "422" ]]; then
  echo "ok   backend は、認証の経路を持っている（入力不備で 422）"
else
  echo "NOTE backend が古いコードで動いています（応答 $probe）。再起動します（scripts/dc.sh restart backend）"
  timeout --kill-after=30 "$STEP_TIMEOUT" scripts/dc.sh restart backend </dev/null
  if ! timeout --kill-after=30 "$STEP_TIMEOUT" scripts/dc.sh up -d --wait backend </dev/null; then
    echo "FAIL backend が healthy になりません" >&2
    exit 2
  fi
fi

STDIN_FILE="$HERE/live_server_check.rb" run "実サーバー（Puma）への確認（疑似の Google でのログインの全体の流れ・セッション固定化の防止・ログアウト・頻度制限・ログに機密が無いこと）" \
  scripts/dc.sh exec -T backend bin/rails runner -

run "curl での確認（フロントエンドの同一オリジン中継を通した、ログインの流れ）" \
  bash "$HERE/curl_bff_check.sh"

find_playwright() {
  local candidate
  local -a candidates=()
  [[ -n "${PLAYWRIGHT_DIR:-}" ]] && candidates+=("$PLAYWRIGHT_DIR")
  candidates+=("$HERE/node_modules/playwright" "$ROOT_DIR/node_modules/playwright")
  if command -v npm >/dev/null 2>&1; then
    candidates+=("$(npm root -g 2>/dev/null)/playwright")
  fi
  while IFS= read -r candidate; do
    candidates+=("$candidate")
  done < <(ls -dt "${HOME:-/nonexistent}"/.npm/_npx/*/node_modules/playwright 2>/dev/null)
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate/package.json" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}
if command -v node >/dev/null 2>&1 && playwright_dir="$(find_playwright)"; then
  echo "NOTE Playwright: $playwright_dir"
  PLAYWRIGHT_DIR="$playwright_dir" run "実ブラウザ（Playwright の Chromium）: LOG IN WITH GOOGLE から /studio まで・戻る操作の再選択・Cookie の属性" \
    node "$HERE/browser_flow_check.cjs" --repo "$ROOT_DIR"
else
  step=$((step + 1))
  printf '\n######## %d. 実ブラウザ（Playwright の Chromium）\nSKIP Node または Playwright が見つからず、確認できなかった（PLAYWRIGHT_DIR に playwright のディレクトリを指定すると実行できる）\n' "$step"
  results+=("SKIP  $step. 実ブラウザ（Playwright の Chromium）  [確認できなかった]")
fi

run "本番の起動の検査（実物の選択・疑似は構築できない・疑似の経路が 404・Secure の Cookie・コールバックの Location は公開オリジン）" \
  bash "$HERE/check_production.sh"

STEP_LIMIT=2400 run "変異の確認（アプリケーションの 1 か所を壊すと、該当するスペックが落ちること。MUTATION_SET=${MUTATION_SET:-key}）" \
  bash "$HERE/mutation_check.sh"

run "ソース走査器の自己検査（合成したソースで、違反を見逃さず、違反でないものを誤検知しないこと）" \
  python3 -I "$HERE/scan_sources.py" --self-test

run "ソースの走査（絵文字・不可視の文字・削除系コマンド・機密の直書き・秘密鍵のファイル）" \
  python3 -I "$HERE/scan_sources.py" "$ROOT_DIR"

printf '\n######## 結果（PR #48）\n'
printf '%s\n' "${results[@]}"
skips="$(printf '%s\n' "${results[@]}" | grep -c '^SKIP' || true)"
if [[ "$status" -ne 0 ]]; then
  printf '\nFAIL PR #48 のテストに失敗した項目があります（ログ: %s）\n' "$LOG_DIR"
  exit 1
fi
printf '\nPASS PR #48 のテストは、失敗なしです（SKIP %s 件。ログ: %s）\n' "$skips" "$LOG_DIR"
exit 0
