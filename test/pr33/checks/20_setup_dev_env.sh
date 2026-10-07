#!/usr/bin/env bash
# pr33-timeout: 300
# scripts/setup_dev_env.sh の受け入れテスト（issue #1「scripts/setup_dev_env.sh が .env を生成する」）。
# すべて、一時ディレクトリの別の ENV_FILE に対して実行する。実際の .env には触れない（最後に、変わっていないことを確かめる）。
#
#   (a) 必要な変数がすべて作られる（requirements.md 29.4・docker-compose.yml・.env.example と突き合わせる）
#   (b) 2 回目以降の実行で、内容が変わらない（冪等）
#   (c) 既存の値を上書きしない（全変数が既にあるとき、一部だけあるとき、引用符・export 付き）
#   (d) 値が標準出力・標準エラーに出ない（成功の場合も、拒否の場合も）
#   (e) RAILS_ENV が書かれていたら拒否する（ファイルは変えない）
# 実装担当の単体テスト（scripts/tests/test_setup_dev_env.sh）は、固定の期待値で個々の挙動を確かめる。
# ここでは、仕様・compose・設定ファイルから期待値を導いて突き合わせ、複数回の実行・実行のたびの乱数・出力の機密性を確かめる。
set -uo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/requirements_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/requirements_env.sh"

require_tools sha256sum awk sed grep cmp stat mktemp sort comm head
SETUP="$ROOT_DIR/scripts/setup_dev_env.sh"
[[ -x "$SETUP" ]] || abort "scripts/setup_dev_env.sh が実行できません"

# 環境変数が、結果に影響しないようにする
unset RELAY_PORT ENV_FILE

real_env_hash_before=""
[[ -f "$ENV_FILE_REAL" ]] && real_env_hash_before="$(sha256sum "$ENV_FILE_REAL" | awk '{print $1}')"

RANDOM_NAMES=(SESSION_SECRET TOKEN_ENCRYPTION_KEY RELAY_SHARED_SECRET BFF_SHARED_SECRET ADMIN_BASIC_PASSWORD POSTGRES_PASSWORD)
EMPTY_NAMES=(GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET RECAPTCHA_SITE_KEY RECAPTCHA_SECRET_KEY)

# --- 部品 ---
# 新しいケース用のディレクトリ（env/ に .env を置き、io/ に標準出力・標準エラーの記録を置く）を作り、そのパスを返す
new_case() {
  local dir
  dir="$(new_tmpdir setup)"
  mkdir -p "$dir/env" "$dir/io"
  printf '%s' "$dir"
}

# run_setup <ケース> [環境変数 NAME=値...]: ENV_FILE を <ケース>/env/.env にして実行する。終了コードを SETUP_STATUS に入れる
SETUP_STATUS=0
run_setup() {
  local case_dir="$1"
  shift
  env ENV_FILE="$case_dir/env/.env" "$@" "$SETUP" >"$case_dir/io/stdout" 2>"$case_dir/io/stderr"
  SETUP_STATUS=$?
}

# ファイルの変数名（コメントではない NAME= の行）を、重複を除いて返す
names_in() {
  grep -E '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$1" | sed -E 's/^[[:space:]]*(export[[:space:]]+)?//; s/=.*//' | sort -u
}

# 最後の NAME=値 の行の値
value_of() {
  grep -E "^[[:space:]]*(export[[:space:]]+)?$2=" "$1" | tail -n 1 | cut -d= -f2-
}

count_of() {
  grep -cE "^[[:space:]]*(export[[:space:]]+)?$2=" "$1"
}

has_name() {
  grep -qE "^[[:space:]]*(export[[:space:]]+)?$2=" "$1"
}

# ファイルの値が、標準出力・標準エラーの記録に出ていないこと。
# 値は 6 文字以上のものを対象にし、24 文字以上の長い値（乱数）は、先頭 12 文字だけの出力（部分的な漏れ）も検出する。
# RAILS_ENV の値（development・test・production）は、秘密ではなく、拒否の理由の説明にも現れる語なので、対象にしない
no_value_in_output() {
  local label="$1" case_dir="$2" env_file="$2/env/.env" leaked=0 value probe
  [[ -f "$env_file" ]] || return 0
  while IFS= read -r value; do
    value="${value%\"}"
    value="${value#\"}"
    [[ "${#value}" -ge 6 ]] || continue
    probe="$value"
    [[ "${#value}" -ge 24 ]] && probe="${value:0:12}"
    if grep -qF -e "$probe" "$case_dir/io/stdout" "$case_dir/io/stderr" 2>/dev/null; then
      leaked=1
    fi
  done < <(grep -E '=' "$env_file" | grep -vE '^[[:space:]]*#' | grep -vE '^[[:space:]]*(export[[:space:]]+)?RAILS_ENV[[:space:]]*=' | cut -d= -f2-)
  if [[ "$leaked" -eq 0 ]]; then
    pass "$label: 値（先頭部分を含む）が標準出力・標準エラーに出ない"
  else
    fail "$label: 値が標準出力・標準エラーに出ている"
  fi
}

# ケースの env/ に、.env だけがある（一時ファイル・バックアップを残さない）
only_env_file_left() {
  local label="$1" case_dir="$2" listing
  listing="$(ls -A "$case_dir/env" | tr '\n' ' ' | sed 's/ $//')"
  expect_eq "$label: ENV_FILE の置き場に、.env 以外のファイル（一時ファイル・バックアップ）を残さない" ".env" "$listing"
}

server_ports_constant() {
  grep -E "^[[:space:]]*$1[[:space:]]*=[[:space:]]*[0-9]+" "$ROOT_DIR/src/backend/config/server_ports.rb" | grep -oE '[0-9]+' | head -n 1
}

relay_default_port() {
  grep -E '^[[:space:]]*DefaultPort[[:space:]]*=[[:space:]]*[0-9]+' "$ROOT_DIR/src/relay/internal/config/config.go" | grep -oE '[0-9]+' | head -n 1
}

# 想定する名前の集合（仕様・compose・.env.example から導く）
REQ_NAMES="$(requirements_env_names)"
if [[ "$(wc -l <<<"$REQ_NAMES")" -ge 14 ]] && grep -qx SESSION_SECRET <<<"$REQ_NAMES"; then
  pass "requirements.md 29.4 の表から、変数名を $(wc -l <<<"$REQ_NAMES") 個読み取れた（確認の前提）"
else
  abort "requirements.md 29.4 の表を読み取れませんでした"
fi
# DATABASE_URL は、開発環境では docker-compose.yml が POSTGRES_USER・POSTGRES_PASSWORD から組み立てる（.env に書かない）
EXPECTED_GENERATED="$(compose_referenced_env_names)"

# --- (a) 必要な変数がすべて作られる ---
section "(a) 必要な変数がすべて作られる（ファイルが無いところから）"
case_a="$(new_case)"
run_setup "$case_a"
file_a="$case_a/env/.env"
expect_eq "(a) 終了コード 0" "0" "$SETUP_STATUS"
if [[ -f "$file_a" ]]; then pass "(a) .env が作られる"; else fail "(a) .env が作られる"; fi
generated="$(names_in "$file_a" 2>/dev/null)"
if same_set "$generated" "$EXPECTED_GENERATED"; then
  pass "(a) 作られる変数 = docker-compose.yml が外から受け取る変数（$(wc -l <<<"$generated") 個）"
else
  fail "(a) 作られる変数 = docker-compose.yml が外から受け取る変数（不足: $(oneline "$(set_minus "$EXPECTED_GENERATED" "$generated")") / 余分: $(oneline "$(set_minus "$generated" "$EXPECTED_GENERATED")")）"
fi
missing_29_4="$(set_minus "$(grep -vx DATABASE_URL <<<"$REQ_NAMES")" "$generated")"
expect_eq "(a) requirements.md 29.4 の変数（DATABASE_URL を除く）に、作られないものが無い" "" "$missing_29_4"
extra_vs_29_4="$(set_minus "$generated" "$REQ_NAMES" | tr '\n' ' ' | sed 's/ $//')"
expect_eq "(a) 29.4 に無い変数は、db コンテナ用の POSTGRES_USER・POSTGRES_PASSWORD だけ" "POSTGRES_PASSWORD POSTGRES_USER" "$extra_vs_29_4"
EXAMPLE_NAMES="$(env_example_names)"
if same_set "$EXAMPLE_NAMES" "$(printf '%s\nPOSTGRES_USER\nPOSTGRES_PASSWORD\n' "$REQ_NAMES")"; then
  pass "(a) .env.example の変数名 = 29.4 の変数 + POSTGRES_USER・POSTGRES_PASSWORD（名前の一覧が最新）"
else
  fail "(a) .env.example の変数名 = 29.4 の変数 + POSTGRES_USER・POSTGRES_PASSWORD（不足: $(oneline "$(set_minus "$(printf '%s\nPOSTGRES_USER\nPOSTGRES_PASSWORD\n' "$REQ_NAMES")" "$EXAMPLE_NAMES")") / 余分: $(oneline "$(set_minus "$EXAMPLE_NAMES" "$(printf '%s\nPOSTGRES_USER\nPOSTGRES_PASSWORD\n' "$REQ_NAMES")")")）"
fi

for name in "${RANDOM_NAMES[@]}"; do
  value="$(value_of "$file_a" "$name")"
  if [[ "$value" =~ ^[0-9a-f]{64,}$ ]]; then
    pass "(a) ${name} は乱数（16 進数で 64 桁以上 = 256 ビット以上）"
  else
    fail "(a) ${name} は乱数（16 進数で 64 桁以上）（実際の長さ: ${#value}。形式: $([[ "$value" =~ ^[0-9a-f]*$ ]] && echo 16進数 || echo 16進数ではない)）"
  fi
done
for name in "${EMPTY_NAMES[@]}"; do
  if has_name "$file_a" "$name" && [[ -z "$(value_of "$file_a" "$name")" ]]; then
    pass "(a) ${name} は、名前だけ書いて空のまま（開発・テストは疑似実装を使う）"
  else
    fail "(a) ${name} は、名前だけ書いて空のまま"
  fi
done

relay_default="$(relay_default_port)"
expect_eq "(a) BACKEND_ORIGIN は backend の公開側の口（ServerPorts::PUBLIC_DEFAULT）を指す" "http://backend:$(server_ports_constant PUBLIC_DEFAULT)" "$(value_of "$file_a" BACKEND_ORIGIN)"
expect_eq "(a) BACKEND_INTERNAL_URL は backend の内部通信の口（ServerPorts::INTERNAL）を指す" "http://backend:$(server_ports_constant INTERNAL)" "$(value_of "$file_a" BACKEND_INTERNAL_URL)"
expect_eq "(a) BACKEND_INTERNAL_URL の口は、ホストへ公開しない内部通信の口 ${INTERNAL_PORT}" "http://backend:${INTERNAL_PORT}" "$(value_of "$file_a" BACKEND_INTERNAL_URL)"
if [[ "$(value_of "$file_a" RELAY_PUBLIC_URL)" == "ws://localhost:${relay_default}/ws" ]]; then
  pass "(a) RELAY_PUBLIC_URL は、中継の既定の口（${relay_default}）の完全な WebSocket の URL（ws://…/ws）"
else
  fail "(a) RELAY_PUBLIC_URL は、中継の既定の口（${relay_default}）の完全な WebSocket の URL（実際: $(value_of "$file_a" RELAY_PUBLIC_URL)）"
fi
if [[ -n "$(value_of "$file_a" ADMIN_BASIC_USER)" ]]; then pass "(a) ADMIN_BASIC_USER は開発用の固定値で、空ではない"; else fail "(a) ADMIN_BASIC_USER は空ではない"; fi
if ! has_name "$file_a" RAILS_ENV; then pass "(a) RAILS_ENV を書かない（テストが development 環境で走る事故を防ぐ）"; else fail "(a) RAILS_ENV を書かない"; fi
if ! has_name "$file_a" DATABASE_URL; then pass "(a) DATABASE_URL を書かない（開発の接続先は docker-compose.yml が組み立てる）"; else fail "(a) DATABASE_URL を書かない"; fi
expect_eq "(a) .env の権限は 600" "600" "$(stat -c '%a' "$file_a")"
for name in "${RANDOM_NAMES[@]}"; do
  if [[ "$(count_of "$file_a" "$name")" -eq 1 ]]; then :; else fail "(a) ${name} が 1 行だけ書かれている"; fi
done
only_env_file_left "(a)" "$case_a"
no_value_in_output "(a) 生成時" "$case_a"
if [[ -s "$case_a/io/stdout" ]]; then
  if grep -q 'SESSION_SECRET' "$case_a/io/stdout"; then pass "(a) 追記した変数は、名前で知らせる（値は出さない）"; else fail "(a) 追記した変数は、名前で知らせる"; fi
else
  fail "(a) 追記した変数を、標準出力で知らせる"
fi
expect_eq "(a) 標準エラーには何も出ない（成功時）" "0" "$(wc -c <"$case_a/io/stderr")"

# --- (g) 実行のたびに、別の乱数になる ---
section "(g) 実行のたびに、別の乱数になる（固定の種を使わない）"
case_g="$(new_case)"
run_setup "$case_g"
same_values=0
for name in "${RANDOM_NAMES[@]}"; do
  [[ "$(value_of "$file_a" "$name")" == "$(value_of "$case_g/env/.env" "$name")" ]] && same_values=$((same_values + 1))
done
expect_eq "(g) 別の ENV_FILE に生成した乱数が、1 つも一致しない" "0" "$same_values"
distinct="$(for name in "${RANDOM_NAMES[@]}"; do value_of "$file_a" "$name"; done | sort -u | wc -l)"
expect_eq "(g) 1 つのファイルの中でも、乱数は変数ごとに異なる" "${#RANDOM_NAMES[@]}" "$distinct"
for name in "${RANDOM_NAMES[@]}"; do
  value="$(value_of "$file_a" "$name")"
  if [[ "${value:0:64}" =~ ^(.)\1+$ ]] || [[ "$value" =~ ^0+$ ]]; then fail "(g) ${name} が同じ文字の繰り返しではない"; fi
done

# --- (b) 2 回目以降の実行で、内容が変わらない ---
section "(b) 2 回目以降の実行で、内容が変わらない（冪等）"
cp "$file_a" "$case_a/before.env"
hash_before="$(sha256sum "$file_a" | awk '{print $1}')"
for attempt in 2 3; do
  run_setup "$case_a"
  expect_eq "(b) ${attempt} 回目の終了コード 0" "0" "$SETUP_STATUS"
  if [[ "$(sha256sum "$file_a" | awk '{print $1}')" == "$hash_before" ]]; then
    pass "(b) ${attempt} 回目の実行で、.env の内容が 1 バイトも変わらない"
  else
    fail "(b) ${attempt} 回目の実行で、.env の内容が変わった"
  fi
  no_value_in_output "(b) ${attempt} 回目" "$case_a"
done
only_env_file_left "(b)" "$case_a"

# --- (c) 既存の値を上書きしない ---
section "(c) 既存の値を上書きしない"
# c1: すべての変数が、既に自分の値で書かれている → 1 バイトも変えない
case_c1="$(new_case)"
{
  printf '# 自分の設定（このコメントも残る）\n'
  while IFS= read -r name; do
    printf '%s=dummy-existing-%s\n' "$name" "$name"
  done <<<"$EXPECTED_GENERATED"
} >"$case_c1/env/.env"
cp "$case_c1/env/.env" "$case_c1/before.env"
run_setup "$case_c1"
expect_eq "(c1) 終了コード 0" "0" "$SETUP_STATUS"
if cmp -s "$case_c1/env/.env" "$case_c1/before.env"; then
  pass "(c1) すべての変数が既にあるとき、.env を 1 バイトも変えない（値・コメント・順序）"
else
  fail "(c1) すべての変数が既にあるとき、.env を 1 バイトも変えない"
fi
no_value_in_output "(c1)" "$case_c1"

# c2: 一部だけある → 既存の行は先頭にそのまま残り、不足分だけが末尾へ追記される
case_c2="$(new_case)"
printf '# 自分のメモ\nSESSION_SECRET=dummy-existing-session\nGOOGLE_CLIENT_ID=dummy-existing-google-id\nBACKEND_ORIGIN=http://example.invalid:9\nUNRELATED=keep-me\n' >"$case_c2/env/.env"
cp "$case_c2/env/.env" "$case_c2/before.env"
run_setup "$case_c2"
file_c2="$case_c2/env/.env"
expect_eq "(c2) 終了コード 0" "0" "$SETUP_STATUS"
old_size="$(stat -c '%s' "$case_c2/before.env")"
if [[ "$(head -c "$old_size" "$file_c2")" == "$(cat "$case_c2/before.env")" ]]; then
  pass "(c2) 元の内容（コメント・既存の値・無関係な変数）を、そのまま残して、末尾へ追記する"
else
  fail "(c2) 元の内容を、そのまま残して、末尾へ追記する"
fi
expect_eq "(c2) 既存の SESSION_SECRET を上書きしない" "dummy-existing-session" "$(value_of "$file_c2" SESSION_SECRET)"
expect_eq "(c2) 既存の GOOGLE_CLIENT_ID を上書きしない" "dummy-existing-google-id" "$(value_of "$file_c2" GOOGLE_CLIENT_ID)"
expect_eq "(c2) 既存の BACKEND_ORIGIN を上書きしない（開発用の固定値より、自分の値を優先する）" "http://example.invalid:9" "$(value_of "$file_c2" BACKEND_ORIGIN)"
expect_eq "(c2) 無関係な変数 UNRELATED を残す" "keep-me" "$(value_of "$file_c2" UNRELATED)"
duplicates="$(names_in "$file_c2" | while IFS= read -r name; do [[ "$(count_of "$file_c2" "$name")" -gt 1 ]] && printf '%s ' "$name"; done)"
expect_eq "(c2) どの変数も、重複して書かれない" "" "$duplicates"
if same_set "$(names_in "$file_c2")" "$(printf '%s\nUNRELATED\n' "$EXPECTED_GENERATED")"; then
  pass "(c2) 不足していた変数だけが追記され、結果は「作られる変数 + UNRELATED」になる"
else
  fail "(c2) 不足していた変数だけが追記され、結果は「作られる変数 + UNRELATED」になる"
fi
no_value_in_output "(c2)" "$case_c2"

# c3: export 付き・引用符付き・行頭の空白がある行も、既存の値として扱う
case_c3="$(new_case)"
printf 'export SESSION_SECRET="has some spaces"\nTOKEN_ENCRYPTION_KEY='\''single-quoted-value'\''\n   RELAY_SHARED_SECRET=indented-value\n' >"$case_c3/env/.env"
cp "$case_c3/env/.env" "$case_c3/before.env"
run_setup "$case_c3"
file_c3="$case_c3/env/.env"
expect_eq "(c3) 終了コード 0" "0" "$SETUP_STATUS"
old_size="$(stat -c '%s' "$case_c3/before.env")"
if [[ "$(head -c "$old_size" "$file_c3")" == "$(cat "$case_c3/before.env")" ]]; then
  pass "(c3) export 付き・引用符付き・行頭に空白がある行を、そのまま残す"
else
  fail "(c3) export 付き・引用符付き・行頭に空白がある行を、そのまま残す"
fi
expect_eq "(c3) 既存の変数を重複して書かない（SESSION_SECRET・TOKEN_ENCRYPTION_KEY・RELAY_SHARED_SECRET）" "1 1 1" \
  "$(count_of "$file_c3" SESSION_SECRET) $(count_of "$file_c3" TOKEN_ENCRYPTION_KEY) $(count_of "$file_c3" RELAY_SHARED_SECRET)"

# --- (d) 拒否する場合も、値が出ない / (e) RAILS_ENV が書かれていたら拒否する ---
section "(e) RAILS_ENV が書かれていたら拒否する（ファイルは変えない。(d) 値を出さない）"
refuse_cases=(
  'RAILS_ENV=development'
  'RAILS_ENV=test'
  'export RAILS_ENV=production'
  '   RAILS_ENV=test'
  'RAILS_ENV='
  'RAILS_ENV="test"'
)
for line in "${refuse_cases[@]}"; do
  case_e="$(new_case)"
  printf 'SESSION_SECRET=dummy-secret-do-not-print-0123456789\nUNRELATED=1\n%s\n' "$line" >"$case_e/env/.env"
  cp "$case_e/env/.env" "$case_e/before.env"
  run_setup "$case_e"
  label="(e) 「${line}」"
  if [[ "$SETUP_STATUS" -ne 0 ]]; then pass "${label} は拒否される（終了コード ${SETUP_STATUS}）"; else fail "${label} は拒否される（終了コード 0 で通った）"; fi
  if grep -q 'RAILS_ENV' "$case_e/io/stderr"; then pass "${label}: 標準エラーが、RAILS_ENV が理由だと知らせる"; else fail "${label}: 標準エラーが、RAILS_ENV が理由だと知らせる"; fi
  if cmp -s "$case_e/env/.env" "$case_e/before.env"; then pass "${label}: ファイルを 1 バイトも変えない"; else fail "${label}: ファイルを 1 バイトも変えない"; fi
  no_value_in_output "${label}" "$case_e"
done
# 対照: RAILS_ENV ではないものを、誤って拒否しない
for line in '# RAILS_ENV=test' 'MY_RAILS_ENV=1' 'XRAILS_ENV=1'; do
  case_e="$(new_case)"
  printf '%s\n' "$line" >"$case_e/env/.env"
  run_setup "$case_e"
  if [[ "$SETUP_STATUS" -eq 0 ]]; then pass "(e) 対照:「${line}」（RAILS_ENV の定義ではない）は拒否しない"; else fail "(e) 対照:「${line}」（RAILS_ENV の定義ではない）は拒否しない（終了コード ${SETUP_STATUS}）"; fi
done

# --- 観察: ガードが認識しない書き方 ---
section "観察: RAILS_ENV の、ガードが認識しない書き方（受け入れ条件の外）"
for line in 'RAILS_ENV = test' 'RAILS_ENV: test'; do
  case_n="$(new_case)"
  printf '%s\n' "$line" >"$case_n/env/.env"
  run_setup "$case_n"
  if [[ "$SETUP_STATUS" -eq 0 ]]; then
    note "「${line}」は拒否されない（docker compose は、この書き方も RAILS_ENV の定義として解釈する）。docker-compose.yml が \${RAILS_ENV} を参照しないため、コンテナには影響しない（21_setup_compose_contract.sh で確認）"
  else
    pass "「${line}」も拒否される"
  fi
done

# --- 失敗の扱い ---
section "失敗の扱い"
case_f="$(new_case)"
env ENV_FILE="$case_f/no_such_dir/.env" "$SETUP" >"$case_f/io/stdout" 2>"$case_f/io/stderr"
failed_status=$?
if [[ "$failed_status" -ne 0 && ! -e "$case_f/no_such_dir" ]]; then
  pass "置き場のディレクトリが無いとき、失敗し（終了コード ${failed_status}）、何も作らない"
else
  fail "置き場のディレクトリが無いとき、失敗し、何も作らない（終了コード ${failed_status}）"
fi
(cd / && env ENV_FILE="$case_f/env/.env" "$SETUP" >/dev/null 2>&1)
expect_eq "どのディレクトリから実行しても動く（cwd が / でも成功する）" "0" "$?"
expect_eq "cwd が / のときも、乱数の変数が作られる" "1" "$(count_of "$case_f/env/.env" SESSION_SECRET)"

# --- 観察: 並行して実行したとき ---
section "観察: 同じファイルへ並行して実行したとき（受け入れ条件の外）"
case_p="$(new_case)"
for _ in 1 2 3 4; do
  env ENV_FILE="$case_p/env/.env" "$SETUP" >/dev/null 2>&1 &
done
wait
dup_names="$(names_in "$case_p/env/.env" | while IFS= read -r name; do [[ "$(count_of "$case_p/env/.env" "$name")" -gt 1 ]] && printf '%s ' "$name"; done)"
if [[ -z "$dup_names" ]]; then
  pass "4 つを並行して実行しても、どの変数も重複しない"
else
  note "4 つを並行して実行すると、同じ変数の行が重複して追記される（重複した変数の数: $(wc -w <<<"$dup_names")）。通常の使い方（1 つの端末で 1 回）では起きない。排他（flock など）があれば防げる"
fi

# --- 実際の .env は変わらない ---
section "実際の .env に触れていない"
if [[ -f "$ENV_FILE_REAL" ]]; then
  real_env_hash_after="$(sha256sum "$ENV_FILE_REAL" | awk '{print $1}')"
  if [[ "$real_env_hash_before" == "$real_env_hash_after" ]]; then pass "このテストの前後で、実際の .env は 1 バイトも変わらない"; else fail "このテストの前後で、実際の .env が変わった"; fi
else
  skip "実際の .env が無いため、変わっていないことの確認は省略した"
fi

finish
