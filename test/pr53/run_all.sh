#!/usr/bin/env bash
# PR #53（取り込みセッションの試験 TestProvisioningDoesNotBlockTheSession の不安定さの修正）のテスト一式。
# 対象は開発サーバー（scripts/dc.sh 経由の docker compose の relay コンテナ）。
#
#   1. 試験のソースの確認（状態報告を取り込み終えてから時計を進める。検査器の自己検査つき）
#   2. 取り込みセッションのパッケージ全体（gofmt・go vet・go test -race -count=1）
#   3. 修正した試験の繰り返し（-race -count=300 -cpu 1,2）
#
# 使い方: このファイルを実行する（場所は、このファイル自身から解決する）。事前に scripts/setup_dev_env.sh で .env を作る
# 終了コード: 0 = すべて成功 / 1 = 失敗がある / 2 = 前提の不足
# ハーネスの安全（.claude/TEST-HARNESS-SAFETY.md）: 自己再帰ガード（TH1）・ulimit -u と各手順の timeout（TH3）
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
cd "$ROOT_DIR" || exit 1

if [[ -n "${PR53_RUN_ALL_ACTIVE:-}" ]]; then
  echo "SKIP run_all.sh が自分自身を再帰的に起動しました。実行しません（TH1）"
  exit 0
fi
export PR53_RUN_ALL_ACTIVE=1
ulimit -u 8192 2>/dev/null || {
  echo "FAIL プロセス数の上限（ulimit -u）を設定できません。中止します（TH3）"
  exit 2
}
[[ -f "$ROOT_DIR/.env" ]] || {
  echo "FAIL .env がありません。先に scripts/setup_dev_env.sh を実行してください" >&2
  exit 2
}

STEP_TIMEOUT="${STEP_TIMEOUT:-900}"
results=()
status=0

run() {
  local label="$1"
  shift
  printf '\n######## %s\n' "$label"
  if timeout --kill-after=30 "$STEP_TIMEOUT" "$@"; then
    results+=("成功  $label")
  else
    results+=("失敗  $label")
    status=1
  fi
}

run "1. 試験のソースの確認" python3 "$HERE/check_barrier_before_advance.py"
run "2. 取り込みセッションのパッケージ全体（-race -count=1）" \
  scripts/test_relay.sh -race -count=1 ./internal/session/
run "3. 修正した試験の繰り返し（-race -count=300 -cpu 1,2）" \
  scripts/test_relay.sh -race -count=300 -cpu 1,2 -run '^TestProvisioningDoesNotBlockTheSession$' ./internal/session/

printf '\n######## 結果（PR #53）\n'
for line in "${results[@]}"; do
  printf '%s\n' "$line"
done
if ((status != 0)); then
  printf '\nFAIL PR #53 のテストに失敗した項目があります\n'
  exit 1
fi
printf '\nPASS PR #53 のテストに、失敗はありません\n'
