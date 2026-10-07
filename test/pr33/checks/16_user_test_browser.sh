#!/usr/bin/env bash
# pr33-timeout: 600
# PR #33 のユーザーテスト手順 1〜5 を、実ブラウザ（Playwright の Chromium）で確かめる。
# 15_user_test_steps.sh（curl）では確かめられない「緑一色（画面の全画素）」「画面に表示される文字」を、実際に描画して確かめる。
#
# Playwright は、このリポジトリの依存ではない（package.json に足さない）。次の順に探し、見つからなければ SKIP とする。
#   1. 環境変数 PR33_PLAYWRIGHT_DIR（playwright の npm パッケージのディレクトリ）
#   2. test/pr33/node_modules/playwright
#   3. リポジトリ直下の node_modules/playwright
#   4. npm のグローバル（npm root -g）の playwright
#   5. ~/.npm/_npx/*/node_modules/playwright（npx playwright のキャッシュ。新しいものを優先）
# Chromium は Playwright が管理する（~/.cache/ms-playwright）。無ければ SKIP とする（このスクリプトは、取得しない）。
#
# 実際の YouTube・Google を使わない。ブラウザのメディア API（getUserMedia・getDisplayMedia・WebCodecs 等）は、この PR に無いため確認しない。
set -uo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_tools node
require_stack_healthy

find_playwright() {
  local candidate
  local -a candidates=()
  [[ -n "${PR33_PLAYWRIGHT_DIR:-}" ]] && candidates+=("$PR33_PLAYWRIGHT_DIR")
  candidates+=("$PR33_DIR/node_modules/playwright" "$ROOT_DIR/node_modules/playwright")
  if command -v npm >/dev/null 2>&1; then
    candidates+=("$(npm root -g 2>/dev/null)/playwright")
  fi
  # npx のキャッシュ（更新日時の新しい順）
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

if ! playwright_dir="$(find_playwright)"; then
  skip "Playwright が見つからないため、実ブラウザの確認を省略した（PR33_PLAYWRIGHT_DIR に playwright のディレクトリを指定すると実行できる）"
  finish
fi
note "Playwright: ${playwright_dir}"

PR33_PLAYWRIGHT_DIR="$playwright_dir" FRONTEND_PORT="$FRONTEND_PORT" BACKEND_PORT="$BACKEND_PORT" RELAY_PORT="$RELAY_PORT" \
  node "$PR33_LIB_DIR/browser_check.cjs"
status=$?
case "$status" in
  0) exit 0 ;;
  3)
    skip "実ブラウザを使えないため、確認を省略した（上の SKIP の行を参照）"
    exit 0
    ;;
  *) exit 1 ;;
esac
