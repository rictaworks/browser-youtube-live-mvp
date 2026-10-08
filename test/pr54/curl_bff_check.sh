#!/usr/bin/env bash
# PR 54（issue #11 YouTube 接続）の、curl での確認。ホストから、フロントエンドの開発サーバー（http://localhost:3000。同一オリジン中継）を通して、
# バックエンド（疑似の Google・疑似の YouTube の環境）の YouTube 接続の流れを確かめる。ブラウザと同じく、Cookie は curl の Cookie の入れ物で受け渡す。
#
#   前提  ログインの代わりのセッション（アカウント・セッションの識別子・CSRF トークン）を、backend コンテナで発行する（ログイン自体は test/pr48 が確かめている）。
#         アカウント画面の状態の API（GET /api/state）は issue #12 のため、CSRF トークンは、コンテナのアプリケーションの導出（CsrfToken）で得る
#   1. POST /api/youtube/connect/start: ログインなしは 401、X-BL-Client なしは 403、recaptcha_token なしは 422、dev-fail は 403、dev-pass は 200 で認可 URL
#      （フロントエンドと同じオリジンの疑似の同意画面）。bl_oauth が HttpOnly・SameSite=Lax・Max-Age=600 で設定される
#   2. 疑似の同意画面（GET）: 選択肢 7 つのリンク
#   3. 選択（リダイレクトを追わない）: 302。Location は、公開オリジンのコールバック（code と state つき）
#   4. コールバック（リダイレクトを追わない）: 302。Location は http://localhost:3000/account?connect=connected。bl_oauth が失効する
#   5. 再確認（POST）: 200 と {"youtube":{state, channel_title: null, can_recheck_at}}。直後の 2 回目は 429
#   6. 不成立: 拒否（deny）は connect=scope_denied、権限の部分拒否は connect=scope_denied、更新トークンなしは connect=no_refresh_token、
#      チャンネルなしは connect=no_channel、確認不能は connect=unverifiable。ライブ未有効は connect=live_not_enabled（成立）
#   7. 戻り先の検査: Cookie なし・state の不一致は connect=unverifiable
#   8. バックエンドのドメインが、ブラウザの受け取る応答（ヘッダ・本文）に出ない。アカウント画面（/account?connect=…）が 200 で返る
#
# 使い方: test/pr54/curl_bff_check.sh。環境変数: FRONTEND_PORT（既定 3000）
# 終了コード: 0 = 成功 / 1 = 失敗 / 2 = 前提の不備（開発サーバーに届かない）。値（Cookie・コード・state・CSRF トークン）は、画面へ出さない
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
DC="$ROOT_DIR/scripts/dc.sh"
FRONT="http://localhost:${FRONTEND_PORT:-3000}"
# この実行専用の IP（頻度制限の計数を、ほかの利用者・ほかの実行と混ぜない）。開発のフロントエンドは、入ってきた X-Forwarded-For の先頭を使う
PROBE_IP="203.0.113.$((RANDOM % 200 + 20))"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/issue11_curl.XXXXXX")"
JAR="$TMP_DIR/cookies.txt"
failures=0
pass() { printf 'ok   %s\n' "$*"; }
fail() {
  printf 'FAIL %s\n' "$*"
  failures=$((failures + 1))
}
curl_front() { curl -sS -H "X-Forwarded-For: $PROBE_IP" "$@"; }
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
cd "$ROOT_DIR" || exit 2

status_of() { head -1 "$1" | awk '{print $2}'; }
header_of() { grep -i "^$2:" "$1" | head -1 | sed -e "s/^[^:]*:[[:space:]]*//" -e 's/\r$//'; }
set_cookie_of() { grep -i "^set-cookie: $2=" "$1" | head -1 | sed -e 's/\r$//'; }
json_field() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
json_path() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); [d := d[k] for k in sys.argv[2].split(".")]; print("null" if d is None else d)' "$1" "$2"; }
# Cookie の入れ物から、名前の値を得る（無ければ空）
cookie_in_jar() { awk -v name="$1" '$6==name{print $7}' "$JAR"; }

# 同意画面のリンク（ラベル -> href）を、「ラベル<TAB>href」の行で出す
links_of() {
  python3 -I - "$1" <<'PYEOF'
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
}

echo "-- 前提: ログインの代わりのセッションを、backend コンテナで発行する（アカウント dummy-curl-check-*）"
SESSION_LINE="$("$DC" exec -T backend bin/rails runner - 2>/dev/null <<'RUBY'
user = User.create!(google_sub: "dummy-curl-check-#{SecureRandom.hex(4)}", last_login_at: Time.current)
issued = SessionStore.new.issue(user: user, now: Time.current)
puts [ issued.token, CsrfToken.new(secret: Rails.application.secret_key_base).derive(issued.token) ].join(" ")
RUBY
)"
SESSION_TOKEN="${SESSION_LINE%% *}"
CSRF_TOKEN="${SESSION_LINE##* }"
if [[ -z "$SESSION_TOKEN" || -z "$CSRF_TOKEN" || "$SESSION_TOKEN" == "$CSRF_TOKEN" ]]; then
  echo "FAIL セッションを発行できません（backend コンテナを確認してください）" >&2
  exit 2
fi
printf 'localhost\tFALSE\t/\tFALSE\t0\tbl_session\t%s\n' "$SESSION_TOKEN" >"$JAR"
pass "セッションを発行した（値は表示しない）"

# 状態を変える API の呼び出し（ブラウザが付けるヘッダ）。引数: ヘッダのファイル 本文のファイル パス 本文 [追加の curl 引数...]
post_api() {
  local header_file="$1" body_file="$2" path="$3" body="$4"
  shift 4
  curl_front --max-time 30 -D "$header_file" -o "$body_file" -b "$JAR" -c "$JAR" -X POST "$FRONT$path" \
    -H 'Content-Type: application/json' -H 'X-BL-Client: web' -H "X-CSRF-Token: $CSRF_TOKEN" -H "Origin: $FRONT" "$@" -d "$body"
}

# 認可の開始から、選択肢を選ぶところまで。引数: 選択肢の名前 作業の名前。戻り先の URL を CALLBACK_URL に置く
begin_flow() {
  local scenario="$1" name="$2"
  post_api "$TMP_DIR/$name.start.h" "$TMP_DIR/$name.start.json" /api/youtube/connect/start '{"recaptcha_token":"dev-pass"}'
  local authorization_url
  authorization_url="$(json_field "$TMP_DIR/$name.start.json" authorization_url 2>/dev/null || true)"
  curl_front --max-time 30 -D "$TMP_DIR/$name.consent.h" -o "$TMP_DIR/$name.consent.html" -b "$JAR" -c "$JAR" "$authorization_url"
  local href
  href="$(links_of "$TMP_DIR/$name.consent.html" | awk -F'\t' -v scenario="$scenario" '$1==scenario{print $2}')"
  curl_front --max-time 30 -D "$TMP_DIR/$name.choose.h" -o /dev/null -b "$JAR" -c "$JAR" "$FRONT$href"
  CALLBACK_URL="$(header_of "$TMP_DIR/$name.choose.h" location)"
}

echo
echo "-- 1. POST /api/youtube/connect/start（同一オリジン中継を通る）"
curl_front --max-time 30 -D "$TMP_DIR/h1a" -o "$TMP_DIR/b1a" -X POST "$FRONT/api/youtube/connect/start" -H 'Content-Type: application/json' -H 'X-BL-Client: web' -d '{"recaptcha_token":"dev-pass"}'
check "ログインしていなければ 401 not_logged_in" test "$(status_of "$TMP_DIR/h1a")" = "401" -a "$(grep -c not_logged_in "$TMP_DIR/b1a")" = "1"
curl_front --max-time 30 -D "$TMP_DIR/h1b" -o "$TMP_DIR/b1b" -b "$JAR" -X POST "$FRONT/api/youtube/connect/start" -H 'Content-Type: application/json' -H "Origin: $FRONT" -H "X-CSRF-Token: $CSRF_TOKEN" -d '{"recaptcha_token":"dev-pass"}'
check "X-BL-Client が無ければ 403 csrf_invalid" test "$(status_of "$TMP_DIR/h1b")" = "403" -a "$(grep -c csrf_invalid "$TMP_DIR/b1b")" = "1"
post_api "$TMP_DIR/h1c" "$TMP_DIR/b1c" /api/youtube/connect/start '{}'
check "recaptcha_token が無ければ 422 invalid_input" test "$(status_of "$TMP_DIR/h1c")" = "422" -a "$(grep -c invalid_input "$TMP_DIR/b1c")" = "1"
post_api "$TMP_DIR/h1d" "$TMP_DIR/b1d" /api/youtube/connect/start '{"recaptcha_token":"dev-fail"}'
check "dev-fail は 403 bot_check_failed。認可 URL も bl_oauth も無い" test "$(status_of "$TMP_DIR/h1d")" = "403" -a "$(grep -c bot_check_failed "$TMP_DIR/b1d")" = "1" -a "$(grep -ci '^set-cookie' "$TMP_DIR/h1d")" = "0"
post_api "$TMP_DIR/h1" "$TMP_DIR/b1" /api/youtube/connect/start '{"recaptcha_token":"dev-pass"}'
AUTH_URL="$(json_field "$TMP_DIR/b1" authorization_url 2>/dev/null || true)"
check "dev-pass は 200。認可 URL は、フロントエンドと同じオリジンの疑似の同意画面" test "$(status_of "$TMP_DIR/h1")" = "200" -a "${AUTH_URL#"$FRONT/api/dev/google/connect?"}" != "$AUTH_URL"
check "認可 URL: スコープは youtube の 1 種・offline・consent・S256。include_granted_scopes・nonce は無い" python3 -I -c '
import sys, urllib.parse
q = urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query)
ok = q["scope"] == ["https://www.googleapis.com/auth/youtube"] and q["access_type"] == ["offline"] and q["prompt"] == ["consent"] and q["code_challenge_method"] == ["S256"]
ok = ok and "include_granted_scopes" not in q and "nonce" not in q and q["redirect_uri"] == [sys.argv[2] + "/api/youtube/connect/callback"]
sys.exit(0 if ok else 1)' "$AUTH_URL" "$FRONT"
COOKIE_LINE="$(set_cookie_of "$TMP_DIR/h1" bl_oauth | tr 'A-Z' 'a-z')"
check "bl_oauth: HttpOnly・SameSite=Lax・Path=/・Max-Age=600" test "$(printf '%s' "$COOKIE_LINE" | grep -c 'httponly')" = "1" -a "$(printf '%s' "$COOKIE_LINE" | grep -c 'samesite=lax')" = "1" -a "$(printf '%s' "$COOKIE_LINE" | grep -c 'max-age=600')" = "1" -a "$(printf '%s' "$COOKIE_LINE" | grep -c 'path=/')" = "1"
check "Cache-Control: no-store" test "$(header_of "$TMP_DIR/h1" cache-control)" = "no-store"

echo
echo "-- 2. 疑似の同意画面（ブラウザが認可 URL を開く）"
curl_front --max-time 30 -D "$TMP_DIR/h2" -o "$TMP_DIR/b2" -b "$JAR" -c "$JAR" "$AUTH_URL"
check "200・text/html" test "$(status_of "$TMP_DIR/h2")" = "200" -a "$(header_of "$TMP_DIR/h2" content-type | grep -c 'text/html')" = "1"
check "選択肢 7 つ（allow・allow_live_not_enabled・allow_no_channel・allow_unverifiable・allow_without_youtube・allow_without_refresh_token・deny）" \
  test "$(links_of "$TMP_DIR/b2" | cut -f1 | tr '\n' ',')" = "allow,allow_live_not_enabled,allow_no_channel,allow_unverifiable,allow_without_youtube,allow_without_refresh_token,deny,"
ALLOW_HREF="$(links_of "$TMP_DIR/b2" | awk -F'\t' '$1=="allow"{print $2}')"

echo
echo "-- 3. 選択（リダイレクトを追わない）"
curl_front --max-time 30 -D "$TMP_DIR/h3" -o /dev/null -b "$JAR" -c "$JAR" "$FRONT$ALLOW_HREF"
CALLBACK_URL="$(header_of "$TMP_DIR/h3" location)"
check "302。Location は公開オリジンのコールバック（code と state つき）" test "$(status_of "$TMP_DIR/h3")" = "302" -a "${CALLBACK_URL#"$FRONT/api/youtube/connect/callback?"}" != "$CALLBACK_URL"
check "bl_oauth は、まだ Cookie の入れ物にある" test "$(cookie_in_jar bl_oauth | wc -c)" -gt 1

echo
echo "-- 4. コールバック（リダイレクトを追わない）"
curl_front --max-time 30 -D "$TMP_DIR/h4" -o "$TMP_DIR/b4" -b "$JAR" -c "$JAR" "$CALLBACK_URL"
check "302。Location は $FRONT/account?connect=connected（公開オリジンの絶対 URL）" test "$(status_of "$TMP_DIR/h4")" = "302" -a "$(header_of "$TMP_DIR/h4" location)" = "$FRONT/account?connect=connected"
check "bl_oauth は失効する（空の値と過去の期限）。Cookie の入れ物から、bl_oauth が無くなる。bl_session は残る" \
  test "$(set_cookie_of "$TMP_DIR/h4" bl_oauth | tr 'A-Z' 'a-z' | grep -c 'bl_oauth=;')" = "1" -a "$(cookie_in_jar bl_oauth | wc -c)" -le 1 -a "$(cookie_in_jar bl_session | wc -c)" -gt 1
check "応答の本文は空。Cache-Control: no-store" test "$(wc -c <"$TMP_DIR/b4")" = "0" -a "$(header_of "$TMP_DIR/h4" cache-control)" = "no-store"
curl_front --max-time 60 -D "$TMP_DIR/h4b" -o "$TMP_DIR/b4b" -b "$JAR" "$(header_of "$TMP_DIR/h4" location)"
check "戻り先のアカウント画面（/account?connect=connected）が 200 で返る" test "$(status_of "$TMP_DIR/h4b")" = "200"

echo
echo "-- 5. 再確認（POST /api/youtube/recheck）"
post_api "$TMP_DIR/h5" "$TMP_DIR/b5" /api/youtube/recheck ''
check "200。state は connected・channel_title は null" test "$(status_of "$TMP_DIR/h5")" = "200" -a "$(json_path "$TMP_DIR/b5" youtube.state)" = "connected" -a "$(json_path "$TMP_DIR/b5" youtube.channel_title)" = "null"
check "can_recheck_at は、JST（+09:00）の ISO 8601" test "$(json_path "$TMP_DIR/b5" youtube.can_recheck_at | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+09:00$')" = "1"
post_api "$TMP_DIR/h5b" "$TMP_DIR/b5b" /api/youtube/recheck ''
check "直後の 2 回目は 429 rate_limited（retry_at つき）" test "$(status_of "$TMP_DIR/h5b")" = "429" -a "$(grep -c rate_limited "$TMP_DIR/b5b")" = "1" -a "$(grep -c retry_at "$TMP_DIR/b5b")" = "1"

echo
echo "-- 6. 不成立と、ライブ未有効の成立（選択肢ごと。コールバックの Location）"
# 選択肢 -> 期待する connect の値
for pair in "deny:scope_denied" "allow_without_youtube:scope_denied" "allow_without_refresh_token:no_refresh_token" "allow_no_channel:no_channel" "allow_unverifiable:unverifiable" "allow_live_not_enabled:live_not_enabled"; do
  scenario="${pair%%:*}"
  expected="${pair##*:}"
  begin_flow "$scenario" "flow_$scenario"
  curl_front --max-time 30 -D "$TMP_DIR/cb_$scenario.h" -o /dev/null -b "$JAR" -c "$JAR" "$CALLBACK_URL"
  check "$scenario -> 302 $FRONT/account?connect=$expected" test "$(status_of "$TMP_DIR/cb_$scenario.h")" = "302" -a "$(header_of "$TMP_DIR/cb_$scenario.h" location)" = "$FRONT/account?connect=$expected"
done

echo
echo "-- 7. 戻り先の検査（Cookie なし・state の不一致）"
begin_flow allow flow_abuse
curl_front --max-time 30 -D "$TMP_DIR/h7a" -o /dev/null "$CALLBACK_URL"
check "Cookie が無いコールバックは 302 connect=unverifiable" test "$(status_of "$TMP_DIR/h7a")" = "302" -a "$(header_of "$TMP_DIR/h7a" location)" = "$FRONT/account?connect=unverifiable"
curl_front --max-time 30 -D "$TMP_DIR/h7b" -o /dev/null -b "$JAR" -c "$JAR" "$(printf '%s' "$CALLBACK_URL" | sed -E 's/state=[^&]+/state=dummy-other-state/')"
check "state の不一致は 302 connect=unverifiable" test "$(status_of "$TMP_DIR/h7b")" = "302" -a "$(header_of "$TMP_DIR/h7b" location)" = "$FRONT/account?connect=unverifiable"
curl_front --max-time 30 -D "$TMP_DIR/h7c" -o /dev/null "$FRONT/api/youtube/connect/callback?error=access_denied"
check "Cookie も state も無い error=access_denied は 302 connect=unverifiable（state を信用しない）" test "$(status_of "$TMP_DIR/h7c")" = "302" -a "$(header_of "$TMP_DIR/h7c" location)" = "$FRONT/account?connect=unverifiable"

echo
echo "-- 8. バックエンドのドメイン・内部の名前が、応答に出ない"
LEAK_COUNT="$(cat "$TMP_DIR"/*.h "$TMP_DIR"/b1 "$TMP_DIR"/b2 "$TMP_DIR"/b5 2>/dev/null | grep -c -i -E 'railway|backend:3001|:3101|x-bff-secret')"
check "応答に、railway・backend:3001・内部の口・X-BFF-Secret が出ない" test "$LEAK_COUNT" = "0"

echo
echo "作業用の一時ファイル（Cookie を含む）: $TMP_DIR（削除しません）"
if [[ "$failures" -ne 0 ]]; then
  printf '%d 件失敗しました\n' "$failures"
  exit 1
fi
echo "すべて成功しました"
exit 0
