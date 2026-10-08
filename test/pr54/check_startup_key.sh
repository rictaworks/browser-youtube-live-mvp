#!/usr/bin/env bash
# PR 54（issue #11。#10 のレビューの申し送り）の、TOKEN_ENCRYPTION_KEY の形式の、起動時の検査。対象は開発サーバーの backend コンテナ
# （scripts/dc.sh exec）。コンテナの中で、環境変数を変えて Rails を起動するだけ（DB・外部サービスへは接続しない）。
#
#   更新トークンの暗号鍵は、64 桁の 16 進数。形式の検査が、初回の使用時にしか働かないと、形式の誤りが、最初の YouTube 接続（利用者の操作）まで見つからない。
#   1. 設定されていて、形式が誤り -> 開発の環境でも、起動に失敗する。例外は、変数の名前と期待する形式だけを書き、値を書かない
#   2. 形式が正しい -> 起動できる（大文字の 16 進数も）
#   3. 開発で、未設定・空・空白だけ -> 起動できる（この検査では止めない。疑似を使う最初の使用で、止まる）
#   4. 本番で、未設定 -> 必須の環境変数の検査が、起動を失敗させる。形式が誤り -> 同じく、この検査が、起動を失敗させる（値を書かない）
#
# 値は、明らかなダミー。秘密値（コンテナの環境変数）は、画面へ出さない。
# 使い方: test/pr54/check_startup_key.sh（run_all.sh が呼ぶ）。終了コード: 0 = 成功 / 1 = 失敗
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

BAD_VALUE="dummy-not-hexadecimal-value-must-not-appear"
VALID_KEY="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

# 開発の環境で、TOKEN_ENCRYPTION_KEY を指定して起動する。出力（終了コードと、最初の行）を返す。引数: 鍵の値
boot_development() {
  "$DC" exec -T -e "TOKEN_ENCRYPTION_KEY=$1" backend sh -c '
    out=$(bin/rails runner "puts :booted" 2>&1 </dev/null)
    code=$?
    echo "exit_code=$code"
    printf "%s\n" "$out" | grep -m1 -E "TOKEN_ENCRYPTION_KEY|booted"
    case "$out" in *must-not-appear*) echo "LEAK_VALUE" ;; esac
  ' 2>&1 </dev/null
}

echo "-- 1. 設定されていて、形式が誤り: 開発の環境でも、起動に失敗する（名前と期待する形式だけ。値を書かない）"
for label_value in "非 16 進数の文字を含む:$BAD_VALUE" "短い（63 桁）:${VALID_KEY:0:63}" "長い（65 桁）:${VALID_KEY}0"; do
  label="${label_value%%:*}"
  value="${label_value#*:}"
  output="$(boot_development "$value")"
  if [[ "$output" == *"exit_code=0"* || "$output" == *"booted"* ]]; then
    fail "形式が誤り（$label）なのに、起動した"
  elif [[ "$output" == *"TOKEN_ENCRYPTION_KEY must be 64 hexadecimal characters (32 bytes)"* && "$output" != *"LEAK_VALUE"* ]]; then
    pass "形式が誤り（$label）: 起動に失敗し、名前と期待する形式を書く。値は書かない"
  else
    fail "形式が誤り（$label）: 失敗の内容が期待と違う（出力: $(printf '%s' "$output" | head -c 300)）"
  fi
done

echo
echo "-- 2. 形式が正しい: 起動できる（大文字の 16 進数も）"
for value in "$VALID_KEY" "${VALID_KEY^^}"; do
  output="$(boot_development "$value")"
  if [[ "$output" == *"exit_code=0"* && "$output" == *"booted"* ]]; then
    pass "形式が正しい鍵（${#value} 桁）で、起動できる"
  else
    fail "形式が正しい鍵で、起動できない（出力: $(printf '%s' "$output" | head -c 300)）"
  fi
done

echo
echo "-- 3. 開発で、未設定・空・空白だけ: 起動できる（この検査では止めない）"
for value in "" "   "; do
  output="$(boot_development "$value")"
  if [[ "$output" == *"exit_code=0"* && "$output" == *"booted"* ]]; then
    pass "鍵が空（$(printf '%s' "$value" | wc -c) 文字）の開発は、起動できる"
  else
    fail "鍵が空の開発が、起動できない（出力: $(printf '%s' "$output" | head -c 300)）"
  fi
done
output="$("$DC" exec -T backend sh -c '
  unset TOKEN_ENCRYPTION_KEY
  out=$(bin/rails runner "puts :booted" 2>&1 </dev/null)
  echo "exit_code=$?"
  printf "%s\n" "$out" | grep -m1 booted
' 2>&1 </dev/null)"
if [[ "$output" == *"exit_code=0"* && "$output" == *"booted"* ]]; then
  pass "鍵が未設定（変数なし）の開発は、起動できる（CI は、鍵なしで DB の準備・RSpec を動かす）"
else
  fail "鍵が未設定の開発が、起動できない（出力: $(printf '%s' "$output" | head -c 300)）"
fi

echo
echo "-- 4. 本番: 未設定は必須の環境変数の検査が、形式の誤りはこの検査が、起動を失敗させる"
REQUIRED=(
  GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET TOKEN_ENCRYPTION_KEY SESSION_SECRET RECAPTCHA_SECRET_KEY
  RELAY_SHARED_SECRET BFF_SHARED_SECRET ADMIN_BASIC_USER ADMIN_BASIC_PASSWORD DATABASE_URL RELAY_PUBLIC_URL
)
# すべての必須の変数へ、明らかなダミー値を与える。TOKEN_ENCRYPTION_KEY は、引数の値にする（空にもできる）
production_env_args() {
  local key_value="$1" name
  for name in "${REQUIRED[@]}"; do
    if [[ "$name" == "TOKEN_ENCRYPTION_KEY" ]]; then
      printf -- '-e\n%s=%s\n' "$name" "$key_value"
    else
      printf -- '-e\n%s=dummy-value-of-%s\n' "$name" "$name"
    fi
  done
}
boot_production() {
  mapfile -t env_args < <(production_env_args "$1")
  "$DC" exec -T "${env_args[@]}" -e RAILS_ENV=production -e RAILS_LOG_LEVEL=fatal backend sh -c '
    out=$(bin/rails runner "puts :booted" 2>&1 </dev/null)
    echo "exit_code=$?"
    printf "%s\n" "$out" | grep -m1 -E "TOKEN_ENCRYPTION_KEY|booted"
    case "$out" in *must-not-appear*) echo "LEAK_VALUE" ;; esac
  ' 2>&1 </dev/null
}
output="$(boot_production "")"
if [[ "$output" != *"exit_code=0"* && "$output" == *"required environment variables are missing: TOKEN_ENCRYPTION_KEY"* ]]; then
  pass "本番で鍵が空: 必須の環境変数の検査が、名前だけを書いて、起動を失敗させる"
else
  fail "本番で鍵が空のときの結果が、期待と違う（出力: $(printf '%s' "$output" | head -c 300)）"
fi
output="$(boot_production "$BAD_VALUE")"
if [[ "$output" != *"exit_code=0"* && "$output" == *"TOKEN_ENCRYPTION_KEY must be 64 hexadecimal characters (32 bytes)"* && "$output" != *"LEAK_VALUE"* ]]; then
  pass "本番で鍵の形式が誤り: 起動に失敗し、名前と期待する形式を書く。値は書かない"
else
  fail "本番で鍵の形式が誤りのときの結果が、期待と違う（出力: $(printf '%s' "$output" | head -c 300)）"
fi
output="$(boot_production "$VALID_KEY")"
if [[ "$output" == *"exit_code=0"* && "$output" == *"booted"* ]]; then
  pass "本番で鍵の形式が正しければ、起動できる"
else
  fail "本番で鍵の形式が正しいのに、起動できない（出力: $(printf '%s' "$output" | head -c 300)）"
fi

echo
if [[ "$failures" -ne 0 ]]; then
  printf '%d 件失敗しました\n' "$failures"
  exit 1
fi
echo "すべて成功しました"
exit 0
