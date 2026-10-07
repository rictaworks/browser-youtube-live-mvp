#!/usr/bin/env bash
# すべてのテストを実行する。
#   1. scripts のテスト（dc.sh・setup_dev_env.sh・test_*.sh。docker を呼ばない）
#   2. backend（RSpec・RuboCop・Brakeman・bundler-audit）・frontend（ESLint・tsc・Jest）・relay（gofmt・go vet・go test）
# 1 つが失敗しても、残りを実行し、最後に結果の一覧を出す。すべて緑なら 0、1 つでも赤なら 0 以外を返す。
# 必要なサービスは、各スクリプトが起動する。止めるときは scripts/dc.sh stop。
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

results=()
status=0

run() {
  local label="$1"
  shift
  echo
  echo "######## ${label}"
  if "$@"; then
    results+=("成功  ${label}")
  else
    results+=("失敗  ${label}")
    status=1
  fi
}

run "scripts: dc.sh" bash scripts/tests/test_dc.sh
run "scripts: setup_dev_env.sh" bash scripts/tests/test_setup_dev_env.sh
run "scripts: test_backend.sh・test_frontend.sh・test_relay.sh" bash scripts/tests/test_test_scripts.sh
run "backend" scripts/test_backend.sh
run "frontend" scripts/test_frontend.sh
run "relay" scripts/test_relay.sh

echo
echo "######## 結果"
printf '%s\n' "${results[@]}"
exit "$status"
