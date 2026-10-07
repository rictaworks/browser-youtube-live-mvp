#!/usr/bin/env bash
# PR #35（issue #3 契約）のテスト一式。対象は開発サーバー（scripts/dc.sh 経由の docker compose）。
#
#   1. 契約（src/contracts）のテスト（node --test。JSON の件数・符号・ベクタの自己整合）
#   2. Ruby の定数モジュール（Rails を起動しない RSpec）
#   3. TypeScript の定数モジュール（Jest）
#   4. Go の定数パッケージ（go test）
#   5. 契約の文書・データ・定数モジュールに、絵文字と削除系コマンドの実行形が無いこと
#
# 使い方: test/pr35/run_all.sh
# 終了コード: 0 = すべて成功 / 1 = 失敗がある
# ハーネスの安全（.claude/TEST-HARNESS-SAFETY.md）: 自己再帰ガード・ulimit -u・各手順の timeout。ファイルは削除しない。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
cd "$ROOT_DIR" || exit 1

if [[ -n "${PR35_RUN_ALL_ACTIVE:-}" ]]; then
  echo "SKIP run_all.sh が自分自身を再帰的に起動しました。実行しません（TH1）"
  exit 0
fi
export PR35_RUN_ALL_ACTIVE=1
ulimit -u 8192 2>/dev/null || {
  echo "FAIL プロセス数の上限（ulimit -u）を設定できません。中止します（TH3）"
  exit 2
}
[[ -f "$ROOT_DIR/.env" ]] || {
  echo "FAIL .env がありません。先に scripts/setup_dev_env.sh を実行してください" >&2
  exit 2
}

export TEST_DB_NAME="${TEST_DB_NAME:-bl_test_pr35}"
results=()
status=0
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

run "契約（node --test）" scripts/test_contracts.sh
run "Ruby の定数モジュール（Rails を起動しない RSpec）" scripts/test_backend.sh --no-db spec/domain/contract
run "TypeScript の定数モジュール（Jest）" scripts/test_frontend.sh core/contract
run "Go の定数パッケージ（go test）" scripts/test_relay.sh ./core/contract/...
run "絵文字・削除系コマンドの走査" python3 -I "$HERE/scan_contract_files.py" "$ROOT_DIR"

printf '\n######## 結果（PR #35）\n'
printf '%s\n' "${results[@]}"
if [[ "$status" -ne 0 ]]; then
  printf '\nFAIL PR #35 のテストに失敗した項目があります\n'
  exit 1
fi
printf '\nPASS PR #35 のテストはすべて成功しました\n'
exit 0
