#!/usr/bin/env bash
# PR 54（issue #11「YouTube 接続: 段階的な認可・接続時の確認・再確認・チャンネル名のメモリ保持」）のテスト一式。
# 対象は開発サーバー（scripts/dc.sh 経由の docker compose の backend・frontend コンテナ。ホストの localhost）。
# あわせて、#10 のレビューの申し送り（暗号鍵の形式の起動時の検査・行ロックと排他の順序・窓口はトランザクションの外）も含む。
#
#    1. backend の RSpec と RuboCop（この issue のスペックと、周辺のスペック。DB を使う）
#    2. 同じスペックを、Rails の eager_load を有効にして（CI と同じ CI=true）
#    3. RuboCop（この issue のアプリケーション・config のファイル）
#    4. Zeitwerk の読み込み検査（eager load ですべて読み込める）
#    5. Brakeman（静的解析。警告 0 件）
#    6. bundler-audit（既知の脆弱性が無い）
#    7. 起動時の検査（check_startup_key.sh）: TOKEN_ENCRYPTION_KEY の形式が誤りなら、環境を問わず起動に失敗する（値を書かない）
#    8. 実サーバー（Puma）への確認（live_server_check.rb）: 疑似の Google・疑似の YouTube での、YouTube 接続の全体の流れ・再接続・不成立・頻度制限・ログに機密が無いこと
#    9. curl での確認（curl_bff_check.sh）: フロントエンドの同一オリジン中継（http://localhost:3000）を通した、接続の流れ
#   10. 実ブラウザの確認（browser_flow_check.cjs。Playwright の Chromium。無ければ SKIP）: ログインから、疑似の同意画面・戻り先・アカウント画面まで
#   11. 本番の起動の検査（check_production.sh）: 実物の選択・疑似は構築できない・疑似の同意画面の経路が 404・実物の認可 URL
#   12. 変異の確認（mutation_check.sh）: アプリケーションの 1 か所を壊すと、該当するスペックが落ちること（既定は key の一覧。MUTATION_SET=all で全部）
#   13. ソース走査器の自己検査（scan_sources.py --self-test）
#   14. ソースの走査（scan_sources.py）: 絵文字・不可視の文字・削除系コマンド・機密の直書き・秘密鍵のファイル
#
# 使い方: test/pr54/run_all.sh（場所は、このファイル自身から解決する。番号は、PR の番号に改名・置換されたあとのもの）
# 終了コード: 0 = すべて成功（SKIP は成功に数えず、件数を表示する） / 1 = 失敗がある / 2 = 前提の不備（.env が無いなど）
# 環境変数: TEST_DB_NAME（テスト用 DB の名前。既定 bl_test_issue11_run）・MUTATION_SET（key|all。既定 key）・PLAYWRIGHT_DIR（playwright のディレクトリ。
#           無ければ、npx のキャッシュなどから探す）・ARTIFACT_DIR（スクリーンショットの置き場）・FRONTEND_PORT（既定 3000）・STEP_TIMEOUT（1 手順の上限の秒数。既定 900）・
#           RUN_ALL_ONLY（手順の名前をカンマ区切りで挙げると、それだけを実行する。名前: rspec・rspec_ci・rubocop・zeitwerk・brakeman・audit・startup_key・
#           live・curl・browser・production・mutation・scan_selftest・scan。例: RUN_ALL_ONLY=zeitwerk,scan）
# ハーネスの安全（.claude/TEST-HARNESS-SAFETY.md）: 自己再帰ガード（TH1）・ulimit -u と各手順の timeout（TH3）。ファイルは削除しない
# （一時ファイルは、置いたままにする）。外部サービス（Google・YouTube・reCAPTCHA）・本番へは接続しない。秘密値（.env）は、画面へ出さない。
# 共有の開発環境: backend が古いコード（YouTube 接続の経路が無いなど）で動いているときだけ、手順 8 の前に backend を再起動する（healthy になるまで待つ）。
# テスト用 DB: 強制終了した実行が、コミット済みの行（同時の操作のスペックが作るもの）を残すことがある。その DB では、スペックの
# 「接続の行は 0 件」の確認が落ちる。そのときは TEST_DB_NAME を変える（新しい名前の DB は、自動で作られる）。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
cd "$ROOT_DIR" || exit 2

# TH1: 自己再帰ガード
if [[ -n "${ISSUE11_RUN_ALL_ACTIVE:-}" ]]; then
  echo "SKIP run_all.sh が自分自身を再帰的に起動しました。実行しません（TH1）"
  exit 0
fi
export ISSUE11_RUN_ALL_ACTIVE=1
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

export TEST_DB_NAME="${TEST_DB_NAME:-bl_test_issue11_run}"
if [[ ! "$TEST_DB_NAME" =~ ^bl_test_[a-z0-9_]{1,50}$ ]]; then
  echo "FAIL テスト用の DB の名前ではありません: $TEST_DB_NAME（bl_test_ で始まる、小文字・数字・アンダースコアの名前に限ります）" >&2
  exit 2
fi
export STEP_TIMEOUT="${STEP_TIMEOUT:-900}"
export FRONTEND_PORT="${FRONTEND_PORT:-3000}"
RUN_ALL_ONLY="${RUN_ALL_ONLY:-}"
VALID_STEPS="rspec rspec_ci rubocop zeitwerk brakeman audit startup_key live curl browser production mutation scan_selftest scan"
if [[ -n "$RUN_ALL_ONLY" ]]; then
  IFS=',' read -r -a requested_steps <<<"$RUN_ALL_ONLY"
  for requested in "${requested_steps[@]}"; do
    case " $VALID_STEPS " in
      *" $requested "*) ;;
      *)
        echo "FAIL RUN_ALL_ONLY の手順の名前が正しくありません: $requested（使える名前: $VALID_STEPS）" >&2
        exit 2
        ;;
    esac
  done
fi
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/issue11.XXXXXX")"
echo "各手順のログの置き場（削除しません）: $LOG_DIR"

# この issue のスペックの置き場と、周辺（変更した基盤: 頻度制限・疑似の Google・外部サービスの選択・ルート）のスペック。
# ほかの issue のスペック（spec/domain・spec/models・spec/lib など）は含めない
MY_SPECS=(
  spec/config
  spec/gateways
  spec/requests
  spec/services
  spec/sources
)
# この issue のアプリケーション・config のファイル（RuboCop の対象）
MY_APP_FILES=(
  app/controllers
  app/gateways
  app/services
  config/routes.rb
  config/initializers
)

results=()
status=0
step=0

# selected <名前>: RUN_ALL_ONLY が空、または名前が含まれていれば真
selected() {
  [[ -z "$RUN_ALL_ONLY" ]] || [[ ",$RUN_ALL_ONLY," == *",$1,"* ]]
}

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
  grep -hE 'examples?, [0-9]+ failures?|[0-9]+ files? inspected|No warnings found|No vulnerabilities found|件を確認しました|^確認 [0-9]+ 項目|^すべて成功|^自己検査|^問題ありません|^PASS|^すべての変異|^All is good' "$1" | tail -2 | tr '\n' ' '
}

# run <名前> <ラベル> <コマンド...>: 終了コード 0 = 成功、3 = 確認できなかった（SKIP）、それ以外 = 失敗
run() {
  local key="$1"
  local label="$2"
  shift 2
  if ! selected "$key"; then
    return 0
  fi
  step=$((step + 1))
  local log="$LOG_DIR/step${step}_${key}.log"
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

needs_servers=0
for server_step in live curl browser; do
  selected "$server_step" && needs_servers=1
done

echo "######## 0. コンテナの起動（scripts/dc.sh up -d --wait）"
if ! timeout --kill-after=30 "$STEP_TIMEOUT" scripts/dc.sh up -d --wait db backend frontend </dev/null; then
  echo "FAIL db・backend・frontend が healthy になりません。scripts/dc.sh logs --tail 100 backend を確認してください" >&2
  exit 2
fi

run rspec "backend の RSpec と RuboCop（この issue と周辺のスペック。テスト用 DB: $TEST_DB_NAME）" \
  scripts/test_backend.sh --db "${MY_SPECS[@]}"

run rspec_ci "同じスペックを、Rails の eager_load を有効にして（CI と同じ CI=true）" \
  scripts/dc.sh exec -T -e CI=true -e "TEST_DB_NAME=$TEST_DB_NAME" backend bash /scripts/test_backend.sh --db "${MY_SPECS[@]}"

run rubocop "RuboCop（この issue のアプリケーション・config のファイル）" \
  scripts/dc.sh exec -T backend bin/rubocop "${MY_APP_FILES[@]}"

run zeitwerk "Zeitwerk の読み込み検査（app/gateways・app/controllers/dev を含む。eager load ですべて読み込める）" \
  scripts/dc.sh exec -T -e RAILS_ENV=test -e "TEST_DB_NAME=$TEST_DB_NAME" backend \
  sh -c 'export DATABASE_URL="${DATABASE_URL%/bl_development}/${TEST_DB_NAME}"; bin/rails zeitwerk:check'

run brakeman "Brakeman（静的解析。警告 0 件）" \
  scripts/dc.sh exec -T backend bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error

run audit "bundler-audit（既知の脆弱性が無い）" \
  scripts/dc.sh exec -T backend bin/bundler-audit check --update

run startup_key "起動時の検査（TOKEN_ENCRYPTION_KEY の形式が誤りなら、環境を問わず起動に失敗する。値を書かない）" \
  bash "$HERE/check_startup_key.sh"

# --- 開発サーバーの確認の前に、backend が、この issue のコードで動いていることを確かめる（古ければ、再起動する） ---
if [[ "$needs_servers" -eq 1 ]]; then
  echo
  echo "######## 準備: backend がこの issue のコード（YouTube 接続の経路）で動いているか"
  probe="$(scripts/dc.sh exec -T backend sh -c 'curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:3001/api/youtube/connect/start -H "X-BFF-Secret: $BFF_SHARED_SECRET" -H "X-BL-Client: web" -H "Content-Type: application/json" -d "{}"' </dev/null 2>/dev/null || echo 000)"
  if [[ "$probe" == "401" ]]; then
    echo "ok   backend は、YouTube 接続の経路を持っている（ログインなしで 401）"
  else
    echo "NOTE backend が古いコードで動いています（応答 $probe）。再起動します（scripts/dc.sh restart backend）"
    timeout --kill-after=30 "$STEP_TIMEOUT" scripts/dc.sh restart backend </dev/null
    if ! timeout --kill-after=30 "$STEP_TIMEOUT" scripts/dc.sh up -d --wait backend </dev/null; then
      echo "FAIL backend が healthy になりません" >&2
      exit 2
    fi
  fi
fi

STDIN_FILE="$HERE/live_server_check.rb" run live "実サーバー（Puma）への確認（疑似の Google・疑似の YouTube での接続の全体の流れ・再接続・不成立・頻度制限・ログに機密が無いこと）" \
  scripts/dc.sh exec -T backend bin/rails runner -

run curl "curl での確認（フロントエンドの同一オリジン中継を通した、接続の流れ）" \
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
if selected browser; then
  if command -v node >/dev/null 2>&1 && playwright_dir="$(find_playwright)"; then
    echo "NOTE Playwright: $playwright_dir"
    PLAYWRIGHT_DIR="$playwright_dir" run browser "実ブラウザ（Playwright の Chromium）: ログイン・疑似の同意画面・戻り先・アカウント画面・戻る操作での再選択" \
      node "$HERE/browser_flow_check.cjs" --repo "$ROOT_DIR"
  else
    step=$((step + 1))
    printf '\n######## %d. 実ブラウザ（Playwright の Chromium）\nSKIP Node または Playwright が見つからず、確認できなかった（PLAYWRIGHT_DIR に playwright のディレクトリを指定すると実行できる）\n' "$step"
    results+=("SKIP  $step. 実ブラウザ（Playwright の Chromium）  [確認できなかった]")
  fi
fi

run production "本番の起動の検査（実物の選択・疑似は構築できない・疑似の同意画面の経路が 404・実物の認可 URL・接続の経路はある）" \
  bash "$HERE/check_production.sh"

STEP_LIMIT=2400 run mutation "変異の確認（アプリケーションの 1 か所を壊すと、該当するスペックが落ちること。MUTATION_SET=${MUTATION_SET:-key}）" \
  bash "$HERE/mutation_check.sh"

run scan_selftest "ソース走査器の自己検査（合成したソースで、違反を見逃さず、違反でないものを誤検知しないこと）" \
  python3 -I "$HERE/scan_sources.py" --self-test

run scan "ソースの走査（絵文字・不可視の文字・削除系コマンド・機密の直書き・秘密鍵のファイル）" \
  python3 -I "$HERE/scan_sources.py" "$ROOT_DIR"

printf '\n######## 結果（PR #54）\n'
if [[ "${#results[@]}" -eq 0 ]]; then
  echo "FAIL 実行した手順がありません（RUN_ALL_ONLY=$RUN_ALL_ONLY）" >&2
  exit 2
fi
printf '%s\n' "${results[@]}"
skips="$(printf '%s\n' "${results[@]}" | grep -c '^SKIP' || true)"
if [[ "$status" -ne 0 ]]; then
  printf '\nFAIL PR #54 のテストに失敗した項目があります（ログ: %s）\n' "$LOG_DIR"
  exit 1
fi
scope="全手順"
[[ -n "$RUN_ALL_ONLY" ]] && scope="選んだ手順（$RUN_ALL_ONLY）"
printf '\nPASS PR #54 のテストは、失敗なしです（%s。SKIP %s 件。ログ: %s）\n' "$scope" "$skips" "$LOG_DIR"
exit 0
