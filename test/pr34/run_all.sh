#!/usr/bin/env bash
# PR #34（issue #2 CI）のテスト一式。.github/workflows/ci.yml を、実行せずに検査する（GitHub 上の実行は PR の Checks で確認する）。
#
#   check_ci.py   構造（トリガー・permissions・アクションの版・timeout・concurrency・各 job の手順の順序）と、
#                 hygiene の各検査の動作（一時の git リポジトリで、違反なら失敗・問題なければ成功）。実際のリポジトリ（HEAD + ci.yml）でも成功すること
#   mutate_ci.py  変異テスト。ci.yml を 1 か所ずつ壊し、check_ci.py が必ず失敗を報告すること
#
# 使い方: test/pr34/run_all.sh [--no-mutation]
# 終了コード: 0 = すべて成功 / 1 = 失敗がある
#
# ハーネスの安全（.claude/TEST-HARNESS-SAFETY.md）: 自己再帰ガード・timeout・ulimit -u。ファイルは削除しない（作業用の一時ファイルは、実行ごとに新しい名前の場所に作る）。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"

if [[ -n "${PR34_RUN_ALL_ACTIVE:-}" ]]; then
  echo "SKIP run_all.sh が自分自身を再帰的に起動しました。実行しません（TH1）"
  exit 0
fi
export PR34_RUN_ALL_ACTIVE=1

ulimit -u 8192 2>/dev/null || {
  echo "FAIL プロセス数の上限（ulimit -u）を設定できません。中止します（TH3）"
  exit 2
}

if ! python3 -I -c "import yaml" 2>/dev/null; then
  echo "FAIL python3 の yaml（PyYAML）がありません。check_ci.py が使います" >&2
  exit 2
fi

run_mutation=1
[[ "${1:-}" == "--no-mutation" ]] && run_mutation=0

WORK_BASE="$(mktemp -d "${TMPDIR:-/tmp}/pr34_work.XXXXXX")"
echo "作業ディレクトリ（一時ファイル。削除しません）: $WORK_BASE"

failed=0
printf '\n==================================================\n実行: check_ci.py\n==================================================\n'
timeout --kill-after=30 900 python3 -I "$HERE/check_ci.py" "$ROOT_DIR" "$WORK_BASE/check" || failed=$((failed + 1))

if [[ "$run_mutation" -eq 1 ]]; then
  printf '\n==================================================\n実行: mutate_ci.py（変異テスト）\n==================================================\n'
  mkdir -p "$WORK_BASE/mutation"
  timeout --kill-after=30 1800 python3 -I "$HERE/mutate_ci.py" "$ROOT_DIR" "$WORK_BASE/mutation" || failed=$((failed + 1))
fi

if [[ "$failed" -ne 0 ]]; then
  printf '\nFAIL PR #34 のテストに失敗した項目があります（%d 件）\n' "$failed"
  exit 1
fi
printf '\nPASS PR #34 のテストはすべて成功しました\n'
exit 0
