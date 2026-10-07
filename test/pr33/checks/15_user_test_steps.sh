#!/usr/bin/env bash
# pr33-timeout: 1800
# PR #33 に書かれたユーザーテスト手順 1〜5 の実行スクリプト（curl 版）。対象は開発サーバー（ホストの localhost）。
#
#   手順 1  http://localhost:3000/healthz を開くと、{"status":"ok"} と表示される
#   手順 2  http://localhost:3001/up を開くと、緑一色のページが表示される
#   手順 3  http://localhost:3002/health を開くと、{"status":"ok"} と表示される
#   手順 4  http://localhost:3101/up は開けない（内部通信の口が外から届かないことの確認）
#   手順 5  存在しないページ（http://localhost:3000/pr33-no-such-page）を開くと、404 の表示になる
#           （PR #33 の時点では / も 404 だったが、ページの追加で変わるため、存在しないパスで確かめる）
#   補足    db のポート 5432 がホストへ公開されていない
#
# 前提: scripts/setup_dev_env.sh と scripts/dc.sh up -d --wait を済ませていること（開発サーバーが healthy）。
# 実ブラウザでの確認（緑一色の画素・404 の画面）は 16_user_test_browser.sh。
#
# 使い方:
#   checks/15_user_test_steps.sh [--up] [--stop]
#     --up    最初に scripts/dc.sh up -d --wait を実行する（起動済みなら何も変わらない）
#     --stop  最後に scripts/dc.sh stop で止める（down・run --rm は使わない）
set -uo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_tools curl jq awk sed grep
do_up=0
do_stop=0
for arg in "$@"; do
  case "$arg" in
    --up) do_up=1 ;;
    --stop) do_stop=1 ;;
    *) abort "知らないオプションです: $arg（使えるのは --up・--stop）" ;;
  esac
done

if [[ "$do_up" -eq 1 ]]; then
  section "準備: scripts/dc.sh up -d --wait"
  if "$DC" up -d --wait >/dev/null 2>&1; then pass "up -d --wait が成功した"; else abort "up -d --wait が失敗しました"; fi
fi
require_stack_healthy

# --- 手順 1 ---
section "手順 1: ${FRONTEND_URL}/healthz を開くと {\"status\":\"ok\"} と表示される"
http_get "${FRONTEND_URL}/healthz"
expect_eq "手順 1: HTTP 200" "200" "$HTTP_STATUS"
expect_eq "手順 1: 表示される本文は {\"status\":\"ok\"}" '{"status":"ok"}' "$(trim "$HTTP_BODY")"
expect_json "手順 1: 本文は JSON で、status だけを持ち、値は ok" '. == {"status":"ok"}' "$HTTP_BODY"
case "$(header_value content-type)" in
  application/json*) pass "手順 1: Content-Type は application/json" ;;
  *) fail "手順 1: Content-Type は application/json（実際: $(header_value content-type)）" ;;
esac
expect_eq "手順 1: Cache-Control は no-store（毎回評価する）" "no-store" "$(header_value cache-control)"
expect_eq "手順 1: X-Powered-By を返さない（使っている技術を知らせない）" "" "$(header_value x-powered-by)"

# --- 手順 2 ---
section "手順 2: ${BACKEND_URL}/up を開くと緑一色のページが表示される"
http_get "${BACKEND_URL}/up"
expect_eq "手順 2: HTTP 200" "200" "$HTTP_STATUS"
case "$(header_value content-type)" in
  text/html*) pass "手順 2: Content-Type は text/html（ページとして表示される）" ;;
  *) fail "手順 2: Content-Type は text/html（実際: $(header_value content-type)）" ;;
esac
if grep -qiE 'background-color:[[:space:]]*green' <<<"$HTTP_BODY"; then pass "手順 2: 背景色が緑（green）"; else fail "手順 2: 背景色が緑（green）"; fi
if grep -qiE 'background-color:[[:space:]]*red' <<<"$HTTP_BODY"; then fail "手順 2: 異常を示す赤のページではない"; else pass "手順 2: 異常を示す赤のページではない"; fi
visible_text="$(sed -E 's/<[^>]*>//g' <<<"$HTTP_BODY" | tr -d '[:space:]')"
expect_eq "手順 2: 文字は何も表示されない（緑一色）" "" "$visible_text"

# --- 手順 3 ---
section "手順 3: ${RELAY_URL}/health を開くと {\"status\":\"ok\"} と表示される"
http_get "${RELAY_URL}/health"
expect_eq "手順 3: HTTP 200" "200" "$HTTP_STATUS"
expect_eq "手順 3: 表示される本文は {\"status\":\"ok\"}" '{"status":"ok"}' "$(trim "$HTTP_BODY")"
expect_json "手順 3: 本文は JSON で、status だけを持ち、値は ok" '. == {"status":"ok"}' "$HTTP_BODY"
case "$(header_value content-type)" in
  application/json*) pass "手順 3: Content-Type は application/json" ;;
  *) fail "手順 3: Content-Type は application/json（実際: $(header_value content-type)）" ;;
esac

# --- 手順 4 ---
section "手順 4: http://localhost:${INTERNAL_PORT}/up は開けない（内部通信の口はホストへ届かない）"
http_get "http://localhost:${INTERNAL_PORT}/up" --max-time 10
if [[ "$HTTP_CURL_EXIT" -ne 0 && "$HTTP_STATUS" == "000" ]]; then
  pass "手順 4: localhost:${INTERNAL_PORT} は開けない（接続できない。curl の終了コード ${HTTP_CURL_EXIT}）"
else
  fail "手順 4: localhost:${INTERNAL_PORT} は開けない（HTTP ${HTTP_STATUS} が返った。ホストの別のプロセスが ${INTERNAL_PORT} を使っていないか、ss -ltn で確認してください）"
fi

# ホストの別のアドレス（ループバックの IPv4・IPv6、ホストの各インターフェース）からも届かない。
# 公開側の口（BACKEND_PORT）に届くアドレスだけを対象にする（届かないアドレスで「届かない」と言っても意味が無いため）
addresses=("127.0.0.1" "[::1]")
if command -v hostname >/dev/null 2>&1; then
  while read -r address; do
    [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && addresses+=("$address")
  done < <(hostname -I 2>/dev/null | tr ' ' '\n' | head -n 6)
fi
for address in "${addresses[@]}"; do
  http_get "http://${address}:${BACKEND_PORT}/up" --max-time 10
  if [[ "$HTTP_STATUS" != "200" ]]; then
    skip "手順 4: ${address} は、公開側の口（${BACKEND_PORT}）にも届かないため、確認の対象外にした"
    continue
  fi
  http_get "http://${address}:${INTERNAL_PORT}/up" --max-time 10
  if [[ "$HTTP_CURL_EXIT" -ne 0 && "$HTTP_STATUS" == "000" ]]; then
    pass "手順 4: ${address}（公開側の ${BACKEND_PORT} には届く）から、${INTERNAL_PORT} は開けない"
  else
    fail "手順 4: ${address} から ${INTERNAL_PORT} が開けた（HTTP ${HTTP_STATUS}）"
  fi
done

if command -v ss >/dev/null 2>&1; then
  listeners="$(ss -H -ltn "sport = :${INTERNAL_PORT}" 2>/dev/null | wc -l)"
  expect_eq "手順 4: ホストに ${INTERNAL_PORT} で待ち受けるプロセスが無い" "0" "$listeners"
else
  skip "手順 4: ss コマンドが無いため、ホストの待ち受けの一覧は確認しなかった"
fi

ps_json="$("$DC" ps --format json 2>/dev/null | jq -s '.')"
expect_json "手順 4: docker compose の公開ポート（Publishers）に、backend の ${INTERNAL_PORT} が無い" \
  "[.[] | select(.Service == \"backend\") | .Publishers[]? | select(.TargetPort == ${INTERNAL_PORT} and .PublishedPort > 0)] | length == 0" "$ps_json"
expect_json "手順 4: backend の公開ポートは ${BACKEND_PORT}（公開側）だけ" \
  "[.[] | select(.Service == \"backend\") | .Publishers[]? | select(.PublishedPort > 0) | .PublishedPort] | unique == [${BACKEND_PORT}]" "$ps_json"

# --- 手順 5 ---
section "手順 5: 存在しないページ ${FRONTEND_URL}/pr33-no-such-page を開くと 404 の表示になる"
http_get "${FRONTEND_URL}/pr33-no-such-page"
expect_eq "手順 5: HTTP 404" "404" "$HTTP_STATUS"
if grep -qiE 'Internal Server Error|Unhandled Runtime Error|Application error' <<<"$HTTP_BODY"; then fail "手順 5: エラー画面（500 など）ではなく、404 の画面である"; else pass "手順 5: エラー画面（500 など）ではなく、404 の画面である"; fi
http_get "${FRONTEND_URL}/pr33-no-such-page/nested"
expect_eq "手順 5: 入れ子の存在しないパスも 404" "404" "$HTTP_STATUS"

# --- 補足: db はホストへ公開しない ---
section "補足: db のポート ${DB_PORT} はホストへ公開されていない"
expect_json "補足: docker compose の公開ポート（Publishers）に、db の公開が無い" \
  '[.[] | select(.Service == "db") | .Publishers[]? | select(.PublishedPort > 0)] | length == 0' "$ps_json"
db_container="$("$DC" ps -q db 2>/dev/null | head -n 1)"
if [[ -n "$db_container" ]]; then
  published="$(docker port "$db_container" 2>/dev/null | wc -l)"
  expect_eq "補足: docker port の結果が空（db のコンテナはホストへポートを公開していない）" "0" "$published"
else
  fail "補足: db のコンテナが見つからない"
fi
http_get "http://localhost:${DB_PORT}/" --max-time 5
if [[ "$HTTP_CURL_EXIT" -eq 7 || "$HTTP_CURL_EXIT" -eq 28 ]]; then
  pass "補足: localhost:${DB_PORT} へ接続できない"
else
  note "localhost:${DB_PORT} へ接続できた（curl の終了コード ${HTTP_CURL_EXIT}）。ホストの別の PostgreSQL の可能性がある（db コンテナが公開していないことは、上の 2 つで確認済み）"
fi

# --- 後始末 ---
if [[ "$do_stop" -eq 1 ]]; then
  section "後始末: scripts/dc.sh stop"
  if "$DC" stop >/dev/null 2>&1; then pass "stop が成功した"; else fail "stop が失敗した"; fi
fi

finish
