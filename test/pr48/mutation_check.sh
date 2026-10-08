#!/usr/bin/env bash
# PR #48（issue #8 認証）の、変異の確認。スペックが「効いている」こと（アプリケーションの 1 か所を壊すと、該当するスペックが落ちること）を確かめる。
#
# 手順: mutations.rb（変異のカタログ）を backend コンテナの /tmp へ複写し、変異ごとに、該当するスペックを `rspec -r` で実行する。
#   変異は、実行中のプロセスの中で、メソッドを差し替えるだけ（アプリケーションのファイルは書き換えない）。
#   0. 基準: 変異なしで、対象のスペックがすべて緑であること（赤のままでは、「落ちた」ことが意味を持たない）
#   1. 変異ごと: スペックが落ちること（KILLED）。緑のまま（SURVIVED）なら失敗。実行できなければ失敗
# 変異の一覧は mutations.txt（key = 既定 / all = MUTATION_SET=all のときも実行）。
# 使い方: test/pr48/mutation_check.sh。環境変数: TEST_DB_NAME（既定 bl_test_issue8）・MUTATION_SET（key|all。既定 key）
# 終了コード: 0 = すべて KILLED / 1 = SURVIVED・実行できないものがある / 2 = 前提の不備
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
DC="$ROOT_DIR/scripts/dc.sh"
cd "$ROOT_DIR" || exit 2

TEST_DB_NAME="${TEST_DB_NAME:-bl_test_issue8}"
MUTATION_SET="${MUTATION_SET:-key}"
if [[ ! "$TEST_DB_NAME" =~ ^bl_test_[a-z0-9_]{1,50}$ ]]; then
  echo "FAIL テスト用の DB の名前ではありません: $TEST_DB_NAME（bl_test_ で始まる名前に限ります）" >&2
  exit 2
fi

# 変異のカタログを、コンテナの /tmp へ複写する（標準入力で渡す）
"$DC" exec -T backend sh -c 'cat > /tmp/issue8_mutations.rb' < "$HERE/mutations.rb" || {
  echo "FAIL 変異のカタログを backend コンテナへ複写できません" >&2
  exit 2
}

# rspec を実行する。引数: 変異の名前 スペック...。標準出力へ、実行の出力を出す。終了コードは rspec のもの
run_rspec() {
  local mutation="$1"
  shift
  timeout --kill-after=30 280 "$DC" exec -T -e "MUTATION=$mutation" -e RAILS_ENV=test -e "TEST_DB_NAME=$TEST_DB_NAME" backend \
    sh -c 'export DATABASE_URL="${DATABASE_URL%/bl_development}/${TEST_DB_NAME}"; bundle exec rspec -r /tmp/issue8_mutations.rb "$@"' sh "$@" </dev/null 2>&1
}

summary_of() {
  grep -E '[0-9]+ examples?, [0-9]+ failures?' | tail -1
}

failures=0
killed=0

# 0. 基準: 対象のスペックの和集合を、変異なしで実行する
mapfile -t all_specs < <(grep -vE '^(#|$)' "$HERE/mutations.txt" | cut -d'|' -f3 | tr ' ' '\n' | sort -u)
echo "-- 0. 基準（変異なし）: ${#all_specs[@]} 個のスペックのファイルが緑であること"
output="$(run_rspec baseline "${all_specs[@]}")"
code=$?
if [[ "$code" -eq 0 ]]; then
  printf 'ok   基準は緑（%s）\n' "$(printf '%s\n' "$output" | summary_of)"
else
  printf 'FAIL 基準が赤です（変異なしで落ちています）: %s\n' "$(printf '%s\n' "$output" | summary_of)"
  printf '%s\n' "$output" | tail -15
  exit 1
fi

echo
echo "-- 1. 変異ごと（MUTATION_SET=$MUTATION_SET）: スペックが落ちること"
while IFS='|' read -r importance name specs; do
  case "$importance" in
    '' | \#*) continue ;;
  esac
  if [[ "$MUTATION_SET" != "all" && "$importance" != "key" ]]; then
    continue
  fi
  read -r -a spec_array <<<"$specs"
  output="$(run_rspec "$name" "${spec_array[@]}")"
  code=$?
  summary="$(printf '%s\n' "$output" | summary_of)"
  if [[ -z "$summary" ]]; then
    printf 'FAIL %-38s 実行できませんでした: %s\n' "$name" "$(printf '%s\n' "$output" | tail -3 | tr '\n' ' ' | cut -c1-200)"
    failures=$((failures + 1))
  elif [[ "$code" -ne 0 ]]; then
    printf 'ok   %-38s 落ちた（KILLED。%s）\n' "$name" "$summary"
    killed=$((killed + 1))
  else
    printf 'FAIL %-38s 緑のまま（SURVIVED。%s）。この変異を検出するスペックがありません\n' "$name" "$summary"
    failures=$((failures + 1))
  fi
done <"$HERE/mutations.txt"

echo
if [[ "$failures" -ne 0 ]]; then
  printf '%d 件失敗しました（落ちた変異: %d 件）\n' "$failures" "$killed"
  exit 1
fi
printf 'すべての変異（%d 件）で、スペックが落ちました\n' "$killed"
exit 0
