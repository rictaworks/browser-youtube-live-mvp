#!/usr/bin/env bash
# PR #44（issue #25「ブラウザ Domain Core（2）: 転送フレームの符号化・送信待ち・適応制御・回線計測」）のテスト一式。
# 対象は開発サーバー（scripts/dc.sh 経由の docker compose の frontend・relay コンテナ）と、ホストの Node（独立した検査・実ブラウザ）。
#
#   0. frontend・relay コンテナの起動
#   1. scripts/test_frontend.sh core/transport core/queue core/governor core/probe core/report
#      （ESLint（この 5 ディレクトリのみ）と Jest（実装担当のテスト。フレーム・送信待ち・適応制御の 7 条件・回線計測・状態報告））
#   2. 受け入れ条件に対応するテストが、すべて実行され、成功したこと（Jest の JSON の結果と、check_acceptance_tests.cjs の表。題の変更・スキップで、黙って検査されなくならない）
#   3. 型検査（tsc --noEmit。この 5 ディレクトリのソースとテスト。プロジェクト全体の型検査は CI の担当）
#   4. 既存の方針の検査（#22 の lib/source-policy：日本語の直書き・絵文字・alert 系。#24 の core/domain-core-rules：実時計・タイマ・DOM・WebSocket・React への依存なし）
#   5. ソースの走査（scan_core_sources.cjs。Jest の走査とは別に実装。契約の数値の直書きも検知。走査器の自己検査つき）
#   6. 共有ベクタの独立した検査と、参照実装との差分テスト（check_vectors.cjs。約 20 万通り）
#   7. 中継（Go）が、同じ共有ベクタを通すこと（scripts/test_relay.sh ./core/frame/...）。ブラウザと中継のコーデックの互換を、両側から確かめる
#   8. 実ブラウザ（Playwright の Chromium）：本物の WebSocket・タイマで、接続 -> 計測 -> 開始 -> 映像・音声 -> 受領応答 -> 状態報告 -> 終了を通す（probe_codec_in_browser.cjs）
#      Playwright が無ければ SKIP（確認できなかった）。README.md に導入の手順
#
# 使い方: このファイルを実行する（リポジトリのどこからでもよい。場所は、このファイル自身から解決する）
#   事前に scripts/setup_dev_env.sh で .env を作る
#   実ブラウザの検査を行うには、Playwright を導入したディレクトリを ISSUE25_PLAYWRIGHT_DIR で指定する（手順は README.md）
# 終了コード: 0 = 失敗なし（SKIP があっても 0。SKIP は成功に数えず、件数を表示する） / 1 = 失敗がある / 2 = 前提の不足
# ハーネスの安全（.claude/TEST-HARNESS-SAFETY.md）: 自己再帰ガード（TH1）・ulimit -u と各手順の timeout（TH3）。ファイルは削除しない。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
cd "$ROOT_DIR" || exit 1

if [[ -n "${ISSUE25_RUN_ALL_ACTIVE:-}" ]]; then
  echo "SKIP run_all.sh が自分自身を再帰的に起動しました。実行しません（TH1）"
  exit 0
fi
export ISSUE25_RUN_ALL_ACTIVE=1
ulimit -u 8192 2>/dev/null || {
  echo "FAIL プロセス数の上限（ulimit -u）を設定できません。中止します（TH3）"
  exit 2
}
[[ -f "$ROOT_DIR/.env" ]] || {
  echo "FAIL .env がありません。先に scripts/setup_dev_env.sh を実行してください" >&2
  exit 2
}
command -v node >/dev/null 2>&1 || {
  echo "FAIL node が見つかりません（独立した検査・実ブラウザの検査に必要です）" >&2
  exit 2
}

STEP_TIMEOUT="${STEP_TIMEOUT:-900}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/issue25.XXXXXX")"
FRONTEND_PATHS=(core/transport core/queue core/governor core/probe core/report)
results=()
passed=0
failed=0
skipped=0

record() { # record <成功|失敗|SKIP> <ラベル>
  case "$1" in
    成功) passed=$((passed + 1)) ;;
    失敗) failed=$((failed + 1)) ;;
    SKIP) skipped=$((skipped + 1)) ;;
  esac
  results+=("$1  $2")
}

# run <ラベル> <コマンド...>：時間制限つきで実行する。0 = 成功、それ以外 = 失敗
run() {
  local label="$1"
  shift
  printf '\n######## %s\n' "$label"
  if timeout --kill-after=30 "$STEP_TIMEOUT" "$@"; then
    record 成功 "$label"
  else
    record 失敗 "$label"
  fi
}

# run_capture <ラベル> <出力ファイル> <コマンド...>：出力を、画面と、ファイルの両方へ。0 = 成功、それ以外 = 失敗
run_capture() {
  local label="$1" out="$2"
  shift 2
  printf '\n######## %s\n' "$label"
  if timeout --kill-after=30 "$STEP_TIMEOUT" "$@" 2>&1 | tee "$out"; then
    record 成功 "$label"
  else
    record 失敗 "$label"
  fi
}

# run_to_file <ラベル> <標準出力のファイル> <コマンド...>：標準出力をファイルへ、標準エラー出力を画面へ。0 = 成功、それ以外 = 失敗
run_to_file() {
  local label="$1" out="$2"
  shift 2
  printf '\n######## %s\n' "$label"
  if timeout --kill-after=30 "$STEP_TIMEOUT" "$@" >"$out"; then
    record 成功 "$label"
  else
    record 失敗 "$label"
  fi
}

# run_optional <ラベル> <コマンド...>：0 = 成功、3 = 確認できなかった（SKIP）、それ以外 = 失敗
run_optional() {
  local label="$1"
  shift
  printf '\n######## %s\n' "$label"
  timeout --kill-after=30 "$STEP_TIMEOUT" "$@"
  local code=$?
  case "$code" in
    0) record 成功 "$label" ;;
    3) record SKIP "$label（確認できなかった）" ;;
    *) record 失敗 "$label（終了コード $code）" ;;
  esac
}

printf '######## 0. frontend・relay コンテナの起動\n'
timeout --kill-after=30 "$STEP_TIMEOUT" scripts/dc.sh up -d --wait frontend relay || {
  echo "FAIL frontend・relay コンテナを起動できません" >&2
  exit 2
}

run_capture "ESLint と Jest（scripts/test_frontend.sh ${FRONTEND_PATHS[*]}）" "$TMP_DIR/frontend.txt" scripts/test_frontend.sh "${FRONTEND_PATHS[@]}"
jest_summary="$(grep -E '^(Tests|Test Suites):' "$TMP_DIR/frontend.txt" | tr -s ' ' | tr '\n' ' ')"
printf '\n（Jest の件数: %s）\n' "${jest_summary:-取得できませんでした}"

run_to_file "Jest の結果（JSON）を取得" "$TMP_DIR/jest.json" scripts/dc.sh exec -T frontend npx jest "${FRONTEND_PATHS[@]}" --ci --json
run "受け入れ条件に対応するテストが、すべて実行され、成功したこと（check_acceptance_tests.cjs）" node "$HERE/check_acceptance_tests.cjs" "$ROOT_DIR" "$TMP_DIR/jest.json"

# 5 ディレクトリを、プロジェクトの設定（tsconfig.json）を引き継いで型検査する。設定ファイルは、コンテナの /tmp に作る（作業ツリーを変えない）。
# timeout は関数を実行できないため、コンテナの中で実行するシェルのスクリプトを、文字列として渡す
TYPECHECK_SCRIPT='cat > /tmp/tsconfig.issue25.json <<JSON
{
  "extends": "/app/tsconfig.json",
  "include": ["/app/core/transport/**/*.ts", "/app/core/queue/**/*.ts", "/app/core/governor/**/*.ts", "/app/core/probe/**/*.ts", "/app/core/report/**/*.ts"],
  "compilerOptions": { "noEmit": true, "incremental": false, "typeRoots": ["/app/node_modules/@types"] }
}
JSON
npx tsc -p /tmp/tsconfig.issue25.json'
run "型検査（tsc --noEmit。5 ディレクトリのソースとテスト）" scripts/dc.sh exec -T frontend sh -c "$TYPECHECK_SCRIPT"

run "既存の方針の検査（#22 の lib/source-policy。日本語の直書き・絵文字・alert 系を、core/ も含めて走査する）" scripts/dc.sh exec -T frontend npx jest lib/source-policy/repository --ci
run "Domain Core の規則の走査（#24 の core/domain-core-rules。実時計・タイマ・DOM・WebSocket・React への依存なし）" scripts/dc.sh exec -T frontend npx jest core/domain-core-rules --ci

run_optional "ソースの走査（scan_core_sources.cjs）" node "$HERE/scan_core_sources.cjs" "$ROOT_DIR"
run_optional "共有ベクタの独立した検査と、参照実装との差分テスト（check_vectors.cjs）" node "$HERE/check_vectors.cjs" "$ROOT_DIR"
run "中継（Go）が、同じ共有ベクタを通すこと（scripts/test_relay.sh ./core/frame/...）" scripts/test_relay.sh ./core/frame/...
run_optional "実ブラウザ（Playwright の Chromium）での一連の流れ（probe_codec_in_browser.cjs）" node "$HERE/probe_codec_in_browser.cjs" --repo "$ROOT_DIR"

printf '\n######## 結果（PR #44 / issue #25）\n'
printf '%s\n' "${results[@]}"
printf '\n合計: 成功 %d 件・SKIP %d 件・失敗 %d 件\n' "$passed" "$skipped" "$failed"
if [[ "$skipped" -gt 0 ]]; then
  printf 'SKIP した項目は、確認できなかったことです（成功には数えていません）。Playwright の導入は README.md を参照してください\n'
fi
if [[ "$failed" -ne 0 ]]; then
  printf '\nFAIL PR #44 のテストに失敗した項目があります\n'
  exit 1
fi
printf '\nPASS PR #44 のテストに、失敗はありません（SKIP %d 件）\n' "$skipped"
exit 0
