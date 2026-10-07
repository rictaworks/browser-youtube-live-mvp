#!/usr/bin/env bash
# backend コンテナの中で実行する（docker-compose.yml が /scripts へ読み取り専用でマウントする）。
# ホストからは scripts/test_backend.sh を使う。使い方は、そちらの冒頭を参照。
set -euo pipefail
cd /app

die() {
  echo "test_backend.sh（コンテナの中）: $*" >&2
  exit 2
}

[[ -n "${TEST_DB_NAME:-}" ]] || die "TEST_DB_NAME が渡されていません。ホストから scripts/test_backend.sh を使ってください。"
if [[ ! "$TEST_DB_NAME" =~ ^[a-z][a-z0-9_]{0,62}$ ]] || [[ ! "$TEST_DB_NAME" =~ (^|_)test(_|$) ]]; then
  die "TEST_DB_NAME=\"${TEST_DB_NAME}\" は、テスト用の DB 名として使えません。"
fi
[[ "${DATABASE_URL:-}" == */bl_development ]] ||
  die "DATABASE_URL が、開発 DB（.../bl_development）を指していません。テスト用の URL は、これを元に組み立てます。"

# テスト用 DB の URL を、開発 DB の URL（接続先とパスワードは同じ）から組み立てる。開発 DB には接続しない
export RAILS_ENV=test
export DATABASE_URL="${DATABASE_URL%/bl_development}/${TEST_DB_NAME}"

# --- 引数の解釈 ---
# --db・--no-db はこのスクリプトのオプション。それ以外は RSpec へ渡す
db_mode=auto
rspec_args=()
for arg in "$@"; do
  case "$arg" in
    --db) db_mode=always ;;
    --no-db) db_mode=never ;;
    *) rspec_args+=("$arg") ;;
  esac
done

# 絞り込みのパス: 存在するファイル・ディレクトリの引数（spec/x_spec.rb:12 の :行番号、spec/x_spec.rb[1:2] の [ID] は除く）
paths=()
for arg in "${rspec_args[@]}"; do
  [[ "$arg" == -* ]] && continue
  candidate="${arg%%\[*}"
  candidate="${candidate%%:*}"
  [[ -e "$candidate" ]] && paths+=("$candidate")
done

# 対象に、Rails・DB を使うスペック（rails_helper を読むもの）があるか
needs_database() {
  case "$db_mode" in
    always) return 0 ;;
    never) return 1 ;;
  esac
  [[ "${#paths[@]}" -eq 0 ]] && return 0
  grep -rqsE "require(_relative)?[[:space:]]+[\"'][^\"']*rails_helper[\"']" "${paths[@]}"
}

echo "== テスト用 DB: ${TEST_DB_NAME}（RAILS_ENV=test）"

bundle check >/dev/null 2>&1 || bundle install

if needs_database; then
  echo "== DB の準備（無ければ作り、スキーマを読み込む）"
  bin/rails db:prepare
else
  echo "== DB の準備を省く（対象は Rails・DB を使わないスペック、または --no-db）"
fi

status=0
step() {
  echo
  echo "== $*"
  "$@" || status=1
}

step bundle exec rspec "${rspec_args[@]}"

if [[ "${#rspec_args[@]}" -eq 0 ]]; then
  step bin/rubocop
  step bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error
  step bin/bundler-audit check --update
elif [[ "${#paths[@]}" -gt 0 ]]; then
  step bin/rubocop "${paths[@]}"
else
  step bin/rubocop
fi

echo
if [[ "$status" -eq 0 ]]; then
  echo "== 成功しました"
else
  echo "== 失敗があります"
fi
exit "$status"
