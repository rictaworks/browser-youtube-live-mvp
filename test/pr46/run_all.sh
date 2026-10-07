#!/usr/bin/env bash
# PR #46（issue #26「ブラウザ: ソースの取得（カメラ・マイク・画面共有・共有音声）と音声の混合（音声の処理周期でクロックを駆動）」）のテスト一式。
# 対象は開発サーバー（scripts/dc.sh 経由の docker compose の frontend コンテナ）と、ホストの Node（実ブラウザの実測・ソースの走査）。
#
#   0. frontend コンテナの起動
#   1. scripts/test_frontend.sh lib/sources lib/audio public/worklets（ESLint・Jest。実装担当のテスト。疑似の MediaDevices・AudioContext と、Worklet の実行を含む）
#   2. 型検査（tsc --noEmit。lib/sources・lib/audio のソースとテスト。プロジェクト全体の型検査は CI の担当で、ここでは絞る）
#   3. 既存の方針の検査（#22 の lib/source-policy。日本語の直書き・絵文字・alert 系を、lib/ 全体で走査する）
#   4. 開発サーバー（next dev）が、Worklet を /worklets/stream-mixer-processor.js で配ること（200・JavaScript・ファイルと同じ内容）
#   5. 独立の走査（scan_media_sources.cjs。実時計・折り返し再生・自己完結・絵文字・削除系の語。走査器の自己検査つき）
#   6. 実ブラウザ（Playwright の Chromium）での実測（probe_media.cjs。偽のデバイス）。Playwright・Chromium が無ければ SKIP
#
# 使い方: このファイルを実行する（リポジトリのどこからでもよい。場所は、このファイル自身から解決する）
#   事前に scripts/setup_dev_env.sh で .env を作る
#   実ブラウザの実測を行うには、Playwright を導入したディレクトリを ISSUE26_PLAYWRIGHT_DIR で指定する（導入の手順は README.md）
# 終了コード: 0 = 失敗なし（SKIP があっても 0。SKIP は成功に数えず、件数を表示する） / 1 = 失敗がある / 2 = 前提の不足
# ハーネスの安全（.claude/TEST-HARNESS-SAFETY.md）: 自己再帰ガード（TH1）・ulimit -u と各手順の timeout（TH3）。ファイルは作るだけで、手順の中で消さない。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
cd "$ROOT_DIR" || exit 1

if [[ -n "${ISSUE26_RUN_ALL_ACTIVE:-}" ]]; then
  echo "SKIP run_all.sh が自分自身を再帰的に起動しました。実行しません（TH1）"
  exit 0
fi
export ISSUE26_RUN_ALL_ACTIVE=1
ulimit -u 8192 2>/dev/null || {
  echo "FAIL プロセス数の上限（ulimit -u）を設定できません。中止します（TH3）"
  exit 2
}
[[ -f "$ROOT_DIR/.env" ]] || {
  echo "FAIL .env がありません。先に scripts/setup_dev_env.sh を実行してください" >&2
  exit 2
}
command -v node >/dev/null 2>&1 || {
  echo "FAIL node が見つかりません（ソースの走査・実ブラウザの実測に必要です）" >&2
  exit 2
}

STEP_TIMEOUT="${STEP_TIMEOUT:-900}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/issue26.XXXXXX")"
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

printf '######## 0. frontend コンテナの起動\n'
timeout --kill-after=30 "$STEP_TIMEOUT" scripts/dc.sh up -d --wait frontend || {
  echo "FAIL frontend コンテナを起動できません" >&2
  exit 2
}

run_capture "ESLint と Jest（scripts/test_frontend.sh lib/sources lib/audio public/worklets）" "$TMP_DIR/frontend.txt" scripts/test_frontend.sh lib/sources lib/audio public/worklets
jest_summary="$(grep -E '^(Tests|Test Suites):' "$TMP_DIR/frontend.txt" | tr -s ' ' | tr '\n' ' ')"
printf '\n（Jest の件数: %s）\n' "${jest_summary:-取得できませんでした}"

# lib/sources・lib/audio を、プロジェクトの設定（tsconfig.json）を引き継いで型検査する。設定ファイルは、コンテナの /tmp に作る（作業ツリーを変えない）。
# timeout は関数を実行できないため、コンテナの中で実行するシェルのスクリプトを、文字列として渡す
TYPECHECK_SCRIPT='cat > /tmp/tsconfig.issue26.json <<JSON
{
  "extends": "/app/tsconfig.json",
  "include": ["/app/lib/audio/**/*.ts", "/app/lib/sources/**/*.ts"],
  "compilerOptions": { "noEmit": true, "incremental": false, "typeRoots": ["/app/node_modules/@types"] }
}
JSON
npx tsc -p /tmp/tsconfig.issue26.json'
run "型検査（tsc --noEmit。lib/sources・lib/audio のソースとテスト）" scripts/dc.sh exec -T frontend sh -c "$TYPECHECK_SCRIPT"

run "既存の方針の検査（#22 の lib/source-policy。lib/ 全体を走査する）" scripts/dc.sh exec -T frontend npx jest lib/source-policy/repository --ci

# 開発サーバーが Worklet を配ること。Next.js は public/ の下を / から配信する。AudioWorklet の addModule は、JavaScript の MIME 型を要する
SERVED_SCRIPT='const fs = require("fs");
(async () => {
  const url = "http://localhost:3000/worklets/stream-mixer-processor.js";
  const response = await fetch(url);
  const body = await response.text();
  const file = fs.readFileSync("/app/public/worklets/stream-mixer-processor.js", "utf8");
  const type = response.headers.get("content-type") || "";
  const problems = [];
  if (response.status !== 200) problems.push("status " + response.status);
  if (!/javascript/i.test(type)) problems.push("content-type " + type);
  if (body !== file) problems.push("the served body differs from the file");
  console.log("status=" + response.status + " content-type=" + type + " cache-control=" + (response.headers.get("cache-control") || "") + " bytes=" + body.length);
  if (problems.length > 0) {
    console.log("FAIL " + problems.join(", "));
    process.exit(1);
  }
  console.log("ok   開発サーバーが、/worklets/stream-mixer-processor.js を、ファイルと同じ内容で配っています");
})().catch((error) => { console.log("FAIL " + error); process.exit(1); });'
run "開発サーバーが Worklet（/worklets/stream-mixer-processor.js）を配る" scripts/dc.sh exec -T frontend node -e "$SERVED_SCRIPT"

run "独立の走査（scan_media_sources.cjs）" node "$HERE/scan_media_sources.cjs" "$ROOT_DIR"

run_optional "実ブラウザ（Playwright の Chromium）での実測（probe_media.cjs。偽のデバイス）" node "$HERE/probe_media.cjs" --repo "$ROOT_DIR"

printf '\n######## 結果（PR #46 / issue #26）\n'
printf '%s\n' "${results[@]}"
printf '\n合計: 成功 %d 件・SKIP %d 件・失敗 %d 件\n' "$passed" "$skipped" "$failed"
if [[ "$skipped" -gt 0 ]]; then
  printf 'SKIP した項目は、確認できなかったことです（成功には数えていません）。Playwright の導入は README.md を参照してください\n'
fi
if [[ "$failed" -ne 0 ]]; then
  printf '\nFAIL PR #46 のテストに失敗した項目があります\n'
  exit 1
fi
printf '\nPASS PR #46 のテストに、失敗はありません（SKIP %d 件）\n' "$skipped"
exit 0
