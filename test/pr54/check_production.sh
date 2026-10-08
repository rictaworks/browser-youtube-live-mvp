#!/usr/bin/env bash
# PR 54（issue #11 YouTube 接続）の、本番（RAILS_ENV=production）の起動の検査。対象は開発サーバーの backend コンテナ
# （scripts/dc.sh exec）。本番へは接続しない（コンテナの中で、本番の設定で Rails を起動するだけ。DB・外部サービスへは接続しない）。
#
#   1. 資格情報がそろっていれば、本番として起動し、本番の構成を、production_check.rb が確かめる
#      （YouTube 接続の手続きが実物で組み立つ・疑似は構築できない・実物の認可 URL・疑似の同意画面の経路が無く 404・接続の経路はある・ログインの方針 ほか）
#   2. 開発では、疑似が選ばれて起動する（YouTubeConnectService.current の部品は、環境の判定で、疑似）。疑似の同意画面の経路が 2 つある
#
# 値は、明らかなダミー。秘密値（コンテナの環境変数）は、画面へ出さない。
# 使い方: test/pr54/check_production.sh（run_all.sh が呼ぶ）。終了コード: 0 = 成功 / 1 = 失敗
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
DC="$ROOT_DIR/scripts/dc.sh"
cd "$ROOT_DIR" || exit 1

failures=0
pass() { printf 'ok   %s\n' "$*"; }
fail() {
  printf 'FAIL %s\n' "$*"
  failures=$((failures + 1))
}

echo "-- 1. 資格情報がそろっていれば、本番として起動し、本番の構成が正しい（production_check.rb）"
# BFF の要求を作るため、BFF_SHARED_SECRET などは、コンテナの環境変数（compose が .env から与える値）を使う。実物の資格情報（開発のコンテナでは空）には、ダミー値を与える。
# TOKEN_ENCRYPTION_KEY は、形式が正しいダミー値（起動時の形式の検査を通る）
if "$DC" exec -T -e GOOGLE_CLIENT_ID=dummy-google-client-id -e GOOGLE_CLIENT_SECRET=dummy-google-client-secret \
  -e RECAPTCHA_SECRET_KEY=dummy-recaptcha-secret-key \
  -e TOKEN_ENCRYPTION_KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  -e RAILS_ENV=production -e RAILS_LOG_LEVEL=fatal \
  backend bin/rails runner - <"$HERE/production_check.rb"; then
  pass "本番の構成の確認（production_check.rb）がすべて成功した"
else
  fail "本番の構成の確認（production_check.rb）に失敗した項目がある"
fi

echo
echo "-- 2. 開発では、資格情報が空でも起動し、疑似が選ばれる（環境の判定）"
output="$("$DC" exec -T -e GOOGLE_CLIENT_ID= -e GOOGLE_CLIENT_SECRET= -e RECAPTCHA_SECRET_KEY= backend bin/rails runner '
service = YouTubeConnectService.current
oidc = service.instance_variable_get(:@oidc)
gateway = service.instance_variable_get(:@youtube)
routes = Rails.application.routes.routes.count { |r| r.defaults[:controller] == "dev/google_connect" }
puts "dev-parts=#{oidc.class.name},#{gateway.class.name} env=#{Rails.env} consent_routes=#{routes}"
' 2>&1 </dev/null)"
if [[ "$output" == *"dev-parts=FakeGoogleOidc,FakeYouTubeGateway env=development consent_routes=2"* ]]; then
  pass "開発（資格情報が空）: 疑似の Google・疑似の YouTube の窓口が選ばれ、疑似の同意画面の経路が 2 つある"
else
  fail "開発で、疑似が選ばれていない（出力: $(printf '%s' "$output" | head -c 300)）"
fi

echo
if [[ "$failures" -ne 0 ]]; then
  printf '%d 件失敗しました\n' "$failures"
  exit 1
fi
echo "すべて成功しました"
exit 0
