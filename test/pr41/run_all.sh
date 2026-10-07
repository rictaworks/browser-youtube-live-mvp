#!/usr/bin/env bash
# PR #41（issue #6「アプリケーション Domain Core（2）: 配信の状態遷移・期限の評価・終了処理・清算・先行配信の清算確認・
# ストリームの取り替え」）のテスト一式。対象は開発サーバー（scripts/dc.sh 経由の docker compose）。
# 純粋な Ruby の Domain Core なので、Rails も DB も使わない。
#
#   1. RSpec（実装担当のスペック spec/domain/lifecycle。Rails を起動しない）と、そのスペックの RuboCop
#   2. RuboCop（Domain Core のファイル app/domain/ の 11 ファイル）
#   3. 絵文字・削除系コマンドの語の走査（変更ファイルとこのディレクトリ）
#   4. Domain Core の規則の走査（入出力の型・実時計・#5 への依存・数値と符号の直書き・日本語の文字列。Ripper）
#   5. 受け入れ条件の検査（公開された API だけで、全体の性質を独立に確かめる）
#   6. 全状態 × 通知なしのシミュレーション（すべての配信が、有限時間で終端へ進む）
#
# 使い方: test/pr41/run_all.sh
# 終了コード: 0 = すべて成功 / 1 = 失敗がある / 2 = 前提が足りない
# ハーネスの安全（.claude/TEST-HARNESS-SAFETY.md）: 自己再帰ガード（TH1）・ulimit -u と各手順の timeout（TH3・TH5）。ファイルは削除しない。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
cd "$ROOT_DIR" || exit 1

# TH1: 自己再帰ガード（子プロセスにだけ環境変数を渡し、子の側で検知したら SKIP する）
if [[ -n "${LIFECYCLE_ISSUE6_RUN_ALL_ACTIVE:-}" ]]; then
  echo "SKIP run_all.sh が自分自身を再帰的に起動しました。実行しません（TH1）"
  exit 0
fi
export LIFECYCLE_ISSUE6_RUN_ALL_ACTIVE=1

# TH3: プロセス数の上限（現在の上限より小さいときだけ設定する。変えられなければ中止する）
PROCESS_LIMIT=8192
current_limit="$(ulimit -u)"
if [[ "$current_limit" == "unlimited" || "$current_limit" -gt "$PROCESS_LIMIT" ]]; then
  ulimit -u "$PROCESS_LIMIT" || {
    echo "FAIL プロセス数の上限（ulimit -u）を設定できません。実行を中止します（TH3）"
    exit 2
  }
fi

if [[ ! -f "$ROOT_DIR/.env" ]]; then
  echo "FAIL .env がありません。先に scripts/setup_dev_env.sh を実行してください" >&2
  exit 2
fi

# テスト用 DB の名前（--no-db のため接続しないが、名前は検証される）。開発 DB（bl_development）は、決して使わない
export TEST_DB_NAME="${TEST_DB_NAME:-bl_test_issue6}"

DOMAIN_FILES=(
  lifecycle_checks lifecycle_time_units directive broadcast_snapshot broadcast_state_machine
  termination_planner deadline_evaluator settlement_rules prior_settlement_check stream_replacement_policy retention_policy
)
domain_paths=()
for name in "${DOMAIN_FILES[@]}"; do
  domain_paths+=("app/domain/${name}.rb")
done

results=()
status=0
# run "見出し" コマンド...: 各手順に timeout（TERM のあと、30 秒で KILL）を付けて実行する
run() {
  local label="$1"
  shift
  printf '\n######## %s\n' "$label"
  if timeout --kill-after=30 600 "$@"; then
    results+=("成功  $label")
  else
    results+=("失敗  $label")
    status=1
  fi
}

# backend のコンテナの中で、標準入力から Ruby のスクリプトを実行する（コンテナへは test/ を渡していないため）。
# スクリプトのパスは、第 1 引数（$1）で渡す
IN_CONTAINER='scripts/dc.sh exec -T backend bundle exec ruby - < "$1"'

run "RSpec と RuboCop（spec/domain/lifecycle。Rails を起動しない）" scripts/test_backend.sh --no-db spec/domain/lifecycle
run "RuboCop（Domain Core の 11 ファイル）" scripts/dc.sh exec -T backend bin/rubocop "${domain_paths[@]}"
run "絵文字・削除系コマンドの語の走査" python3 -I "$HERE/scan_text_hygiene.py" "$ROOT_DIR"
run "Domain Core の規則の走査（入出力・実時計・#5 への依存・直書き）" bash -c "$IN_CONTAINER" _ "$HERE/check_domain_purity.rb"
run "受け入れ条件の検査（独立の実行）" bash -c "$IN_CONTAINER" _ "$HERE/check_acceptance.rb"
run "全状態 × 通知なし: 有限時間で終端へ進む（シミュレーション）" bash -c "$IN_CONTAINER" _ "$HERE/simulate_no_notification.rb"

printf '\n######## 結果（PR #41）\n'
printf '%s\n' "${results[@]}"
if [[ "$status" -ne 0 ]]; then
  printf '\nFAIL PR #41 のテストに失敗した項目があります\n'
  exit 1
fi
printf '\nPASS PR #41 のテストはすべて成功しました\n'
exit 0
