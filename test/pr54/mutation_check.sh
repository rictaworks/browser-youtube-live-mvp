#!/usr/bin/env bash
# PR 54（issue #11 YouTube 接続）の、変異の確認。スペックが「効いている」こと（アプリケーションの 1 か所を壊すと、該当するスペックが落ちること）を確かめる。
#
# 手順: mutations.rb（変異のカタログ）を backend コンテナの /tmp へ複写し、変異ごとに、該当するスペックを `rspec -r` で実行する。
#   変異は、実行中のプロセスの中で、メソッドを差し替えるだけ（アプリケーションのファイルは書き換えない）。
#   0. 基準: 変異なしで、対象のスペックがすべて緑であること（赤のままでは、「落ちた」ことが意味を持たない）
#   1. 変異ごと: スペックが落ちること（KILLED）。緑のまま（SURVIVED）なら失敗。実行できなければ失敗。
#      変異の定義の誤り（定数の書き損じ・引数の違いなど）で落ちたものは、「落ちた」と数えず、失敗にする（出力に、定義の誤りを示す例外があれば）
# 変異の一覧は mutations.txt（key = 既定 / all = MUTATION_SET=all のときも実行）。最初の失敗で止める（--fail-fast）ので、落ちる変異は短時間で終わる。
# 使い方: test/pr54/mutation_check.sh
# 環境変数: TEST_DB_NAME（既定 bl_test_issue11_run。DB は、先に scripts/test_backend.sh --db で作られていること）・MUTATION_SET（key|all。既定 key）・
#           MUTATION_ONLY（変異の名前をカンマ区切りで挙げると、それだけを実行する）・SKIP_BASELINE=1（基準を省く。MUTATION_ONLY の再実行用）・
#           INNER_TIMEOUT（1 回の実行の上限の秒数。既定 240）
# 終了コード: 0 = すべて KILLED / 1 = SURVIVED・実行できない・定義の誤りがある / 2 = 前提の不備
# ファイルは削除しない（実行ごとの出力は、mktemp の場所に残す。最後に場所を表示する）。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
DC="$ROOT_DIR/scripts/dc.sh"
cd "$ROOT_DIR" || exit 2

TEST_DB_NAME="${TEST_DB_NAME:-bl_test_issue11_run}"
MUTATION_SET="${MUTATION_SET:-key}"
MUTATION_ONLY="${MUTATION_ONLY:-}"
SKIP_BASELINE="${SKIP_BASELINE:-}"
INNER_TIMEOUT="${INNER_TIMEOUT:-240}"
if [[ ! "$TEST_DB_NAME" =~ ^bl_test_[a-z0-9_]{1,50}$ ]]; then
  echo "FAIL テスト用の DB の名前ではありません: $TEST_DB_NAME（bl_test_ で始まる名前に限ります）" >&2
  exit 2
fi
if [[ ! "$INNER_TIMEOUT" =~ ^[0-9]{1,4}$ ]]; then
  echo "FAIL INNER_TIMEOUT は秒数（整数）で指定してください: $INNER_TIMEOUT" >&2
  exit 2
fi
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/issue11_mutation.XXXXXX")"
echo "各実行の出力の置き場（削除しません）: $LOG_DIR"

# 変異のカタログを、コンテナの /tmp へ複写する（標準入力で渡す）
"$DC" exec -T backend sh -c 'cat > /tmp/issue11_mutations.rb' < "$HERE/mutations.rb" || {
  echo "FAIL 変異のカタログを backend コンテナへ複写できません" >&2
  exit 2
}

# rspec を実行する。引数: 変異の名前 rspec のオプション -- スペック...。標準出力へ、実行の出力を出す。終了コードは rspec のもの。
# コンテナの中でも timeout をかける（外側の timeout だけでは、コンテナの中の rspec が残るため）
run_rspec() {
  local mutation="$1"
  shift
  timeout --kill-after=30 $((INNER_TIMEOUT + 60)) "$DC" exec -T -e "MUTATION=$mutation" -e RAILS_ENV=test -e "TEST_DB_NAME=$TEST_DB_NAME" \
    -e "INNER_TIMEOUT=$INNER_TIMEOUT" backend \
    sh -c 'export DATABASE_URL="${DATABASE_URL%/bl_development}/${TEST_DB_NAME}"; exec timeout --kill-after=10 "$INNER_TIMEOUT" bundle exec rspec -r /tmp/issue11_mutations.rb "$@"' \
    sh "$@" </dev/null 2>&1
}

summary_of() {
  grep -E '[0-9]+ examples?, [0-9]+ failures?' | tail -1
}

# 標準入力の先頭の N 文字だけを出す（日本語を文字の途中で切らない。cut -c は、ロケールによっては、バイトで切る）
clip() {
  python3 -I -c 'import sys; print(sys.stdin.read().strip()[:int(sys.argv[1])])' "$1"
}

# 変異の定義の誤りを示す例外（落ちた理由が、仕様の違反ではなく、変異の書き損じであるもの）
DEFINITION_ERRORS='uninitialized constant|undefined local variable or method|wrong number of arguments|unknown keyword|missing keyword|private constant|SyntaxError|unknown mutation'

failures=0
killed=0

# 0. 基準: 対象のスペックの和集合を、変異なしで実行する
if [[ -z "$SKIP_BASELINE" ]]; then
  mapfile -t all_specs < <(grep -vE '^(#|$)' "$HERE/mutations.txt" | cut -d'|' -f3 | tr ' ' '\n' | sort -u)
  echo "-- 0. 基準（変異なし）: ${#all_specs[@]} 個のスペックのファイルが緑であること"
  output="$(run_rspec baseline "${all_specs[@]}")"
  code=$?
  printf '%s\n' "$output" >"$LOG_DIR/baseline.log"
  if [[ "$code" -eq 0 ]]; then
    printf 'ok   基準は緑（%s）\n' "$(printf '%s\n' "$output" | summary_of)"
  else
    printf 'FAIL 基準が赤です（変異なしで落ちています）: %s\n' "$(printf '%s\n' "$output" | summary_of)"
    printf '%s\n' "$output" | tail -15
    exit 1
  fi
else
  echo "-- 0. 基準は省きました（SKIP_BASELINE）"
fi

echo
echo "-- 1. 変異ごと（MUTATION_SET=$MUTATION_SET${MUTATION_ONLY:+、MUTATION_ONLY=$MUTATION_ONLY}）: スペックが落ちること"
selected=0
while IFS='|' read -r importance name specs; do
  case "$importance" in
    '' | \#*) continue ;;
  esac
  if [[ -n "$MUTATION_ONLY" ]]; then
    case ",$MUTATION_ONLY," in
      *",$name,"*) ;;
      *) continue ;;
    esac
  elif [[ "$MUTATION_SET" != "all" && "$importance" != "key" ]]; then
    continue
  fi
  selected=$((selected + 1))
  read -r -a spec_array <<<"$specs"
  output="$(run_rspec "$name" --fail-fast "${spec_array[@]}")"
  code=$?
  printf '%s\n' "$output" >"$LOG_DIR/$name.log"
  summary="$(printf '%s\n' "$output" | summary_of)"
  first_failure="$(printf '%s\n' "$output" | grep -m1 -E '^  1\) ' | sed -E 's/^ +1\) //' | clip 90)"
  if [[ -z "$summary" ]]; then
    printf 'FAIL %-42s 実行できませんでした: %s\n' "$name" "$(printf '%s\n' "$output" | tail -3 | tr '\n' ' ' | clip 200)"
    failures=$((failures + 1))
  elif [[ "$code" -ne 0 ]] && printf '%s\n' "$output" | grep -qE "$DEFINITION_ERRORS"; then
    printf 'FAIL %-42s 変異の定義の誤りの疑い（%s）。%s を見て、mutations.rb を直してください\n' "$name" \
      "$(printf '%s\n' "$output" | grep -m1 -E "$DEFINITION_ERRORS" | clip 100)" "$LOG_DIR/$name.log"
    failures=$((failures + 1))
  elif [[ "$code" -ne 0 ]]; then
    printf 'ok   %-42s 落ちた（KILLED。%s）%s\n' "$name" "$summary" "${first_failure:+ <- $first_failure}"
    killed=$((killed + 1))
  else
    printf 'FAIL %-42s 緑のまま（SURVIVED。%s）。この変異を検出するスペックがありません\n' "$name" "$summary"
    failures=$((failures + 1))
  fi
done <"$HERE/mutations.txt"

echo
if [[ "$selected" -eq 0 ]]; then
  echo "FAIL 実行する変異がありません（MUTATION_ONLY の名前を確認してください）"
  exit 2
fi
if [[ "$failures" -ne 0 ]]; then
  printf '%d 件失敗しました（落ちた変異: %d 件。出力: %s）\n' "$failures" "$killed" "$LOG_DIR"
  exit 1
fi
printf 'すべての変異（%d 件）で、スペックが落ちました\n' "$killed"
exit 0
