#!/usr/bin/env bash
# PR #43（issue #7 アプリケーション基盤）の、ホストから見た口の確認。ブラウザ（またはホストの curl）が見るものを確かめる。
#
#   1. 公開側の口（BACKEND_PORT。既定 3001）: /up が 200。/api/usage-events（認証なし）が JSON のエラー（403 forbidden）。/internal は 404
#   2. 内部側の口（3101）は、ホストへ公開されていない（外部から到達できない経路でのみ受ける。requirements.md 6.1・11.9）
#   3. フロントエンドの同一オリジン中継（BFF。FRONTEND_PORT。既定 3000）経由で、アプリケーションが、BFF の秘密値・転送ヘッダ
#      （X-Forwarded-Host・X-Forwarded-Proto）・Origin の照合を、期待どおりに処理すること（フロントエンドが起動していなければ SKIP）
#
# 対象は、開発サーバー（ホストの localhost。docker compose が公開した口）。本番へは接続しない。値（秘密値）を扱わない。
# 並行して複数の環境を起動しているときは、BACKEND_PORT を、その環境の公開側の口にする（既定 3001）。
# 使い方: test/pr43/check_host_ports.sh（run_all.sh が呼ぶ）。終了コード: 0 = 成功 / 1 = 失敗
set -uo pipefail

PORT="${BACKEND_PORT:-3001}"
BASE="http://localhost:${PORT}"
failures=0
pass() { printf 'ok   %s\n' "$*"; }
fail() {
  printf 'FAIL %s\n' "$*"
  failures=$((failures + 1))
}

status_of() { curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 20 "$@"; }

echo "-- 1. 公開側の口（${BASE}）"
if [[ "$(status_of "${BASE}/up")" == "200" ]]; then
  pass "GET /up は 200（ヘルスチェック。緑一色の画面のまま）"
else
  fail "GET /up が 200 ではない"
fi

response="$(curl -s -i --connect-timeout 5 --max-time 20 "${BASE}/api/usage-events")"
if [[ "$response" == HTTP/*" 403"* ]]; then
  pass "GET /api/usage-events（認証なし）は 403"
else
  fail "GET /api/usage-events（認証なし）が 403 ではない"
fi
body="$(printf '%s' "$response" | sed -n '/^\r\{0,1\}$/,$p' | tr -d '\r\n')"
if [[ "$body" == '{"error":{"code":"forbidden","details":{}}}' ]]; then
  pass "本文は契約の JSON（{\"error\":{\"code\":\"forbidden\",\"details\":{}}}）。手がかりを書かない"
else
  fail "本文が契約の JSON ではない（${body:0:120}）"
fi
if printf '%s' "$response" | grep -qi '^content-type: application/json; charset=utf-8'; then
  pass "Content-Type は application/json; charset=utf-8（HTML のエラーページではない）"
else
  fail "Content-Type が application/json; charset=utf-8 ではない"
fi
if printf '%s' "$response" | grep -qi '^cache-control: no-store'; then
  pass "Cache-Control: no-store"
else
  fail "Cache-Control: no-store が無い"
fi
if printf '%s' "$response" | grep -qi '^set-cookie:'; then
  fail "Set-Cookie が付いている（セッションの Cookie を出さない）"
else
  pass "Set-Cookie が無い"
fi

if [[ "$(status_of -X POST "${BASE}/internal/v1/verify")" == "404" ]]; then
  pass "POST /internal/v1/verify は 404（内部通信の経路は、公開側の口で応答しない）"
else
  fail "POST /internal/v1/verify が 404 ではない"
fi
if [[ "$(status_of "${BASE}/no-such-page")" == "404" ]]; then
  pass "存在しない経路は 404"
else
  fail "存在しない経路が 404 ではない"
fi
if [[ "$(status_of -H 'Host: evil.example' "${BASE}/api/usage-events")" == "403" ]]; then
  pass "許可されていない Host（evil.example）は 403（DNS rebinding の防止）"
else
  fail "許可されていない Host が 403 ではない"
fi

echo
echo "-- 2. 内部側の口（3101）は、ホストへ公開されていない"
# 公開側の口を 3101 にしている環境では、この確認は意味を持たない
if [[ "$PORT" == "3101" ]]; then
  fail "公開側の口が 3101 になっている（内部側の口と同じ。起動に失敗するはずの設定）"
elif curl -s -o /dev/null --connect-timeout 3 --max-time 5 "http://localhost:3101/up"; then
  fail "ホストの localhost:3101 へ接続できた（内部側の口が、ホストへ公開されている）"
else
  pass "ホストの localhost:3101 へ接続できない（内部側の口は、compose のネットワークの中だけ）"
fi

echo
echo "-- 3. フロントエンドの同一オリジン中継（BFF）経由"
FRONTEND_BASE="http://localhost:${FRONTEND_PORT:-3000}"
if [[ "$(status_of "${FRONTEND_BASE}/healthz")" != "200" ]]; then
  printf 'SKIP フロントエンド（%s）が起動していないため、BFF 経由の確認を省きます\n' "$FRONTEND_BASE"
else
  bff_post() { curl -s -i --connect-timeout 5 --max-time 30 -X POST -H 'Content-Type: application/json' "$@" -d '{"event_type":"watch_url_copied"}' "${FRONTEND_BASE}/api/usage-events"; }
  frontend_origin="http://localhost:${FRONTEND_PORT:-3000}"

  response="$(bff_post -H 'X-BL-Client: web' -H "Origin: ${frontend_origin}")"
  if [[ "$response" == HTTP/*" 401"* && "$response" == *'"code":"not_logged_in"'* ]]; then
    pass "BFF 経由の POST /api/usage-events（ログインなし・Origin が公開オリジンと一致）は 401 not_logged_in（秘密値・転送ヘッダ・Origin の照合を通った）"
  else
    fail "BFF 経由の POST が 401 not_logged_in ではない（$(printf '%s' "$response" | head -1 | tr -d '\r')）"
  fi

  response="$(bff_post -H 'X-BL-Client: web' -H 'Origin: http://evil.example')"
  if [[ "$response" == HTTP/*" 403"* && "$response" == *'"code":"csrf_invalid"'* ]]; then
    pass "BFF 経由で、Origin が公開オリジンと違えば 403 csrf_invalid"
  else
    fail "BFF 経由の POST（Origin 違い）が 403 csrf_invalid ではない"
  fi

  response="$(bff_post)"
  if [[ "$response" == HTTP/*" 403"* && "$response" == *'"code":"csrf_invalid"'* ]]; then
    pass "BFF 経由で、X-BL-Client が無ければ 403 csrf_invalid"
  else
    fail "BFF 経由の POST（X-BL-Client なし）が 403 csrf_invalid ではない"
  fi

  response="$(curl -s -i --connect-timeout 5 --max-time 30 "${FRONTEND_BASE}/api/no-such-endpoint")"
  if [[ "$response" == HTTP/*" 404"* && "$response" == *'"code":"not_found"'* ]]; then
    pass "BFF 経由で、存在しない /api の経路は 404 not_found（アプリケーションの JSON のエラーが、そのまま届く）"
  else
    fail "BFF 経由の存在しない経路が 404 not_found ではない"
  fi
fi

echo
if [[ "$failures" -ne 0 ]]; then
  printf '%d 件失敗しました\n' "$failures"
  exit 1
fi
echo "すべて成功しました"
exit 0
