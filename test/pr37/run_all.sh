#!/usr/bin/env bash
# PR #37（issue #18「中継 Domain Core: フレームの符号化・検証・時刻の再基準化・受信量の監視・回線計測・無通信の検出」）のテスト一式。
# 対象は開発サーバー（scripts/dc.sh 経由の docker compose の relay コンテナ）。
#
#   0. relay コンテナの起動
#   1. 全パッケージのビルド（go build ./...）
#   2. scripts/test_relay.sh ./core/...（gofmt・go vet・go test。実装担当のテスト）
#   3. 競合検出つき（-race -count=1 ./core/...。CI と同じ形）
#   4. ファジング（FuzzDecode を -fuzztime=20s。失敗する入力が見つかれば testdata/fuzz/ に残る。残す）
#   5. 共有ベクタ（src/contracts/ws-frame-vectors.json）の全件が、1 件ずつ実行され、成功したこと
#   6. 受け入れ条件に対応するテストが、すべて実行され、成功したこと（テストの名前の変更・スキップで、黙って検査されなくならない）
#   7. ソースの走査（絵文字・削除系・time.Now や net などの参照・グローバル変数・日本語の直書き・変更の範囲）と、走査器の自己検査
#
# 使い方: このファイルを実行する（リポジトリのどこからでもよい。場所は、このファイル自身から解決する）
#   事前に scripts/setup_dev_env.sh で .env を作る
# 終了コード: 0 = すべて成功 / 1 = 失敗がある / 2 = 前提の不足
# ハーネスの安全（.claude/TEST-HARNESS-SAFETY.md）: 自己再帰ガード（TH1）・ulimit -u と各手順の timeout（TH3）。ファイルは削除しない。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
cd "$ROOT_DIR" || exit 1

if [[ -n "${ISSUE18_RUN_ALL_ACTIVE:-}" ]]; then
  echo "SKIP run_all.sh が自分自身を再帰的に起動しました。実行しません（TH1）"
  exit 0
fi
export ISSUE18_RUN_ALL_ACTIVE=1
ulimit -u 8192 2>/dev/null || {
  echo "FAIL プロセス数の上限（ulimit -u）を設定できません。中止します（TH3）"
  exit 2
}
[[ -f "$ROOT_DIR/.env" ]] || {
  echo "FAIL .env がありません。先に scripts/setup_dev_env.sh を実行してください" >&2
  exit 2
}

STEP_TIMEOUT="${STEP_TIMEOUT:-900}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/issue18.XXXXXX")"
results=()
status=0

# run <ラベル> <コマンド...>：時間制限つきで実行し、結果を記録する
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

# run_capture <ラベル> <出力ファイル> <コマンド...>：出力を、画面と、ファイルの両方へ
run_capture() {
  local label="$1" out="$2"
  shift 2
  printf '\n######## %s\n' "$label"
  if timeout --kill-after=30 "$STEP_TIMEOUT" "$@" 2>&1 | tee "$out"; then
    results+=("成功  $label")
  else
    results+=("失敗  $label")
    status=1
  fi
}

printf '######## 0. relay コンテナの起動\n'
timeout --kill-after=30 "$STEP_TIMEOUT" scripts/dc.sh up -d --wait relay || {
  echo "FAIL relay コンテナを起動できません" >&2
  exit 2
}

run "全パッケージのビルド（go build ./...）" scripts/dc.sh exec -T relay go build ./...
run "Domain Core のテスト（gofmt・go vet・go test）" scripts/test_relay.sh ./core/...
run "競合検出つきのテスト（-race -count=1）" scripts/test_relay.sh -race -count=1 ./core/...
run "ファジング（FuzzDecode を 20 秒）" scripts/test_relay.sh -fuzz=FuzzDecode -fuzztime=20s ./core/frame

run_capture "ファジングの対象の一覧（FuzzDecode があること）" "$TMP_DIR/fuzz_list.txt" scripts/test_relay.sh -list='Fuzz.*' ./core/frame
if grep -qx 'FuzzDecode' "$TMP_DIR/fuzz_list.txt"; then
  results+=("成功  FuzzDecode が存在する")
else
  results+=("失敗  FuzzDecode が存在しない")
  status=1
fi

run_capture "共有ベクタを、1 件ずつ実行する（go test -v）" "$TMP_DIR/vectors.txt" \
  scripts/test_relay.sh -v -count=1 -run='TestSharedVectors|TestEncodeMatchesSharedVectors' ./core/frame
run "共有ベクタの全件が、1 件ずつ成功している" \
  python3 -I "$HERE/check_vector_coverage.py" "$ROOT_DIR/src/contracts/ws-frame-vectors.json" "$TMP_DIR/vectors.txt"

run_capture "Domain Core のテストを、すべて実行する（go test -v）" "$TMP_DIR/all.txt" scripts/test_relay.sh -v -count=1 ./core/...
run "受け入れ条件に対応するテストが、すべて成功している" python3 -I "$HERE/check_acceptance_tests.py" "$TMP_DIR/all.txt"

run "走査器の自己検査" python3 -I "$HERE/scan_core_sources.py" --self-test
run "ソースの走査（絵文字・削除系・Domain Core の規則・変更の範囲）" python3 -I "$HERE/scan_core_sources.py" "$ROOT_DIR"

printf '\n######## 結果（PR #37）\n'
printf '%s\n' "${results[@]}"
if [[ "$status" -ne 0 ]]; then
  printf '\nFAIL PR #37 のテストに失敗した項目があります\n'
  exit 1
fi
printf '\nPASS PR #37 のテストはすべて成功しました\n'
exit 0
