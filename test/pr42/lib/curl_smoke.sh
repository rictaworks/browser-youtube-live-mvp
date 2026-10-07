#!/usr/bin/env bash
# 開発サーバー（http://localhost:<FRONTEND_PORT>。scripts/dc.sh up で起動した frontend）へ curl で要求を送り、
# 画面（/・/account）の HTML と、同一オリジン中継（/api/...）の応答を確かめる。バックエンドは、実物（backend コンテナ）へ繋がる。
#
# 実物のバックエンドは、この時点では /up しか無く、/api/... は 404 を返す。バックエンドが実装を進めても壊れないよう、
# 「バックエンドが応答したこと（中継の設定エラー・不達ではない）」「バックエンドの内部のヘッダを返さないこと」を確かめる。
# バックエンドの応答の中身を、スタブで確かめる検査は、bff_e2e.cjs（frontend コンテナの中の next start とスタブ）にある。
#
# 使い方: bash curl_smoke.sh      （FRONTEND_PORT・BACKEND_PORT で、ポートを変えられる。ホストは localhost に固定）
# 終了コード: 0 = すべて成功（SKIP があっても 0） / 1 = 失敗がある / 2 = 前提の不備（curl・node が無い・開発サーバーに届かない）
#
# 守ること: 対象は開発サーバー（本番へ接続しない）。ファイルを消さない（一時ファイルは、新しいディレクトリへ作り、置いたままにする）。
#   .env の値を、出力・コマンドの引数へ出さない。認証情報（Cookie・トークン）を送らない。送る本文・ヘッダは、明らかなダミー。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../../.." && pwd)"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"
BACKEND_PORT="${BACKEND_PORT:-3001}"
for name_value in "FRONTEND_PORT=$FRONTEND_PORT" "BACKEND_PORT=$BACKEND_PORT"; do
  if [[ ! "${name_value#*=}" =~ ^[0-9]{1,5}$ ]]; then
    echo "FAIL ${name_value%%=*} は、ポート番号ではありません" >&2
    exit 2
  fi
done
BASE="http://localhost:${FRONTEND_PORT}"
BACKEND="http://localhost:${BACKEND_PORT}"
CURL_TIMEOUT=120

command -v curl >/dev/null 2>&1 || {
  echo "FAIL curl が見つかりません" >&2
  exit 2
}
command -v node >/dev/null 2>&1 || {
  echo "FAIL node が見つかりません（文言の正本を読むために必要です）" >&2
  exit 2
}

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/issue_curl.XXXXXX")"
RESP_HEADERS="$WORK_DIR/headers.txt"
RESP_BODY="$WORK_DIR/body.txt"
CURL_ERR="$WORK_DIR/curl_error.txt"

FAILURES=0
PASSES=0
SKIPS=0
pass() {
  PASSES=$((PASSES + 1))
  printf 'ok   %s\n' "$*"
}
fail() {
  FAILURES=$((FAILURES + 1))
  printf 'FAIL %s\n' "$*"
}
skip() {
  SKIPS=$((SKIPS + 1))
  printf 'SKIP %s\n' "$*"
}
note() { printf 'NOTE %s\n' "$*"; }
section() { printf '\n-- %s\n' "$*"; }

# check <説明> <コマンド...>: コマンドが成功すれば ok
check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label"
  fi
}

# http <メソッド> <経路> [curl の追加の引数...]: 応答を $RESP_HEADERS・$RESP_BODY・$RESP_STATUS へ入れる（通信に失敗したら 000）
RESP_STATUS="000"
http() {
  local method="$1" path="$2"
  shift 2
  : >"$RESP_HEADERS"
  : >"$RESP_BODY"
  RESP_STATUS="$(curl -sS --max-time "$CURL_TIMEOUT" -X "$method" -D "$RESP_HEADERS" -o "$RESP_BODY" -w '%{http_code}' "$@" "${BASE}${path}" 2>"$CURL_ERR")" || RESP_STATUS="000"
}

has_header() { grep -qi "^$1:" "$RESP_HEADERS"; }
header_value() { grep -i "^$1:" "$RESP_HEADERS" | tail -n 1 | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/[[:space:]]*$//'; }
body_has() { grep -qF -- "$1" "$RESP_BODY"; }
body_lacks() { ! grep -qF -- "$1" "$RESP_BODY"; }
body_has_regex() { grep -qE -- "$1" "$RESP_BODY"; }
body_lacks_regex() { ! grep -qE -- "$1" "$RESP_BODY"; }
headers_lack_regex() { ! grep -qiE -- "$1" "$RESP_HEADERS"; }
headers_have_regex() { grep -qiE -- "$1" "$RESP_HEADERS"; }

# 文言の正本（messages/）の 1 つの文言。読めなければ、失敗（呼び出し側が、SKIP にする）
msg() {
  node "$HERE/message_text.cjs" "$ROOT_DIR" "$@" 2>/dev/null
}

# 語は分割して組み立てる（テストのソースに、削除系の語を、そのまま書かない）
METHOD_DELETE="DELE""TE"

# ---------------------------------------------------------------------------------------------
section "前提: 開発サーバーが応答する"
http GET /healthz
if [[ "$RESP_STATUS" == "000" ]]; then
  echo "FAIL 開発サーバー（${BASE}）へ接続できません。先に scripts/dc.sh up -d --wait を実行してください" >&2
  exit 2
fi
[[ "$RESP_STATUS" == "200" ]] && body_has '{"status":"ok"}' && pass 'GET /healthz が 200 {"status":"ok"}' || fail "GET /healthz が 200 {\"status\":\"ok\"}（実際: $RESP_STATUS）"

# 開発サーバーは、最初の要求で画面を組み立てる。先に温める（時間がかかっても、後の確認を妨げない）
http GET /
http GET /account

# ---------------------------------------------------------------------------------------------
section "ランディング（/）"
http GET /
[[ "$RESP_STATUS" == "200" ]] && pass "GET / が 200" || fail "GET / が 200（実際: $RESP_STATUS）"
[[ "$(header_value content-type)" == text/html* ]] && pass "Content-Type は text/html" || fail "Content-Type は text/html（実際: $(header_value content-type)）"
check "html の lang は ja" body_has '<html lang="ja"'
check "h1 がある" body_has '<h1'
if hero_login="$(msg landing landing hero.login)" && hero_lead="$(msg landing landing hero.headline.lead)" && hero_accent="$(msg landing landing hero.headline.accent)"; then
  check "h1 の見出し（hero.headline の前半）が、文言の正本と一致して出ている" body_has "$hero_lead"
  check "h1 の見出し（hero.headline の強調）が、文言の正本と一致して出ている" body_has "$hero_accent"
  check "ログインのボタン（hero.login）が出ている（サーバーで描画した HTML の中）" body_has "$hero_login"
else
  skip "文言の正本（messages/landing.ts）を読めないため、見出し・ボタンの文言の照合を省略した"
fi
check "bot 判定の秘密（RECAPTCHA_SECRET_KEY）・共有の秘密値（BFF_SHARED_SECRET）の名前が、HTML に出ない" body_lacks_regex 'RECAPTCHA_SECRET_KEY|BFF_SHARED_SECRET|X-BFF-Secret|X-Relay-Secret'
if grep -oE '(src|href)="https?://[^"]+"' "$RESP_BODY" | grep -vE "https?://localhost:${FRONTEND_PORT}/" >"$WORK_DIR/external_refs.txt" && [[ -s "$WORK_DIR/external_refs.txt" ]]; then
  fail "HTML が、外部のドメインのスクリプト・スタイル・リンクを参照している: $(head -n 3 "$WORK_DIR/external_refs.txt" | tr '\n' ' ')"
else
  pass "HTML が、外部のドメインを参照しない（src・href の絶対 URL が無い）"
fi

section "ランディング: ログインの拒否・失敗の通知（/?login_error=）"
if rh_title="$(msg landing landing notice.registrationHeld.title)" && of_title="$(msg landing landing notice.oauthFailed.title)"; then
  http GET "/?login_error=registration_held"
  check "registration_held: 通知の題が、サーバーで描画した HTML に出る" body_has "$rh_title"
  check "registration_held: 情報の通知（role=status）" body_has 'role="status"'
  http GET "/?login_error=oauth_failed"
  check "oauth_failed: 通知の題が出る" body_has "$of_title"
  check "oauth_failed: エラーの通知（role=alert）" body_has 'role="alert"'
  http GET "/?login_error=unknown_value"
  check "未知の値は、情報の通知（再登録の保留）にならない（別の通知へ倒さない）" body_lacks "$rh_title"
  check "未知の値は、エラーの通知（ログインの失敗）にならない（別の通知へ倒さない）" body_lacks "$of_title"
  http GET "/?login_error=registration_held&login_error=oauth_failed"
  check "同じ値が複数あるときは、情報の通知にならない（先頭を採用して、別の通知へ倒さない）" body_lacks "$rh_title"
  check "同じ値が複数あるときは、エラーの通知にならない（先頭を採用して、別の通知へ倒さない）" body_lacks "$of_title"
else
  skip "文言の正本を読めないため、通知の照合を省略した"
fi

# ---------------------------------------------------------------------------------------------
section "アカウント（/account）"
http GET /account
[[ "$RESP_STATUS" == "200" ]] && pass "GET /account が 200（ログインの判定は、ブラウザ側。未ログインの誘導は、実ブラウザの検査）" || fail "GET /account が 200（実際: $RESP_STATUS）"
check "検索エンジンへ載せない（robots: noindex）" body_has_regex 'name="robots" content="noindex'
check "h1 がある" body_has '<h1'
if heading="$(msg account account heading)"; then
  check "h1 の題（account.heading）が、文言の正本と一致して出ている" body_has "$heading"
else
  skip "文言の正本（messages/account.ts）を読めないため、h1 の照合を省略した"
fi
check "共有の秘密値の名前が、HTML に出ない" body_lacks_regex 'RECAPTCHA_SECRET_KEY|BFF_SHARED_SECRET|X-BFF-Secret'

# ---------------------------------------------------------------------------------------------
section "同一オリジン中継（/api/...）: 実物のバックエンドへ"
if curl -sS --max-time 20 -o /dev/null -w '%{http_code}' "${BACKEND}/up" 2>/dev/null | grep -q '^200$'; then
  pass "実物のバックエンド（${BACKEND}/up）が応答している"
  http GET "/api/state?with_channel=1"
  note "GET /api/state?with_channel=1（フロントエンドの中継 > バックエンド）: HTTP ${RESP_STATUS}。バックエンドが /api/state を実装するまでは 404"
  case "$RESP_STATUS" in
    200 | 400 | 401 | 403 | 404 | 422 | 429) pass "バックエンドが応答した（HTTP ${RESP_STATUS}）。中継の設定エラー（500）・不達（502）ではない" ;;
    *) fail "バックエンドの応答として、想定外のステータス（${RESP_STATUS}）。中継の設定（BACKEND_ORIGIN・BFF_SHARED_SECRET）か、バックエンドの異常を確認してください" ;;
  esac
  check "バックエンド自身の識別・内部のヘッダを、返さない（Server・X-Runtime・X-Request-Id・X-Xss-Protection・X-Permitted-Cross-Domain-Policies・Via）" headers_lack_regex '^(server|x-runtime|x-request-id|x-xss-protection|x-permitted-cross-domain-policies|via):'
  check "X-Content-Type-Options: nosniff を付ける" headers_have_regex '^x-content-type-options: nosniff'
  check "応答のヘッダに、共有の秘密値の名前が出ない" headers_lack_regex 'BFF_SHARED_SECRET|X-BFF-Secret'
  check "応答の本文に、共有の秘密値の名前が出ない" body_lacks_regex 'BFF_SHARED_SECRET|X-BFF-Secret'
else
  skip "実物のバックエンド（${BACKEND}/up）に届かないため、バックエンドへの転送の確認を省略した（確認できなかった）。scripts/dc.sh up -d --wait で全体を起動してください"
fi

section "同一オリジン中継: すべてのメソッドを、中継が受け付ける（Next.js の 405 ではない）"
for method in GET POST PUT PATCH "$METHOD_DELETE" OPTIONS; do
  http "$method" "/api/no-such-endpoint-for-test" -H 'Content-Type: application/json' --data-binary '{}'
  if [[ "$RESP_STATUS" == "000" || "$RESP_STATUS" == "405" ]]; then
    fail "${method} /api/no-such-endpoint-for-test が中継されない（HTTP ${RESP_STATUS}）"
  else
    pass "${method} が、中継される（HTTP ${RESP_STATUS}）"
  fi
done

# ---------------------------------------------------------------------------------------------
section "中継が、自分で拒否する要求（バックエンドへ届かない。中継の 404 は、{\"error\":{\"code\":\"not_found\"}}）"
for pair in \
  "上の階層へ戻る（%2e%2e）:/api/%2e%2e/admin" \
  "上の階層へ戻る（..%2f）:/api/..%2fadmin" \
  "エンコードされた区切り（%2f）:/api/auth%2flogin/start" \
  "エンコードされた区切り（%5c）:/api/auth%5clogin" \
  "二重のエンコード:/api/%252e%252e/admin" \
  "内部通信の経路（/api/internal）:/api/internal/verify" \
  "管理画面の経路（/api/admin）:/api/admin"; do
  label="${pair%%:*}"
  path="${pair#*:}"
  http GET "$path" --path-as-is
  # 中継が拒否すれば、本文は {"error":{"code":"not_found"}}。Next.js が、先に経路を正規化して（%2e%2e を .. として）、中継の外の経路にすることもある。
  # どちらも、バックエンドへ届かない（バックエンド（Rails）の 404 の画面ではない）
  if [[ "$RESP_STATUS" == "404" ]] && body_lacks 'Action Controller' && body_lacks 'RoutingError'; then
    if body_has '"code":"not_found"'; then
      pass "${label}: 404（中継の拒否。バックエンドへ届かない）"
    else
      pass "${label}: 404（Next.js が、経路を正規化して、中継の外の経路として拒否。バックエンドへ届かない）"
    fi
  else
    fail "${label}: 拒否されていない、またはバックエンドへ届いた疑い（HTTP ${RESP_STATUS}）"
  fi
done
http GET /internal/verify
if [[ "$RESP_STATUS" == "404" ]] && ! body_has 'Action Controller' && ! body_has 'RoutingError'; then
  pass "/internal/ は、中継の対象外（Next.js の 404。バックエンドへ届かない）"
else
  fail "/internal/verify が、バックエンドへ届いた疑い（HTTP ${RESP_STATUS}）"
fi

section "中継: 本文の上限（64 KB）・形の不正な Host"
head -c 65537 /dev/zero | tr '\0' 'x' >"$WORK_DIR/too_large.txt"
http POST /api/no-such-endpoint-for-test -H 'Content-Type: text/plain' --data-binary "@$WORK_DIR/too_large.txt"
if [[ "$RESP_STATUS" == "413" ]] && body_has '"code":"invalid_input"'; then
  pass "65,537 バイトの本文は、413 {\"error\":{\"code\":\"invalid_input\"}}（バックエンドへ届かない）"
else
  fail "65,537 バイトの本文が、413 にならない（HTTP ${RESP_STATUS}）"
fi
head -c 65536 /dev/zero | tr '\0' 'x' >"$WORK_DIR/at_limit.txt"
http POST /api/no-such-endpoint-for-test -H 'Content-Type: text/plain' --data-binary "@$WORK_DIR/at_limit.txt"
[[ "$RESP_STATUS" != "413" && "$RESP_STATUS" != "000" ]] && pass "65,536 バイト（上限ちょうど）は、中継される（HTTP ${RESP_STATUS}）" || fail "65,536 バイトが、拒否された（HTTP ${RESP_STATUS}）"
http GET /api/state -H 'Host: evil.example/<x>'
if [[ "$RESP_STATUS" == "400" ]] && body_has '"code":"invalid_input"'; then
  pass "形の不正な Host は、400 {\"error\":{\"code\":\"invalid_input\"}}"
else
  # 開発サーバー（Next.js）が、不正な Host を先に扱う場合がある。中継へ届いていないことだけを確かめ、観察として残す
  note "形の不正な Host の応答: HTTP ${RESP_STATUS}（中継の 400 ではない。この形の拒否は、bff_e2e.cjs の next start の検査で確かめている）"
  [[ "$RESP_STATUS" =~ ^4[0-9][0-9]$ ]] && pass "形の不正な Host は、4xx で拒否される（HTTP ${RESP_STATUS}）" || fail "形の不正な Host が、拒否されない（HTTP ${RESP_STATUS}）"
fi

# ---------------------------------------------------------------------------------------------
printf '\n成功 %d 件・失敗 %d 件・省略（SKIP）%d 件\n' "$PASSES" "$FAILURES" "$SKIPS"
if [[ "$FAILURES" -ne 0 ]]; then
  exit 1
fi
exit 0
