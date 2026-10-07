#!/usr/bin/env bash
# PR #33（issue #1 開発環境の整備）のテスト一式。対象は開発サーバー（scripts/dc.sh 経由の docker compose。ホストの localhost）。
#
# checks/*.sh を番号順に実行し、結果を集計する。各チェックの先頭 2 行目の「# pr33-timeout: 秒」が、そのチェックの上限時間。
#
# 使い方:
#   test/pr33/run_all.sh [--stop] [チェックのファイル名の一部...]
#     --stop   最後に scripts/dc.sh stop で止める（down・run --rm は使わない）
#     名前     指定した文字列を含むチェックだけを実行する（例: run_all.sh 15_ 16_）
#
# 終了コード: 0 = すべて成功（SKIP があっても 0。集計に出る） / 1 = 失敗がある
#
# ハーネスの安全（.claude/TEST-HARNESS-SAFETY.md）
#   TH1 自己再帰ガード: このスクリプトの中から、このスクリプト自身を起動しない（起動されたら即座に SKIP する）
#   TH3 初回の保険:     プロセス数の上限（ulimit -u）と、チェックごとの timeout を設定してから実行する
#   TH5 CI 側の二重化:  CI で実行する場合も、呼び出し側のコマンドに timeout を付ける
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"

# TH1: 自己再帰ガード（子プロセスにだけ環境変数を渡し、子の側で検知したら SKIP する）
if [[ -n "${PR33_RUN_ALL_ACTIVE:-}" ]]; then
  echo "SKIP run_all.sh が自分自身を再帰的に起動しました。実行しません（TH1）"
  exit 0
fi

# TH3: プロセス数の上限（現在の上限より小さいときだけ設定する。変えられなければ中止する）
PROCESS_LIMIT=8192
current_limit="$(ulimit -u)"
if [[ "$current_limit" != "unlimited" && "$current_limit" -gt "$PROCESS_LIMIT" ]] || [[ "$current_limit" == "unlimited" ]]; then
  ulimit -u "$PROCESS_LIMIT" || {
    echo "FAIL プロセス数の上限（ulimit -u）を設定できません。実行を中止します（TH3）"
    exit 2
  }
fi

do_stop=0
filters=()
for arg in "$@"; do
  case "$arg" in
    --stop) do_stop=1 ;;
    -*)
      echo "FAIL 不明なオプションです: $arg" >&2
      exit 2
      ;;
    *) filters+=("$arg") ;;
  esac
done

if [[ ! -f "$ROOT_DIR/.env" ]]; then
  echo "FAIL .env がありません。先に scripts/setup_dev_env.sh を実行してください" >&2
  exit 2
fi

DEFAULT_TIMEOUT=600
declare -a names=() results=() seconds=()

for check in "$HERE"/checks/*.sh; do
  name="$(basename "$check")"
  if [[ "${#filters[@]}" -gt 0 ]]; then
    matched=0
    for f in "${filters[@]}"; do
      [[ "$name" == *"$f"* ]] && matched=1
    done
    [[ "$matched" -eq 1 ]] || continue
  fi

  limit="$(sed -n '2s/^# pr33-timeout: *\([0-9][0-9]*\).*$/\1/p' "$check")"
  limit="${limit:-$DEFAULT_TIMEOUT}"

  printf '\n==================================================\n'
  printf '実行: %s（上限 %s 秒）\n' "$name" "$limit"
  printf '==================================================\n'

  started=$SECONDS
  PR33_RUN_ALL_ACTIVE=1 timeout --kill-after=30 "$limit" bash "$check"
  code=$?
  elapsed=$((SECONDS - started))

  case "$code" in
    0) result="成功" ;;
    1) result="失敗" ;;
    2) result="失敗（前提を満たさない）" ;;
    124 | 137) result="失敗（時間切れ）" ;;
    *) result="失敗（終了コード ${code}）" ;;
  esac
  names+=("$name")
  results+=("$result")
  seconds+=("$elapsed")
done

if [[ "$do_stop" -eq 1 ]]; then
  printf '\n--- 止めます（scripts/dc.sh stop）\n'
  "$ROOT_DIR/scripts/dc.sh" stop || echo "FAIL 停止に失敗しました"
fi

printf '\n==================================================\n'
printf '結果（PR #33）\n'
printf '==================================================\n'
failed=0
for i in "${!names[@]}"; do
  printf '%-34s %-26s %5s 秒\n' "${names[$i]}" "${results[$i]}" "${seconds[$i]}"
  [[ "${results[$i]}" == "成功" ]] || failed=$((failed + 1))
done

if [[ "${#names[@]}" -eq 0 ]]; then
  echo "FAIL 実行するチェックがありません（名前の指定が、どのチェックにも一致しません）"
  exit 1
fi
if [[ "$failed" -ne 0 ]]; then
  printf '\nFAIL PR #33 のテストに失敗した項目があります（%d 件）。上記のログを確認してください。\n' "$failed"
  exit 1
fi
printf '\nPASS PR #33 のテストはすべて成功しました\n'
exit 0
