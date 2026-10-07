#!/usr/bin/env bash
# PR #47（issue #19 中継: FLV 多重化と RTMPS 送出 - 容器の詰め替え・送出先の検証・送出待ちの管理）のテスト一式。
# 対象は開発サーバー（scripts/dc.sh 経由の docker compose の relay コンテナ）。実際の YouTube へは接続しない。
#
#   1. 実装担当のテスト: gofmt・go vet・go test -race（internal/flv・internal/rtmps ほか internal 全体）
#   2. モジュール全体: gofmt・go vet・go test -race ./...（core・契約・main を含む。この PR が、ほかのパッケージを壊していないこと）
#   3. 繰り返し: -count=3 -shuffle=on（実行の順序・時間への依存が無いこと）
#   4. go test -json の結果をファイルへ書く（5 の入力）
#   5. 受け入れ条件の対応: 4 の結果を、acceptance_map.json（受け入れ条件 17 件 -> テスト）と突き合わせる
#      （列挙したテストが、すべて成功・スキップ 0 件であること）
#   6. ビルドとモジュール: 静的リンクのビルド（CGO_ENABLED=0）・go mod verify・go mod tidy の差分が無いこと
#   7. 本番用イメージのビルド: docker build --target production src/relay（CLAUDE.md のコマンド）
#   8. ファジング 10 秒: 送出先の検証（FuzzValidate）
#   9. ファジング 10 秒: FLV の往復（FuzzMuxerRoundTrip）
#  10. 走査器の自己検査 / 11. 照合器の自己検査 / 12. 変異テストの仕組みの自己検査（合成した入力で、違反・見逃しを検出すること）
#  13. ソースの走査: 絵文字・不可視の書式文字・日本語以外の非 ASCII・削除系の語・go.mod の固定（go-rtmp v0.0.7・go-flv v0.3.1）・core が internal を参照しない
#  14. 変異テスト（既定で実行。十数分かかる。--no-mutation で省略。省略は「省略」として数え、成功とはみなさない）:
#      実装を 1 か所ずつ壊し（80 件超）、テストが必ず失敗すること
#
# 使い方: test/pr47/run_all.sh [--no-mutation]
# 終了コード: 0 = すべて成功 / 1 = 失敗がある / 2 = 準備ができていない（.env が無い・引数の誤りなど）
# ハーネスの安全（.claude/TEST-HARNESS-SAFETY.md）: 自己再帰ガード・ulimit -u・各手順の timeout。ファイルは削除しない。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
cd "$ROOT_DIR" || exit 1

if [[ -n "${RELAY_PUBLISH_RUN_ALL_ACTIVE:-}" ]]; then
  echo "SKIP run_all.sh が自分自身を再帰的に起動しました。実行しません（TH1）"
  exit 0
fi
export RELAY_PUBLISH_RUN_ALL_ACTIVE=1
ulimit -u 8192 2>/dev/null || {
  echo "FAIL プロセス数の上限（ulimit -u）を設定できません。中止します（TH3）"
  exit 2
}

with_mutation=1
for argument in "$@"; do
  case "$argument" in
    --no-mutation) with_mutation=0 ;;
    *)
      echo "FAIL 未知の引数です: $argument（使い方: run_all.sh [--no-mutation]）" >&2
      exit 2
      ;;
  esac
done

[[ -f "$ROOT_DIR/.env" ]] || {
  echo "FAIL .env がありません。先に scripts/setup_dev_env.sh を実行してください" >&2
  exit 2
}

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/relay_publish.XXXXXX")"
echo "各手順のログの置き場（削除しません）: $LOG_DIR"

results=()
status=0
skipped=0
step=0

# run <ラベル> <コマンド...>: コマンドを timeout つきで実行し、出力をログへも残す。成功は 0
run() {
  local label="$1"
  shift
  step=$((step + 1))
  local log="$LOG_DIR/step${step}.log"
  printf '\n######## %d. %s\n' "$step" "$label"
  local summary
  if timeout --kill-after=30 "${STEP_TIMEOUT:-900}" "$@" 2>&1 | grep -v 'Changing chunkSize' | tee "$log"; [[ "${PIPESTATUS[0]}" -eq 0 ]]; then
    summary="$(grep -hE '^ok |^PASS|^成功|^問題ありません|^受け入れ条件|^自己検査|^検出 [0-9]+ 件|^all modules verified|^[0-9]+ ファイル' "$log" | tail -3 | tr '\n' ' ')"
    results+=("成功  $label  [$summary]")
  else
    summary="$(grep -hE '^FAIL|^--- FAIL|^問題|^失敗|panic:' "$log" | head -3 | tr '\n' ' ')"
    results+=("失敗  $label  [$summary]")
    status=1
  fi
}

# capture <出力ファイル> <ラベル> <コマンド...>: 標準出力をファイルへ書く（go test -json など）。標準エラーは画面とログへ
capture() {
  local output="$1"
  local label="$2"
  shift 2
  step=$((step + 1))
  local log="$LOG_DIR/step${step}.log"
  printf '\n######## %d. %s\n' "$step" "$label"
  if timeout --kill-after=30 "${STEP_TIMEOUT:-900}" "$@" >"$output" 2>"$log"; then
    results+=("成功  $label  [$(wc -l <"$output") 行を $output へ書きました]")
  else
    cat "$log"
    results+=("失敗  $label  [終了コード非 0。ログ: $log]")
    status=1
  fi
}

run "実装担当のテスト（gofmt・go vet・go test -race。internal 全体）" \
  scripts/test_relay.sh -race -count=1 ./internal/...

run "モジュール全体（gofmt・go vet・go test -race ./...。core・契約・main を含む）" \
  scripts/test_relay.sh -race -count=1 ./...

run "繰り返し（-count=3 -shuffle=on。順序・時間への依存が無いこと）" \
  scripts/test_relay.sh -race -count=3 -shuffle=on ./internal/flv/... ./internal/rtmps/...

capture "$LOG_DIR/gotest.json" "go test -json（受け入れ条件の照合の入力）" \
  scripts/dc.sh exec -T relay sh -c 'cd /app && GIN_MODE=test go test -json -count=1 -race ./internal/flv/... ./internal/rtmps/...'

run "受け入れ条件の対応（17 件 -> テスト。列挙したテストがすべて成功・スキップ 0 件）" \
  python3 -I "$HERE/check_acceptance.py" "$LOG_DIR/gotest.json" "$HERE/acceptance_map.json" "$ROOT_DIR"

run "ビルドとモジュール（静的リンクのビルド・go mod verify・go mod tidy の差分が無いこと）" \
  scripts/dc.sh exec -T relay sh -c 'cd /app && CGO_ENABLED=0 GOOS=linux go build ./... && go mod verify && go mod tidy -diff && echo "問題ありません"'

STEP_TIMEOUT=1200 run "本番用イメージのビルド（docker build --target production src/relay）" \
  docker build --target production --tag bl-relay-issue19-prod:check src/relay

run "ファジング（FuzzValidate を 10 秒）" \
  scripts/dc.sh exec -T relay sh -c 'cd /app && GIN_MODE=test go test -run "^$" -fuzz "^FuzzValidate$" -fuzztime 10s ./internal/rtmps/'

run "ファジング（FuzzMuxerRoundTrip を 10 秒）" \
  scripts/dc.sh exec -T relay sh -c 'cd /app && GIN_MODE=test go test -run "^$" -fuzz "^FuzzMuxerRoundTrip$" -fuzztime 10s ./internal/flv/'

run "走査器の自己検査（合成したソースで、違反を見逃さず、違反でないものを誤検知しないこと）" \
  python3 -I "$HERE/scan_sources.py" --self-test

run "受け入れ条件の照合器の自己検査" \
  python3 -I "$HERE/check_acceptance.py" --self-test

run "変異テストの仕組みの自己検査" \
  python3 -I "$HERE/mutate_relay.py" --self-test

run "ソースの走査（絵文字・不可視の書式文字・日本語以外の非 ASCII・削除系の語・go.mod の固定・core が internal を参照しない）" \
  python3 -I "$HERE/scan_sources.py" "$ROOT_DIR" "$HERE"

if [[ "$with_mutation" -eq 1 ]]; then
  STEP_TIMEOUT=3000 run "変異テスト（実装を 1 か所ずつ壊し、テストが必ず失敗すること）" \
    python3 -I "$HERE/mutate_relay.py" "$ROOT_DIR"
else
  results+=("省略  変異テスト（--no-mutation が指定されたため。成功とはみなしません）")
  skipped=$((skipped + 1))
fi

printf '\n######## 結果（PR #47）\n'
printf '%s\n' "${results[@]}"
printf '\n省略: %d 件' "$skipped"
if [[ "$skipped" -ne 0 ]]; then
  printf '（省略した手順は、成功とはみなしていません）'
fi
printf '\n'
if [[ "$status" -ne 0 ]]; then
  printf '\nFAIL PR #47 のテストに失敗した項目があります（ログ: %s）\n' "$LOG_DIR"
  exit 1
fi
printf '\nPASS PR #47 のテストは、実行した手順がすべて成功しました（省略 %d 件。ログ: %s）\n' "$skipped" "$LOG_DIR"
exit 0
