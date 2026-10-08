#!/usr/bin/env bash
# PR #48（issue #8 認証）の、curl での確認。ホストから、フロントエンドの開発サーバー（http://localhost:3000。同一オリジン中継）を通して、
# バックエンド（疑似の Google の環境）のログインの流れを確かめる。ブラウザと同じく、Cookie は curl の Cookie の入れ物で受け渡す。
#
#   1. ランディングが 200 で、「LOG IN WITH GOOGLE」が出る。?login_error=oauth_failed のとき、ログインの失敗の通知が出る
#   2. POST /api/auth/login/start: X-BL-Client が無ければ 403 csrf_invalid、recaptcha_token が無ければ 422、dev-fail は 403 bot_check_failed、
#      dev-pass は 200 で認可 URL（フロントエンドと同じオリジンの疑似の認可画面）。bl_oauth が HttpOnly・SameSite=Lax・Max-Age=600 で設定される
#   3. 疑似の認可画面（GET）: 固定の 3 アカウントのリンク
#   4. リンクを開く（リダイレクトを追わない）: 302 Location は http://localhost:3000/studio。bl_session が HttpOnly・SameSite=Lax で設定される
#   5. 失敗: error=access_denied は 302 /?login_error=oauth_failed。Cookie が無いコールバックも同じ
#   6. バックエンドのドメインが、ブラウザの受け取る応答（ヘッダ・本文）に出ない
#
# 使い方: test/pr48/curl_bff_check.sh。環境変数: FRONTEND_PORT（既定 3000）
# 終了コード: 0 = 成功 / 1 = 失敗 / 2 = 前提の不備（開発サーバーに届かない）。値（Cookie・コード・state）は、画面へ出さない
set -uo pipefail

FRONT="http://localhost:${FRONTEND_PORT:-3000}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/issue8_curl.XXXXXX")"
JAR="$TMP_DIR/cookies.txt"
failures=0
pass() { printf 'ok   %s\n' "$*"; }
fail() {
  printf 'FAIL %s\n' "$*"
  failures=$((failures + 1))
}
check() { # check <ラベル> <コマンド...>
  local label="$1"
  shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

command -v curl >/dev/null 2>&1 || {
  echo "FAIL curl がありません" >&2
  exit 2
}
command -v python3 >/dev/null 2>&1 || {
  echo "FAIL python3 がありません" >&2
  exit 2
}
curl -sS -o /dev/null --max-time 20 "$FRONT/healthz" || {
  echo "FAIL フロントエンドの開発サーバー（$FRONT）に届きません。scripts/dc.sh up -d --wait を実行してください" >&2
  exit 2
}

# ヘッダのファイルから、状態の行・指定したヘッダの値（小文字で比較）を得る
status_of() { head -1 "$1" | awk '{print $2}'; }
header_of() { grep -i "^$2:" "$1" | head -1 | sed -e "s/^[^:]*:[[:space:]]*//" -e 's/\r$//'; }
set_cookie_of() { grep -i "^set-cookie: $2=" "$1" | head -1 | sed -e 's/\r$//'; }
json_field() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }

echo "-- 1. ランディング"
curl -sS --max-time 60 -D "$TMP_DIR/h1" -o "$TMP_DIR/b1" "$FRONT/"
check "ランディングが 200" test "$(status_of "$TMP_DIR/h1")" = "200"
check "「LOG IN WITH GOOGLE」のボタンが出る" grep -q "LOG IN WITH GOOGLE" "$TMP_DIR/b1"
curl -sS --max-time 60 -o "$TMP_DIR/b1b" "$FRONT/?login_error=oauth_failed"
OAUTH_FAILED_TITLE="$(grep -oE 'oauthFailed: \{ title: "[^"]+"' "$(dirname "$0")/../../src/frontend/messages/landing.ts" | sed -e 's/.*title: "//' -e 's/"$//')"
check "?login_error=oauth_failed のとき、ログインの失敗の通知が出る（文言は文言カタログ）" grep -q "$OAUTH_FAILED_TITLE" "$TMP_DIR/b1b"

echo
echo "-- 2. POST /api/auth/login/start（同一オリジン中継を通る）"
curl -sS --max-time 30 -D "$TMP_DIR/h2a" -o "$TMP_DIR/b2a" -X POST "$FRONT/api/auth/login/start" -H 'Content-Type: application/json' -d '{"recaptcha_token":"dev-pass"}'
check "X-BL-Client が無ければ 403 csrf_invalid" test "$(status_of "$TMP_DIR/h2a")" = "403" -a "$(json_field "$TMP_DIR/b2a" error | grep -c csrf_invalid)" = "1"
curl -sS --max-time 30 -D "$TMP_DIR/h2b" -o "$TMP_DIR/b2b" -X POST "$FRONT/api/auth/login/start" -H 'Content-Type: application/json' -H 'X-BL-Client: web' -d '{}'
check "recaptcha_token が無ければ 422 invalid_input" test "$(status_of "$TMP_DIR/h2b")" = "422" -a "$(grep -c invalid_input "$TMP_DIR/b2b")" = "1"
curl -sS --max-time 30 -D "$TMP_DIR/h2c" -o "$TMP_DIR/b2c" -X POST "$FRONT/api/auth/login/start" -H 'Content-Type: application/json' -H 'X-BL-Client: web' -d '{"recaptcha_token":"dev-fail"}'
check "dev-fail は 403 bot_check_failed。認可 URL も bl_oauth も無い" test "$(status_of "$TMP_DIR/h2c")" = "403" -a "$(grep -c bot_check_failed "$TMP_DIR/b2c")" = "1" -a "$(grep -ci '^set-cookie' "$TMP_DIR/h2c")" = "0"
curl -sS --max-time 30 -D "$TMP_DIR/h2" -o "$TMP_DIR/b2" -c "$JAR" -X POST "$FRONT/api/auth/login/start" -H 'Content-Type: application/json' -H 'X-BL-Client: web' -d '{"recaptcha_token":"dev-pass"}'
AUTH_URL="$(json_field "$TMP_DIR/b2" authorization_url 2>/dev/null || true)"
check "dev-pass は 200。認可 URL は、フロントエンドと同じオリジンの疑似の認可画面" test "$(status_of "$TMP_DIR/h2")" = "200" -a "${AUTH_URL#"$FRONT/api/dev/google/authorize?"}" != "$AUTH_URL"
COOKIE_LINE="$(set_cookie_of "$TMP_DIR/h2" bl_oauth | tr 'A-Z' 'a-z')"
check "bl_oauth: HttpOnly・SameSite=Lax・Path=/・Max-Age=600" test "$(printf '%s' "$COOKIE_LINE" | grep -c 'httponly')" = "1" -a "$(printf '%s' "$COOKIE_LINE" | grep -c 'samesite=lax')" = "1" -a "$(printf '%s' "$COOKIE_LINE" | grep -c 'max-age=600')" = "1" -a "$(printf '%s' "$COOKIE_LINE" | grep -c 'path=/')" = "1"
check "Cache-Control: no-store" test "$(header_of "$TMP_DIR/h2" cache-control)" = "no-store"

echo
echo "-- 3. 疑似の認可画面（ブラウザが認可 URL を開く）"
curl -sS --max-time 30 -D "$TMP_DIR/h3" -o "$TMP_DIR/b3" -b "$JAR" -c "$JAR" "$AUTH_URL"
check "200・text/html" test "$(status_of "$TMP_DIR/h3")" = "200" -a "$(header_of "$TMP_DIR/h3" content-type | grep -c 'text/html')" = "1"
LINKS="$(python3 -I - "$TMP_DIR/b3" <<'PYEOF'
import html.parser
import sys


class Links(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.current = None
        self.links = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self.current = dict(attrs).get("href")

    def handle_data(self, data):
        if self.current is not None and data.strip():
            self.links.append((data.strip(), self.current))
            self.current = None


parser = Links()
parser.feed(open(sys.argv[1], encoding="utf-8").read())
for name, href in parser.links:
    print(f"{name}\t{href}")
PYEOF
)"
check "固定の 3 アカウント（dev-user-1〜dev-user-3）のリンク" test "$(printf '%s\n' "$LINKS" | cut -f1 | tr '\n' ',')" = "dev-user-1,dev-user-2,dev-user-3,"
LINK="$(printf '%s\n' "$LINKS" | awk -F'\t' '$1=="dev-user-1"{print $2}')"

echo
echo "-- 4. アカウントを選ぶ（コールバック。リダイレクトを追わない）"
curl -sS --max-time 30 -D "$TMP_DIR/h4" -o "$TMP_DIR/b4" -b "$JAR" -c "$JAR" "$LINK"
check "302。Location は公開オリジンの /studio" test "$(status_of "$TMP_DIR/h4")" = "302" -a "$(header_of "$TMP_DIR/h4" location)" = "$FRONT/studio"
SESSION_LINE="$(set_cookie_of "$TMP_DIR/h4" bl_session | tr 'A-Z' 'a-z')"
check "bl_session: HttpOnly・SameSite=Lax・Path=/。有効期限の属性なし" test "$(printf '%s' "$SESSION_LINE" | grep -c 'httponly')" = "1" -a "$(printf '%s' "$SESSION_LINE" | grep -c 'samesite=lax')" = "1" -a "$(printf '%s' "$SESSION_LINE" | grep -c -E 'max-age|expires')" = "0"
check "bl_oauth は失効する（空の値と過去の期限）" test "$(set_cookie_of "$TMP_DIR/h4" bl_oauth | tr 'A-Z' 'a-z' | grep -c 'bl_oauth=;')" = "1"
check "Cookie の入れ物に、bl_session があり、bl_oauth は残らない" test "$(grep -c 'bl_session' "$JAR")" = "1" -a "$(grep -c 'bl_oauth' "$JAR")" = "0"

echo
echo "-- 5. 失敗（同じ認可の途中の状態を、もう一度使う / Cookie が無い / 拒否）"
curl -sS --max-time 30 -D "$TMP_DIR/h5a" -o /dev/null "$LINK"
check "Cookie が無いコールバックは 302 /?login_error=oauth_failed" test "$(status_of "$TMP_DIR/h5a")" = "302" -a "$(header_of "$TMP_DIR/h5a" location)" = "$FRONT/?login_error=oauth_failed"
curl -sS --max-time 30 -D "$TMP_DIR/h5b" -o /dev/null "$FRONT/api/auth/callback?error=access_denied"
check "認可の拒否（error=access_denied）は 302 /?login_error=oauth_failed" test "$(status_of "$TMP_DIR/h5b")" = "302" -a "$(header_of "$TMP_DIR/h5b" location)" = "$FRONT/?login_error=oauth_failed"
curl -sS --max-time 30 -D "$TMP_DIR/h5c" -o /dev/null "$FRONT/api/dev/google/authorize?response_type=code&scope=openid%20email&redirect_uri=x&state=a&nonce=b&code_challenge=c&code_challenge_method=S256"
check "不正な認可の要求（scope に email）では、画面を出さない（422）" test "$(status_of "$TMP_DIR/h5c")" = "422"

echo
echo "-- 6. バックエンドのドメイン・内部の名前が、応答に出ない"
LEAK_COUNT="$(cat "$TMP_DIR"/h2 "$TMP_DIR"/b2 "$TMP_DIR"/h3 "$TMP_DIR"/b3 "$TMP_DIR"/h4 "$TMP_DIR"/h5a "$TMP_DIR"/h5b 2>/dev/null | grep -c -i -E 'railway|backend:3001|:3101|x-bff-secret')"
check "応答に、railway・backend:3001・内部の口・X-BFF-Secret が出ない" test "$LEAK_COUNT" = "0"

echo
echo "作業用の一時ファイル（Cookie を含む）: $TMP_DIR（削除しません）"
if [[ "$failures" -ne 0 ]]; then
  printf '%d 件失敗しました\n' "$failures"
  exit 1
fi
echo "すべて成功しました"
exit 0
