#!/usr/bin/env bash
# PR #48（issue #8 認証）の、本番（RAILS_ENV=production）の起動の検査。対象は開発サーバーの backend コンテナ
# （scripts/dc.sh exec）。本番へは接続しない（コンテナの中で、本番の設定で Rails を起動するだけ。DB・外部サービスへは接続しない）。
#
#   1. 実物の資格情報（GOOGLE_CLIENT_ID・GOOGLE_CLIENT_SECRET・RECAPTCHA_SECRET_KEY）が欠けていれば、本番は起動に失敗し、
#      欠けている名前だけを書く（値は書かない）。疑似へ倒れて起動することはない
#   2. 資格情報がそろっていれば起動し、本番の構成を、production_check.rb が確かめる
#      （実物が選ばれる・疑似は構築できない・疑似の経路が無く 404・コールバックの Location は公開オリジン・Secure の Cookie ほか）
#   3. 開発（資格情報が空）では、疑似が選ばれて起動する（ExternalServices の選択は、環境の判定）
#
# 値は、明らかなダミー。秘密値（コンテナの環境変数）は、画面へ出さない。
# 使い方: test/pr48/check_production.sh（run_all.sh が呼ぶ）。終了コード: 0 = 成功 / 1 = 失敗
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

# requirements.md 29.4 の、層が「アプリケーション」の変数
REQUIRED=(
  GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET TOKEN_ENCRYPTION_KEY SESSION_SECRET RECAPTCHA_SECRET_KEY
  RELAY_SHARED_SECRET BFF_SHARED_SECRET ADMIN_BASIC_USER ADMIN_BASIC_PASSWORD DATABASE_URL RELAY_PUBLIC_URL
)

# すべての必須の変数へ、明らかなダミー値を与える。引数に、空にする変数の名前を渡すと、その変数だけ、空にする
production_env_args() {
  local blank=" $* " name
  for name in "${REQUIRED[@]}"; do
    if [[ "$blank" == *" $name "* ]]; then
      printf -- '-e\n%s=\n' "$name"
    else
      printf -- '-e\n%s=dummy-value-of-%s\n' "$name" "$name"
    fi
  done
}

echo "-- 1. 実物の資格情報が欠けていれば、本番は起動に失敗する（疑似へ倒れない。名前だけを書く。値は書かない）"
mapfile -t env_args < <(production_env_args GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET RECAPTCHA_SECRET_KEY)
output="$("$DC" exec -T "${env_args[@]}" -e RAILS_ENV=production -e RAILS_LOG_LEVEL=fatal backend sh -c '
  out=$(bin/rails runner "puts :booted" 2>&1)
  code=$?
  echo "exit_code=$code"
  printf "%s\n" "$out" | grep -m1 "required environment variables are missing"
  case "$out" in *booted*) echo "BOOTED" ;; esac
  case "$out" in *"dummy-value-of-"*) echo "LEAK_DUMMY_VALUE" ;; esac
' 2>&1 </dev/null)"
if [[ "$output" == *"exit_code=0"* || "$output" == *"BOOTED"* ]]; then
  fail "実物の資格情報が欠けているのに、本番として起動した"
else
  pass "実物の資格情報が欠けていると、本番は起動に失敗する"
fi
if [[ "$output" == *"required environment variables are missing: GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, RECAPTCHA_SECRET_KEY"* ]]; then
  pass "例外に、欠けている名前（GOOGLE_CLIENT_ID・GOOGLE_CLIENT_SECRET・RECAPTCHA_SECRET_KEY）だけを、表の順に書いている"
else
  fail "例外に、欠けている名前が、期待どおりに書かれていない（出力: $(printf '%s' "$output" | head -c 300)）"
fi
if [[ "$output" == *"LEAK_DUMMY_VALUE"* ]]; then
  fail "起動の失敗の出力に、設定されている値が現れた"
else
  pass "起動の失敗の出力に、設定されている値が現れない"
fi

echo
echo "-- 2. 資格情報がそろっていれば、本番として起動し、本番の構成が正しい（production_check.rb）"
# BFF の要求を作るため、BFF_SHARED_SECRET などは、コンテナの環境変数（compose が .env から与える値）を使う。実物の 3 つ（開発のコンテナでは空）にだけ、ダミー値を与える
if "$DC" exec -T -e GOOGLE_CLIENT_ID=dummy-google-client-id -e GOOGLE_CLIENT_SECRET=dummy-google-client-secret \
  -e RECAPTCHA_SECRET_KEY=dummy-recaptcha-secret-key -e RAILS_ENV=production -e RAILS_LOG_LEVEL=fatal \
  backend bin/rails runner - <"$HERE/production_check.rb"; then
  pass "本番の構成の確認（production_check.rb）がすべて成功した"
else
  fail "本番の構成の確認（production_check.rb）に失敗した項目がある"
fi

echo
echo "-- 3. 開発では、資格情報が空でも起動し、疑似が選ばれる（環境の判定）"
output="$("$DC" exec -T -e GOOGLE_CLIENT_ID= -e GOOGLE_CLIENT_SECRET= -e RECAPTCHA_SECRET_KEY= backend bin/rails runner '
gateways = ExternalServices.current
puts "dev-gateways=#{gateways.google_oidc.class.name},#{gateways.recaptcha_verifier.class.name} env=#{Rails.env} routes_dev=#{Rails.application.routes.routes.count { |r| r.defaults[:controller] == "dev/google" }}"
' 2>&1 </dev/null)"
if [[ "$output" == *"dev-gateways=FakeGoogleOidc,FakeRecaptchaVerifier env=development routes_dev=1"* ]]; then
  pass "開発（資格情報が空）: 疑似の Google・疑似の bot 判定が選ばれ、疑似の経路が 1 つある"
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
