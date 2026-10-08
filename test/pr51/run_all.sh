#!/usr/bin/env bash
# PR #51（issue #21「中継: WebSocket の受け口（Gin）と結線・設定・停止処理・結合テスト」）のテスト一式。
# 対象は開発サーバー（scripts/dc.sh 経由の docker compose の relay コンテナ）。実際の YouTube・アプリケーションには接続しない
# （結合テストは、疑似のアプリケーションと、疑似の RTMP の受け口。TLS・自己署名）。
#
#   0. relay コンテナの再起動（現在のソースで、開発用のバイナリをビルドし直す）
#   1. 全パッケージのビルド（go build ./...）
#   2. scripts/test_relay.sh（gofmt・go vet・go test。実装担当のテスト：wsapi・server・config・main）
#   3. 競合検出つき（-race -count=1。CI と同じ形）
#   4. 繰り返しと並列度の変更（-race -count=3 -cpu 1,4。時計の注入による決定性・ゴルーチンの残りが無いことの確認）
#   5. 中継の全パッケージ（-race -count=1。#18・#19・#20 など、既存の部品が壊れていないこと）
#   6. 受け入れ条件に対応するテストが、すべて実行され、成功したこと（名前の変更・スキップで、黙って検査されなくならない）
#   7. 依存：go mod verify・go mod tidy の差分が無いこと
#   8. 本番用イメージのビルド（docker build --target production src/relay）
#   9. 開発サーバーの確認：GET /health・GET /ws（実際の WebSocket の接続。無効なチケット・テキスト・2 MiB 超・hello の期限など）
#  10. 走査器の自己検査 / 11. ソースの走査（絵文字・削除系・go.mod・変更の範囲）。go.mod・go.sum と変更の範囲は、PR のブランチの
#      コミット済みの内容を、比較の基準（既定 origin/main。環境変数 PR_BASE_REF で変える）と比べる。作業ツリーの未コミットの変更
#      （他の issue の作業）は見ない。基準を解決できなければ、エラー（終了コード 2。別の基準へ切り替えない）
#
# 使い方: このファイルを実行する（リポジトリのどこからでもよい。場所は、このファイル自身から解決する）
#   事前に scripts/setup_dev_env.sh で .env を作る。origin/main が無い、または古いときは、git fetch origin main で取得するか、
#   PR_BASE_REF=<基準のコミット・ブランチ> test/pr51/run_all.sh のように指定する
# 終了コード: 0 = すべて成功 / 1 = 失敗がある / 2 = 前提の不足（.env が無い、など）
# ハーネスの安全（.claude/TEST-HARNESS-SAFETY.md）: 自己再帰ガード（TH1）・ulimit -u と各手順の timeout（TH3）。ファイルは作るだけで、消さない。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
cd "$ROOT_DIR" || exit 1

if [[ -n "${ISSUE21_RUN_ALL_ACTIVE:-}" ]]; then
  echo "SKIP run_all.sh が自分自身を再帰的に起動しました。実行しません（TH1）"
  exit 0
fi
export ISSUE21_RUN_ALL_ACTIVE=1
ulimit -u 8192 2>/dev/null || {
  echo "FAIL プロセス数の上限（ulimit -u）を設定できません。中止します（TH3）"
  exit 2
}
[[ -f "$ROOT_DIR/.env" ]] || {
  echo "FAIL .env がありません。先に scripts/setup_dev_env.sh を実行してください" >&2
  exit 2
}

STEP_TIMEOUT="${STEP_TIMEOUT:-900}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/issue21.XXXXXX")"
RELAY_PORT="${RELAY_PORT:-3002}"
export RELAY_PORT
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
  if timeout --kill-after=30 "$STEP_TIMEOUT" "$@" 2>&1 | tee "$out"; [[ "${PIPESTATUS[0]}" -eq 0 ]]; then
    results+=("成功  $label")
  else
    results+=("失敗  $label")
    status=1
  fi
}

printf '######## 0. relay コンテナの再起動（現在のソースで、ビルドし直す）\n'
timeout --kill-after=30 "$STEP_TIMEOUT" scripts/dc.sh up -d --wait relay || {
  echo "FAIL relay コンテナを起動できません" >&2
  exit 2
}
timeout --kill-after=30 "$STEP_TIMEOUT" scripts/dc.sh restart relay || {
  echo "FAIL relay コンテナを再起動できません" >&2
  exit 2
}
timeout --kill-after=30 "$STEP_TIMEOUT" scripts/dc.sh up -d --wait relay || {
  echo "FAIL 再起動した relay コンテナが healthy になりません" >&2
  exit 2
}

PACKAGES=(./internal/wsapi/... ./internal/server/... ./internal/config/... .)

run "全パッケージのビルド（go build ./...）" scripts/dc.sh exec -T relay go build ./...
run "実装担当のテスト（gofmt・go vet・go test）" scripts/test_relay.sh "${PACKAGES[@]}"
run "競合検出つきのテスト（-race -count=1）" scripts/test_relay.sh -race -count=1 "${PACKAGES[@]}"
run "繰り返しと並列度の変更（-race -count=3 -cpu 1,4）" scripts/test_relay.sh -race -count=3 -cpu 1,4 ./internal/wsapi/... ./internal/server/...
run "中継の全パッケージ（-race -count=1）" scripts/test_relay.sh -race -count=1

run_capture "実装担当のテストを、すべて実行する（go test -v）" "$TMP_DIR/all.txt" scripts/test_relay.sh -v -count=1 "${PACKAGES[@]}"
run "受け入れ条件に対応するテストが、すべて成功している" python3 -I "$HERE/check_acceptance_tests.py" "$TMP_DIR/all.txt"

run "依存の検証（go mod verify）" scripts/dc.sh exec -T relay go mod verify
run "go.mod・go.sum が整っている（go mod tidy の差分が無い）" scripts/dc.sh exec -T relay go mod tidy -diff
run "本番用イメージのビルド（docker build --target production src/relay）" docker build --target production src/relay

run "開発サーバーの確認（GET /health・GET /ws。実際の WebSocket の接続）" python3 -I "$HERE/dev_server_check.py" --port "$RELAY_PORT"

run "走査器の自己検査" python3 -I "$HERE/scan_sources.py" --self-test
run "ソースの走査（絵文字・削除系・go.mod・変更の範囲。基準 ${PR_BASE_REF:-origin/main}）" python3 -I "$HERE/scan_sources.py" "$ROOT_DIR" "${PR_BASE_REF:-origin/main}"

printf '\n######## 結果（PR #51）\n'
printf '%s\n' "${results[@]}"
if [[ "$status" -ne 0 ]]; then
  printf '\nFAIL PR #51 のテストに失敗した項目があります\n'
  exit 1
fi
printf '\nPASS PR #51 のテストはすべて成功しました\n'
exit 0
