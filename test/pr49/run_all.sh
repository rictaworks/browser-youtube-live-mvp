#!/usr/bin/env bash
# PR #49（issue #20「中継: 取り込みセッション・セッション台帳・アプリケーションとの内部通信クライアント」）のテスト一式。
# 対象は開発サーバー（scripts/dc.sh 経由の docker compose の relay コンテナ）。
#
#   0. relay コンテナの起動
#   1. 全パッケージのビルド（go build ./...）
#   2. scripts/test_relay.sh ./internal/session/... ./internal/backend/...（gofmt・go vet・go test。実装担当のテスト）
#   3. 競合検出つき（-race -count=1。CI と同じ形）
#   4. 繰り返しと並列度の変更（-race -count=3 -cpu 1,4。時計の注入による決定性・ゴルーチンの残りが無いことの確認）
#   5. 中継の全パッケージ（-race -count=1 ./...。#18・#19 など、既存の部品が壊れていないこと）
#   6. 受け入れ条件に対応するテストが、すべて実行され、成功したこと（テストの名前の変更・スキップで、黙って検査されなくならない）
#   7. ソースの走査（絵文字・削除系・変更の範囲）と、走査器の自己検査。変更の範囲は、PR のブランチのコミット済みの内容を、
#      比較の基準（既定 origin/main。環境変数 PR_BASE_REF で変える）と比べる。作業ツリーの未コミットの変更（他の issue の作業）は見ない
#
# 使い方: このファイルを実行する（リポジトリのどこからでもよい。場所は、このファイル自身から解決する）
#   事前に scripts/setup_dev_env.sh で .env を作る
# 終了コード: 0 = すべて成功 / 1 = 失敗がある / 2 = 前提の不足（.env が無い、など）
# ハーネスの安全（.claude/TEST-HARNESS-SAFETY.md）: 自己再帰ガード（TH1）・ulimit -u と各手順の timeout（TH3）。ファイルは作るだけで、消さない。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
cd "$ROOT_DIR" || exit 1

if [[ -n "${ISSUE20_RUN_ALL_ACTIVE:-}" ]]; then
  echo "SKIP run_all.sh が自分自身を再帰的に起動しました。実行しません（TH1）"
  exit 0
fi
export ISSUE20_RUN_ALL_ACTIVE=1
ulimit -u 8192 2>/dev/null || {
  echo "FAIL プロセス数の上限（ulimit -u）を設定できません。中止します（TH3）"
  exit 2
}
[[ -f "$ROOT_DIR/.env" ]] || {
  echo "FAIL .env がありません。先に scripts/setup_dev_env.sh を実行してください" >&2
  exit 2
}

STEP_TIMEOUT="${STEP_TIMEOUT:-900}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/issue20.XXXXXX")"
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
run "取り込みセッション・内部通信クライアントのテスト（gofmt・go vet・go test）" scripts/test_relay.sh ./internal/session/... ./internal/backend/...
run "競合検出つきのテスト（-race -count=1）" scripts/test_relay.sh -race -count=1 ./internal/session/... ./internal/backend/...
run "繰り返しと並列度の変更（-race -count=3 -cpu 1,4）" scripts/test_relay.sh -race -count=3 -cpu 1,4 ./internal/session/... ./internal/backend/...
run "中継の全パッケージ（-race -count=1 ./...）" scripts/test_relay.sh -race -count=1

run_capture "取り込みセッション・内部通信クライアントのテストを、すべて実行する（go test -v）" "$TMP_DIR/all.txt" \
  scripts/test_relay.sh -v -count=1 ./internal/session/... ./internal/backend/...
run "受け入れ条件に対応するテストが、すべて成功している" python3 -I "$HERE/check_acceptance_tests.py" "$TMP_DIR/all.txt"

run "走査器の自己検査" python3 -I "$HERE/scan_sources.py" --self-test
run "ソースの走査（絵文字・削除系・変更の範囲）" python3 -I "$HERE/scan_sources.py" "$ROOT_DIR" "${PR_BASE_REF:-origin/main}"

printf '\n######## 結果（PR #49）\n'
printf '%s\n' "${results[@]}"
if [[ "$status" -ne 0 ]]; then
  printf '\nFAIL PR #49 のテストに失敗した項目があります\n'
  exit 1
fi
printf '\nPASS PR #49 のテストはすべて成功しました\n'
exit 0
