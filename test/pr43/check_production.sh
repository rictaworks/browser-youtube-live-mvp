#!/usr/bin/env bash
# PR #43（issue #7 アプリケーション基盤）の、本番（RAILS_ENV=production）の起動の検査。対象は開発サーバーの backend コンテナ
# （scripts/dc.sh exec）。本番へは接続しない（コンテナの中で、本番の設定で Rails を起動するだけ。DB・外部サービスへは接続しない）。
#
#   1. 必須の環境変数（requirements.md 29.4 のアプリケーション層の 11 個）が欠けていれば、起動に失敗し、
#      欠けている名前だけを書く（値は書かない）。空の値は、欠けているとみなす
#   2. 必須の環境変数がそろっていれば、起動し、本番の構成を、production_stack_check.rb が確かめる
#   3. 開発・テストでは、必須の環境変数の検査をしない（開発のコンテナは、GOOGLE_*・RECAPTCHA_* が空のまま動く）
#
# 秘密値は、画面へ出さない（コンテナの環境変数から読む。例外のメッセージに現れないことは、コンテナの中で照合する）。
# 使い方: test/pr43/check_production.sh（run_all.sh が呼ぶ）。終了コード: 0 = 成功 / 1 = 失敗
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

# すべての必須の変数へ、明らかなダミー値を与える（SESSION_SECRET は、公開されている開発用の値でないこと）。
# 引数に、空にする変数の名前を渡すと、その変数だけ、空にする
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

echo "-- 1. 必須の環境変数が欠けていれば、起動に失敗する（名前だけを書く。値は書かない）"
mapfile -t env_args < <(production_env_args GOOGLE_CLIENT_ID RECAPTCHA_SECRET_KEY RELAY_PUBLIC_URL)
# コンテナの中の sh で、起動の失敗の出力を捕捉し、秘密値（コンテナの環境変数）が含まれていないことも、その場で照合する
output="$("$DC" exec -T "${env_args[@]}" -e RAILS_ENV=production -e RAILS_LOG_LEVEL=fatal backend sh -c '
  out=$(bin/rails runner "puts :booted" 2>&1)
  code=$?
  echo "exit_code=$code"
  printf "%s\n" "$out" | grep -m1 "required environment variables are missing"
  case "$out" in *booted*) echo "BOOTED" ;; esac
  case "$out" in *"dummy-value-of-"*) echo "LEAK_DUMMY_VALUE" ;; esac
' 2>&1)"
if [[ "$output" == *"exit_code=0"* ]]; then
  fail "必須の環境変数が欠けているのに、本番として起動した"
else
  pass "必須の環境変数が欠けていると、起動に失敗する"
fi
if [[ "$output" == *"required environment variables are missing: GOOGLE_CLIENT_ID, RECAPTCHA_SECRET_KEY, RELAY_PUBLIC_URL"* ]]; then
  pass "例外に、欠けている名前（GOOGLE_CLIENT_ID・RECAPTCHA_SECRET_KEY・RELAY_PUBLIC_URL）だけを、表の順に書いている"
else
  fail "例外に、欠けている名前が、期待どおりに書かれていない（出力: $(printf '%s' "$output" | head -c 300)）"
fi
if [[ "$output" == *"LEAK_DUMMY_VALUE"* || "$output" == *"BOOTED"* ]]; then
  fail "起動の失敗の出力に、設定されている値が現れた"
else
  pass "起動の失敗の出力に、設定されている値が現れない"
fi

echo
echo "-- 1b. 空の値・空白だけの値も、欠けているとみなす（SESSION_SECRET が空）"
mapfile -t env_args < <(production_env_args SESSION_SECRET)
output="$("$DC" exec -T "${env_args[@]}" -e RAILS_ENV=production -e RAILS_LOG_LEVEL=fatal backend bin/rails runner 'puts :booted' 2>&1)"
# SESSION_SECRET は、Rails の secret_key_base（config/application.rb）に使うため、空ならそちらが先に失敗する（どちらも起動の失敗）
if [[ "$output" == *"booted"* ]]; then
  fail "SESSION_SECRET が空なのに、本番として起動した"
else
  pass "SESSION_SECRET が空なら、起動に失敗する"
fi

echo
echo "-- 2. 必須の環境変数がそろっていれば、起動し、本番の構成が正しい（production_stack_check.rb）"
# 開発のコンテナの .env は、GOOGLE_*・RECAPTCHA_SECRET_KEY を空のまま（疑似実装を使う）。この 3 つへだけ、ダミー値を与える。
# ほかの 8 つは、コンテナの環境変数（compose が .env から与える値）を使う（BFF の要求を作るため、BFF_SHARED_SECRET の実際の値が要る）
if "$DC" exec -T -e GOOGLE_CLIENT_ID=dummy-google-client-id -e GOOGLE_CLIENT_SECRET=dummy-google-client-secret \
  -e RECAPTCHA_SECRET_KEY=dummy-recaptcha-secret-key -e RAILS_ENV=production -e RAILS_LOG_LEVEL=fatal \
  backend bin/rails runner - <"$HERE/production_stack_check.rb"; then
  pass "本番の構成の確認（production_stack_check.rb）がすべて成功した"
else
  fail "本番の構成の確認（production_stack_check.rb）に失敗した項目がある"
fi

echo
echo "-- 3. 開発・テストでは、必須の環境変数の検査をしない"
output="$("$DC" exec -T -e GOOGLE_CLIENT_ID= -e RECAPTCHA_SECRET_KEY= backend bin/rails runner 'puts "booted-in-#{Rails.env}"' 2>&1)"
if [[ "$output" == *"booted-in-development"* ]]; then
  pass "開発（GOOGLE_CLIENT_ID・RECAPTCHA_SECRET_KEY が空）でも、起動する"
else
  fail "開発で、起動できない（出力: $(printf '%s' "$output" | head -c 300)）"
fi

echo
if [[ "$failures" -ne 0 ]]; then
  printf '%d 件失敗しました\n' "$failures"
  exit 1
fi
echo "すべて成功しました"
exit 0
