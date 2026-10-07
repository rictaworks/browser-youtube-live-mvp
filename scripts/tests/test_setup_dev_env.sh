#!/usr/bin/env bash
# scripts/setup_dev_env.sh のテスト。
# 一時ディレクトリの .env（ENV_FILE で指定する）に対して実行し、リポジトリの .env には触れない。
#   - 不足している変数だけを追記する（乱数・開発用の固定値・空のままの変数）
#   - 既存の値を上書きしない。ファイルを削除せず、元の内容を残したまま末尾へ追記する
#   - 2 回実行しても結果が変わらない（冪等）
#   - RAILS_ENV が書かれている・生成する変数の値が空のときは、ファイルを変えずに失敗する
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
SETUP="$ROOT_DIR/scripts/setup_dev_env.sh"

# 環境変数が、テストの結果に影響しないようにする
unset RELAY_PORT ENV_FILE

failures=0

pass() { printf 'ok   %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}

# 一時ディレクトリを作り、そのパスを返す（後始末は OS の一時領域の掃除に任せる）
new_workdir() { mktemp -d "${TMPDIR:-/tmp}/setup_dev_env_test.XXXXXX"; }

# ファイルの最後の NAME=値 の行から値を取り出す
value_of() { grep -E "^$2=" "$1" | tail -n 1 | cut -d= -f2-; }

has_name() { grep -qE "^$2=" "$1"; }

RANDOM_NAMES=(SESSION_SECRET TOKEN_ENCRYPTION_KEY RELAY_SHARED_SECRET BFF_SHARED_SECRET ADMIN_BASIC_PASSWORD POSTGRES_PASSWORD)
EMPTY_NAMES=(GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET RECAPTCHA_SITE_KEY RECAPTCHA_SECRET_KEY)

# --- 1. ファイルが無いところから生成する ---
dir="$(new_workdir)"
env_file="$dir/.env"
out="$(ENV_FILE="$env_file" "$SETUP" 2>&1)"
status=$?
if [ "$status" -eq 0 ] && [ -f "$env_file" ]; then pass "ファイルが無くても生成できる"; else fail "ファイルが無くても生成できる（終了コード $status。出力: $out）"; fi

for name in "${RANDOM_NAMES[@]}"; do
  value="$(value_of "$env_file" "$name")"
  if [[ "$value" =~ ^[0-9a-f]{64,}$ ]]; then pass "$name は乱数（16 進文字列）で埋まる"; else fail "$name は乱数で埋まる（値の長さ: ${#value}）"; fi
done

session_length="$(value_of "$env_file" SESSION_SECRET | tr -d '\n' | wc -c)"
if [ "$session_length" -eq 128 ]; then pass "SESSION_SECRET は 64 バイト（128 桁）"; else fail "SESSION_SECRET は 128 桁（実際: $session_length）"; fi

distinct="$(for name in "${RANDOM_NAMES[@]}"; do value_of "$env_file" "$name"; done | sort -u | wc -l)"
if [ "$distinct" -eq "${#RANDOM_NAMES[@]}" ]; then pass "乱数の値は変数ごとに異なる"; else fail "乱数の値は変数ごとに異なる（異なる値: $distinct 個）"; fi

declare -A FIXED=(
  [ADMIN_BASIC_USER]=admin
  [POSTGRES_USER]=bl
  [BACKEND_ORIGIN]=http://backend:3001
  [BACKEND_INTERNAL_URL]=http://backend:3101
  [RELAY_PUBLIC_URL]=ws://localhost:3002/ws
)
for name in "${!FIXED[@]}"; do
  if [ "$(value_of "$env_file" "$name")" = "${FIXED[$name]}" ]; then pass "$name は開発用の固定値"; else fail "$name は開発用の固定値 ${FIXED[$name]}（実際: $(value_of "$env_file" "$name")）"; fi
done

for name in "${EMPTY_NAMES[@]}"; do
  if has_name "$env_file" "$name" && [ -z "$(value_of "$env_file" "$name")" ]; then pass "$name は名前だけ書いて空のまま"; else fail "$name は空のまま"; fi
done

if ! has_name "$env_file" RAILS_ENV; then pass "RAILS_ENV を書かない"; else fail "RAILS_ENV を書かない"; fi
if ! has_name "$env_file" DATABASE_URL; then pass "DATABASE_URL を書かない（docker-compose.yml が組み立てる）"; else fail "DATABASE_URL を書かない"; fi

leaked=0
for name in "${RANDOM_NAMES[@]}"; do
  value="$(value_of "$env_file" "$name")"
  if grep -qF "$value" <<<"$out"; then leaked=1; fi
done
if [ "$leaked" -eq 0 ]; then pass "生成した値を出力へ出さない"; else fail "生成した値を出力へ出さない"; fi

if [ "$(stat -c '%a' "$env_file")" = "600" ]; then pass ".env の権限は 600"; else fail ".env の権限は 600（実際: $(stat -c '%a' "$env_file")）"; fi

# --- 2. 2 回目の実行は何も変えない（冪等） ---
cp "$env_file" "$dir/before.env"
out="$(ENV_FILE="$env_file" "$SETUP" 2>&1)"
status=$?
if [ "$status" -eq 0 ] && cmp -s "$env_file" "$dir/before.env"; then pass "2 回実行しても .env が変わらない"; else fail "2 回実行しても .env が変わらない（終了コード $status）"; fi

# --- 3. 既存の値を上書きしない。元の内容を残したまま追記する ---
dir="$(new_workdir)"
env_file="$dir/.env"
printf '# 自分のメモ\nSESSION_SECRET=keep-this-value\nGOOGLE_CLIENT_ID=my-google-client-id\nUNRELATED=1\n' >"$env_file"
cp "$env_file" "$dir/before.env"
out="$(ENV_FILE="$env_file" "$SETUP" 2>&1)"
status=$?
if [ "$status" -eq 0 ]; then pass "既存の値がある .env にも実行できる"; else fail "既存の値がある .env にも実行できる（終了コード $status。出力: $out）"; fi
if [ "$(value_of "$env_file" SESSION_SECRET)" = "keep-this-value" ]; then pass "既存の SESSION_SECRET を上書きしない"; else fail "既存の SESSION_SECRET を上書きしない"; fi
if [ "$(value_of "$env_file" GOOGLE_CLIENT_ID)" = "my-google-client-id" ]; then pass "既存の GOOGLE_CLIENT_ID を上書きしない"; else fail "既存の GOOGLE_CLIENT_ID を上書きしない"; fi
if [ "$(grep -c '^GOOGLE_CLIENT_ID=' "$env_file")" -eq 1 ] && [ "$(grep -c '^SESSION_SECRET=' "$env_file")" -eq 1 ]; then pass "既存の変数を重複して書かない"; else fail "既存の変数を重複して書かない"; fi
if has_name "$env_file" TOKEN_ENCRYPTION_KEY && has_name "$env_file" GOOGLE_CLIENT_SECRET; then pass "不足している変数だけを追記する"; else fail "不足している変数だけを追記する"; fi
old_size="$(stat -c '%s' "$dir/before.env")"
if [ "$(head -c "$old_size" "$env_file")" = "$(cat "$dir/before.env")" ]; then pass "元の内容（コメント・他の変数）を残したまま末尾へ追記する"; else fail "元の内容を残したまま末尾へ追記する"; fi

# --- 3.5. export 付きの行・行頭に空白がある行も、既存の値として扱う（重複して書かない） ---
dir="$(new_workdir)"
env_file="$dir/.env"
printf 'export SESSION_SECRET=exported-secret\n  GOOGLE_CLIENT_ID=indented-id\n' >"$env_file"
out="$(ENV_FILE="$env_file" "$SETUP" 2>&1)"
status=$?
if [ "$status" -eq 0 ] &&
  [ "$(grep -cE '^[[:space:]]*(export[[:space:]]+)?SESSION_SECRET=' "$env_file")" -eq 1 ] &&
  [ "$(grep -cE '^[[:space:]]*(export[[:space:]]+)?GOOGLE_CLIENT_ID=' "$env_file")" -eq 1 ] &&
  grep -qx 'export SESSION_SECRET=exported-secret' "$env_file"; then
  pass "export 付き・行頭に空白がある行も、既存の値として扱い、重複して書かない"
else
  fail "export 付き・行頭に空白がある行も、既存の値として扱い、重複して書かない（終了コード $status。出力: $out）"
fi

# --- 4. 改行だけの .env（リポジトリの .env と同じ状態）と、末尾に改行が無い .env ---
dir="$(new_workdir)"
env_file="$dir/.env"
printf '\n' >"$env_file"
out="$(ENV_FILE="$env_file" "$SETUP" 2>&1)"
status=$?
if [ "$status" -eq 0 ] && has_name "$env_file" SESSION_SECRET; then pass "改行だけの .env に追記できる"; else fail "改行だけの .env に追記できる（終了コード $status。出力: $out）"; fi

dir="$(new_workdir)"
env_file="$dir/.env"
printf 'UNRELATED=1' >"$env_file"
out="$(ENV_FILE="$env_file" "$SETUP" 2>&1)"
status=$?
if [ "$status" -eq 0 ] && grep -qx 'UNRELATED=1' "$env_file" && has_name "$env_file" SESSION_SECRET; then pass "末尾に改行が無い .env でも、既存の行を壊さず追記する"; else fail "末尾に改行が無い .env でも、既存の行を壊さず追記する（終了コード $status）"; fi

# --- 5. 失敗する場合は、ファイルを変えない ---
dir="$(new_workdir)"
env_file="$dir/.env"
printf 'RAILS_ENV=test\n' >"$env_file"
cp "$env_file" "$dir/before.env"
out="$(ENV_FILE="$env_file" "$SETUP" 2>&1)"
status=$?
if [ "$status" -ne 0 ] && grep -q 'RAILS_ENV' <<<"$out" && cmp -s "$env_file" "$dir/before.env"; then pass "RAILS_ENV が書かれていれば、ファイルを変えずに失敗する"; else fail "RAILS_ENV が書かれていれば、ファイルを変えずに失敗する（終了コード $status。出力: $out）"; fi

dir="$(new_workdir)"
env_file="$dir/.env"
printf 'SESSION_SECRET=\n' >"$env_file"
cp "$env_file" "$dir/before.env"
out="$(ENV_FILE="$env_file" "$SETUP" 2>&1)"
status=$?
if [ "$status" -ne 0 ] && grep -q 'SESSION_SECRET' <<<"$out" && cmp -s "$env_file" "$dir/before.env"; then pass "生成する変数の値が空なら、ファイルを変えずに失敗する"; else fail "生成する変数の値が空なら、ファイルを変えずに失敗する（終了コード $status。出力: $out）"; fi

# --- 5.5. RELAY_PORT を変えた環境（並行して複数の環境を起動するとき）: RELAY_PUBLIC_URL の既定値が、その口になる ---
dir="$(new_workdir)"
env_file="$dir/.env"
out="$(RELAY_PORT=13002 ENV_FILE="$env_file" "$SETUP" 2>&1)"
status=$?
if [ "$status" -eq 0 ] && [ "$(value_of "$env_file" RELAY_PUBLIC_URL)" = "ws://localhost:13002/ws" ]; then
  pass "環境変数 RELAY_PORT があれば、RELAY_PUBLIC_URL の既定値の口になる"
else
  fail "環境変数 RELAY_PORT があれば、RELAY_PUBLIC_URL の既定値の口になる（終了コード $status。値: $(value_of "$env_file" RELAY_PUBLIC_URL)）"
fi

dir="$(new_workdir)"
env_file="$dir/.env"
printf 'RELAY_PORT=14002\n' >"$env_file"
out="$(ENV_FILE="$env_file" "$SETUP" 2>&1)"
status=$?
if [ "$status" -eq 0 ] && [ "$(value_of "$env_file" RELAY_PUBLIC_URL)" = "ws://localhost:14002/ws" ] && [ "$(grep -c '^RELAY_PORT=' "$env_file")" -eq 1 ]; then
  pass ".env の RELAY_PORT があれば、RELAY_PUBLIC_URL の既定値の口になる（RELAY_PORT は書き換えない）"
else
  fail ".env の RELAY_PORT があれば、RELAY_PUBLIC_URL の既定値の口になる（終了コード $status。値: $(value_of "$env_file" RELAY_PUBLIC_URL)）"
fi

dir="$(new_workdir)"
env_file="$dir/.env"
out="$(RELAY_PORT=abc ENV_FILE="$env_file" "$SETUP" 2>&1)"
status=$?
if [ "$status" -ne 0 ] && [ ! -e "$env_file" ] && grep -q 'RELAY_PORT' <<<"$out"; then
  pass "RELAY_PORT がポート番号でなければ、ファイルを作らずに失敗する"
else
  fail "RELAY_PORT がポート番号でなければ、ファイルを作らずに失敗する（終了コード $status。出力: $out）"
fi

# --- 6. リポジトリの中の .env は、gitignore されていなければ失敗する ---
not_ignored="$ROOT_DIR/scripts/tests/zz-not-ignored.env"
out="$(ENV_FILE="$not_ignored" "$SETUP" 2>&1)"
status=$?
if [ "$status" -ne 0 ] && [ ! -e "$not_ignored" ] && grep -q 'gitignore' <<<"$out"; then pass "gitignore されていないファイルには書かずに失敗する"; else fail "gitignore されていないファイルには書かずに失敗する（終了コード $status。出力: $out）"; fi

if [ "$failures" -ne 0 ]; then
  printf '\n%d 件失敗しました\n' "$failures"
  exit 1
fi
printf '\nすべて成功しました\n'
