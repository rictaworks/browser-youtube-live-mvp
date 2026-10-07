#!/usr/bin/env bash
# pr33-timeout: 600
# scripts/setup_dev_env.sh が作る .env と、docker-compose.yml の必須変数の整合（結合テスト）。
# 一時ディレクトリに生成した .env を docker compose --env-file で読ませる。実際の .env は使わず、何も起動しない（config だけ）。
#
#   - 生成した .env で、compose の必須変数がすべて満たされる（config が成功する）
#   - 必須変数が 1 つ欠ける・空になると、compose は起動前に失敗し、setup_dev_env.sh の実行を案内する（値は出さない）
#   - 任意の変数（GOOGLE_*・RECAPTCHA_*）が欠けても、開発環境は起動できる
#   - 生成した値が、層をまたいで正しく渡る（DATABASE_URL の組み立て・共有の秘密値の一致・秘密値どうしが別の値）
#   - .env に RAILS_ENV・DATABASE_URL が書かれても、コンテナの環境は変わらない（開発 DB を指す DATABASE_URL・development のまま）
#   - 並行して複数の環境を起動するための環境変数（ポート・プロジェクト名）が効く
set -uo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/requirements_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/requirements_env.sh"

require_tools docker jq sed grep mktemp
SETUP="$ROOT_DIR/scripts/setup_dev_env.sh"

# compose が受け取る変数が、実行環境の値に影響されないようにする（--env-file より、プロセスの環境変数が優先されるため）
while IFS= read -r name; do unset "$name"; done < <(compose_referenced_env_names)
unset FRONTEND_PORT BACKEND_PORT RELAY_PORT COMPOSE_PROJECT_NAME ENV_FILE
# common.sh が読んだポート番号は、シェル変数として残る。ここから先の docker compose 呼び出しは、既定のポートで評価する
FRONTEND_PORT_DEFAULT=3000
BACKEND_PORT_DEFAULT=3001
RELAY_PORT_DEFAULT=3002

work="$(new_tmpdir contract)"
mkdir -p "$work/env"
generated="$work/env/generated.env"
ENV_FILE="$generated" "$SETUP" >/dev/null 2>&1 || abort "scripts/setup_dev_env.sh が失敗しました"

# compose_config <env ファイル> [docker compose config の引数...]: 標準出力と標準エラーを分けて、COMPOSE_OUT・COMPOSE_ERR・COMPOSE_STATUS へ入れる
COMPOSE_OUT=""
COMPOSE_ERR=""
COMPOSE_STATUS=0
compose_config() {
  local env_file="$1"
  shift
  local err_file="$work/compose_stderr"
  COMPOSE_OUT="$("$DC" --env-file "$env_file" config "$@" 2>"$err_file")"
  COMPOSE_STATUS=$?
  COMPOSE_ERR="$(cat "$err_file")"
}

value_in() {
  grep -E "^$2=" "$1" | tail -n 1 | cut -d= -f2-
}

# --- 生成した .env で、必須変数がすべて満たされる ---
section "生成した .env で、compose の必須変数がすべて満たされる"
compose_config "$generated" --quiet
expect_eq "生成した .env で docker compose config が成功する" "0" "$COMPOSE_STATUS"
required_names="$(compose_required_env_names)"
if [[ "$(wc -l <<<"$required_names")" -ge 10 ]]; then
  pass "docker-compose.yml の必須変数（\${NAME:?...}）を $(wc -l <<<"$required_names") 個読み取れた（確認の前提）"
else
  abort "docker-compose.yml の必須変数を読み取れませんでした"
fi

# --- 必須変数が欠ける・空になる ---
section "必須変数が 1 つ欠ける・空になると、compose は起動前に失敗する"
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  # 欠ける
  missing_file="$work/env/missing_${name}.env"
  grep -v "^${name}=" "$generated" >"$missing_file"
  compose_config "$missing_file" --quiet
  leaked=0
  while IFS= read -r secret; do
    grep -qF -e "$secret" <<<"$COMPOSE_ERR" && leaked=1
  done < <(secret_values "$missing_file")
  if [[ "$COMPOSE_STATUS" -ne 0 ]] && grep -q "$name" <<<"$COMPOSE_ERR" && grep -q 'setup_dev_env.sh' <<<"$COMPOSE_ERR"; then
    pass "${name} が無いと、compose が失敗し、変数名と setup_dev_env.sh の実行を案内する"
  else
    fail "${name} が無いと、compose が失敗し、変数名と setup_dev_env.sh の実行を案内する（終了コード ${COMPOSE_STATUS}）"
  fi
  [[ "$leaked" -eq 0 ]] || fail "${name} が無いときのエラーに、ほかの変数の値が出ている"
  # 空になる（${NAME:?...} は、空も未設定として扱う）
  empty_file="$work/env/empty_${name}.env"
  sed -E "s/^${name}=.*/${name}=/" "$generated" >"$empty_file"
  compose_config "$empty_file" --quiet
  if [[ "$COMPOSE_STATUS" -ne 0 ]] && grep -q "$name" <<<"$COMPOSE_ERR"; then
    pass "${name} が空でも、compose が失敗する"
  else
    fail "${name} が空でも、compose が失敗する（終了コード ${COMPOSE_STATUS}）"
  fi
done <<<"$required_names"

# --- 任意の変数 ---
section "任意の変数（GOOGLE_*・RECAPTCHA_*）が無くても、開発環境は起動できる"
for name in GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET RECAPTCHA_SITE_KEY RECAPTCHA_SECRET_KEY; do
  optional_file="$work/env/no_${name}.env"
  grep -v "^${name}=" "$generated" >"$optional_file"
  compose_config "$optional_file" --quiet
  expect_eq "${name} が無くても、compose config が成功する（空として渡る）" "0" "$COMPOSE_STATUS"
done
if grep -q 'GOOGLE_CLIENT_ID' "$ROOT_DIR/docker-compose.yml" && ! grep -qE '\$\{GOOGLE_CLIENT_ID:\?' "$ROOT_DIR/docker-compose.yml"; then
  pass "GOOGLE_CLIENT_ID は、docker-compose.yml が必須にしていない（開発・テストは疑似実装を使うため）"
else
  fail "GOOGLE_CLIENT_ID は、docker-compose.yml が必須にしていない"
fi

# --- 層をまたいで、値が正しく渡る ---
section "生成した値が、層をまたいで正しく渡る"
compose_config "$generated" --format json
expect_eq "config --format json が成功する" "0" "$COMPOSE_STATUS"
cfg="$COMPOSE_OUT"
pg_user="$(value_in "$generated" POSTGRES_USER)"
pg_pass="$(value_in "$generated" POSTGRES_PASSWORD)"
expect_eq "backend の DATABASE_URL は、POSTGRES_USER・POSTGRES_PASSWORD から組み立てた開発 DB（db:5432/bl_development）" \
  "postgres://${pg_user}:${pg_pass}@db:5432/bl_development" "$(jq -r '.services.backend.environment.DATABASE_URL' <<<"$cfg")"
expect_eq "db の POSTGRES_USER は、.env の値" "$pg_user" "$(jq -r '.services.db.environment.POSTGRES_USER' <<<"$cfg")"
expect_eq "db の POSTGRES_PASSWORD は、.env の値" "$pg_pass" "$(jq -r '.services.db.environment.POSTGRES_PASSWORD' <<<"$cfg")"
expect_eq "db の初期データベースは bl_development（開発 DB）" "bl_development" "$(jq -r '.services.db.environment.POSTGRES_DB' <<<"$cfg")"
expect_eq "relay の RELAY_SHARED_SECRET は、backend と同じ値（内部通信の相互確認）" \
  "$(jq -r '.services.backend.environment.RELAY_SHARED_SECRET' <<<"$cfg")" "$(jq -r '.services.relay.environment.RELAY_SHARED_SECRET' <<<"$cfg")"
expect_eq "frontend の BFF_SHARED_SECRET は、backend と同じ値（フロントエンドからの要求の確認）" \
  "$(jq -r '.services.backend.environment.BFF_SHARED_SECRET' <<<"$cfg")" "$(jq -r '.services.frontend.environment.BFF_SHARED_SECRET' <<<"$cfg")"
if [[ "$(value_in "$generated" RELAY_SHARED_SECRET)" != "$(value_in "$generated" BFF_SHARED_SECRET)" ]]; then
  pass "RELAY_SHARED_SECRET と BFF_SHARED_SECRET は、別の値（一方が漏れても、他方の確認を破られない）"
else
  fail "RELAY_SHARED_SECRET と BFF_SHARED_SECRET は、別の値"
fi
expect_eq "backend の SESSION_SECRET は、.env の値（Rails の secret_key_base の元）" \
  "$(value_in "$generated" SESSION_SECRET)" "$(jq -r '.services.backend.environment.SESSION_SECRET' <<<"$cfg")"
expect_eq "backend の RAILS_ENV は development（docker-compose.yml が明示する）" "development" "$(jq -r '.services.backend.environment.RAILS_ENV' <<<"$cfg")"
expect_eq "relay の GIN_MODE は debug（開発の判定: development）" "debug" "$(jq -r '.services.relay.environment.GIN_MODE' <<<"$cfg")"

# --- .env に RAILS_ENV・DATABASE_URL が書かれても、コンテナの環境は変わらない ---
section ".env に RAILS_ENV・DATABASE_URL が書かれても、コンテナの環境は変わらない"
hostile="$work/env/hostile.env"
{
  cat "$generated"
  printf 'RAILS_ENV = production\n'
  printf 'DATABASE_URL=postgres://attacker:dummy@example.invalid:5432/bl_production\n'
} >"$hostile"
compose_config "$hostile" --format json
hostile_cfg="$COMPOSE_OUT"
expect_eq "RAILS_ENV が .env にあっても、backend の RAILS_ENV は development のまま" "development" "$(jq -r '.services.backend.environment.RAILS_ENV' <<<"$hostile_cfg")"
expect_eq "DATABASE_URL が .env にあっても、backend の DATABASE_URL は組み立てた開発 DB のまま" \
  "postgres://${pg_user}:${pg_pass}@db:5432/bl_development" "$(jq -r '.services.backend.environment.DATABASE_URL' <<<"$hostile_cfg")"

# --- 並行して複数の環境を起動するための環境変数 ---
section "並行して複数の環境を起動するための環境変数（ポート・プロジェクト名）"
parallel_cfg="$(COMPOSE_PROJECT_NAME=bl-pr33-parallel FRONTEND_PORT=13000 BACKEND_PORT=13001 RELAY_PORT=13002 "$DC" --env-file "$generated" config --format json 2>/dev/null)"
expect_json "公開ポートが 13000・13001・13002 になる（frontend・backend・relay）" \
  '(.services.frontend.ports | map(.published) == ["13000"]) and (.services.backend.ports | map(.published) == ["13001"]) and (.services.relay.ports | map(.published) == ["13002"])' "$parallel_cfg"
expect_json "どの設定でも、backend の内部通信の口（${INTERNAL_PORT}）と db は、ホストへ公開しない" \
  "([.services[] | .ports[]? | .target] | index(${INTERNAL_PORT}) == null) and (.services.db.ports | length == 0)" "$parallel_cfg"
expect_eq "プロジェクト名を変えると、db のボリュームの名前も分かれる（既存の環境のデータと混ざらない）" "bl-pr33-parallel_db_data" "$(jq -r '.volumes.db_data.name' <<<"$parallel_cfg")"
default_cfg="$("$DC" --env-file "$generated" config --format json 2>/dev/null)"
expect_json "既定では、公開ポートが ${FRONTEND_PORT_DEFAULT}・${BACKEND_PORT_DEFAULT}・${RELAY_PORT_DEFAULT} になる" \
  "(.services.frontend.ports | map(.published) == [\"${FRONTEND_PORT_DEFAULT}\"]) and (.services.backend.ports | map(.published) == [\"${BACKEND_PORT_DEFAULT}\"]) and (.services.relay.ports | map(.published) == [\"${RELAY_PORT_DEFAULT}\"])" "$default_cfg"
expect_eq "既定のプロジェクト名は browser-youtube-live-mvp" "browser-youtube-live-mvp" "$(jq -r '.name' <<<"$default_cfg")"

finish
