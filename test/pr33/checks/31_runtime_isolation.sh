#!/usr/bin/env bash
# pr33-timeout: 600
# 起動中のコンテナ（開発サーバー）の実行時の検査（システム・結合テスト）。docker compose config（30）が静的な設定を確かめるのに対し、
# ここは、実際に動いているコンテナの中で、設定どおりになっていることと、コンテナ間の通信を確かめる。
# 環境変数は、名前と、空でないことだけを確かめる（値は端末へ出さない。コンテナの中で判定し、終了コードだけを受け取る）。
#
#   - コンテナの UID・GID はホストのユーザー（backend・relay・frontend）
#   - 環境変数が、層ごとに必要なものだけ、実際にコンテナへ入っている
#   - /contracts は、全サービスで読み取り専用でマウントされている（書き込めない）
#   - 内部通信の口（3101）は、compose のネットワークの中（relay から）では届き、ホストからは届かない。Puma は 2 つの口で待ち受ける
#   - frontend から BACKEND_ORIGIN、relay から BACKEND_INTERNAL_URL で、backend に届く（後続の issue の通信経路の土台）
#   - backend から db（開発 DB bl_development）に接続できる。db は backend のコンテナの外へ公開されていない
#   - 環境の判定: 開発サーバーは development・外部サービスは疑似実装（fake）。本番は未設定の SESSION_SECRET・公開済みの開発用の値で起動を拒否する
#   - 版: Ruby 3.4・Rails 8.1・Go 1.27・Node 22・PostgreSQL 17
set -uo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/requirements_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/requirements_env.sh"

require_tools docker jq grep awk sed
require_env_file
require_stack_healthy

# --- コンテナの UID・GID ---
section "コンテナの UID・GID は、ホストのユーザー（root 所有のファイルを作らない）"
for service in "${APP_SERVICES[@]}"; do
  expect_eq "${service}: UID:GID は ${HOST_UID}:${HOST_GID}" "${HOST_UID}:${HOST_GID}" "$(in_container "$service" sh -c 'echo "$(id -u):$(id -g)"' 2>/dev/null | tr -d '\r')"
done

# --- 環境変数 ---
section "環境変数（実際にコンテナへ入っているもの。名前と、空でないことだけを確かめる）"
all_known="$(printf '%s\nPOSTGRES_USER\nPOSTGRES_PASSWORD\nPOSTGRES_DB\n' "$(requirements_env_names)")"
optional_names="GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET RECAPTCHA_SITE_KEY RECAPTCHA_SECRET_KEY"
for service in "${APP_SERVICES[@]}"; do
  # 名前だけを、コンテナの中で切り出す（値を、ホストへ出さない）
  have="$(in_container "$service" sh -c 'printenv | cut -d= -f1' 2>/dev/null | tr -d '\r')"
  expected="$(requirements_env_names_for "$service")"
  expect_eq "${service}: 29.4 が求める変数が、実際にコンテナへ入っている" "" "$(oneline "$(set_minus "$expected" "$have")")"
  leaked="$(comm -12 <(sort -u <<<"$have") <(sort -u <<<"$all_known") | comm -23 - <(sort -u <<<"$expected"))"
  expect_eq "${service}: 29.4 が求めない変数（他の層の秘密値・db の資格情報）は、コンテナに入っていない" "" "$(oneline "$leaked")"

  empty_names=""
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    grep -qw "$name" <<<"$optional_names" && continue
    in_container "$service" sh -c 'printenv "$1" | grep -q .' sh "$name" >/dev/null 2>&1 || empty_names+="${name} "
  done <<<"$expected"
  expect_eq "${service}: 必須の環境変数が、空でない（GOOGLE_*・RECAPTCHA_* を除く）" "" "$empty_names"
done
for name in GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET RECAPTCHA_SECRET_KEY; do
  if in_container backend sh -c 'printenv "$1" >/dev/null' sh "$name" >/dev/null 2>&1; then
    pass "backend: ${name} は定義されている（開発・テストでは空でよい）"
  else
    fail "backend: ${name} は定義されている（空でもよいが、変数としては存在する）"
  fi
done
db_have="$(in_container db sh -c 'printenv | cut -d= -f1' 2>/dev/null | tr -d '\r')"
expect_eq "db: アプリケーションの秘密値（29.4 の変数）は、コンテナに入っていない" "" "$(oneline "$(comm -12 <(sort -u <<<"$db_have") <(sort -u <<<"$(requirements_env_names)"))")"

# --- /contracts ---
section "/contracts は、すべてのサービスで、読み取り専用（書き込めない）"
host_contracts_listing="$(ls -A "$ROOT_DIR/src/contracts" | tr '\n' ' ' | sed 's/ $//')"
for service in "${STACK_SERVICES[@]}"; do
  mount_options="$(in_container "$service" sh -c "awk '\$5 == \"/contracts\" {print \$6}' /proc/self/mountinfo" 2>/dev/null | tr -d '\r' | head -n 1)"
  if [[ ",${mount_options}," == *",ro,"* ]]; then
    pass "${service}: /contracts は、読み取り専用（ro）でマウントされている"
  else
    fail "${service}: /contracts は、読み取り専用（ro）でマウントされている（マウントのオプション: ${mount_options:-マウントが無い}）"
  fi
  if in_container "$service" sh -c 'test -d /contracts && test ! -w /contracts' >/dev/null 2>&1; then
    pass "${service}: /contracts は、ディレクトリで、書き込めない"
  else
    fail "${service}: /contracts は、ディレクトリで、書き込めない"
  fi
  expect_eq "${service}: /contracts の中身は、ホストの src/contracts と同じ（${host_contracts_listing:-空}）" "$host_contracts_listing" "$(in_container "$service" sh -c 'ls -A /contracts' 2>/dev/null | tr -d '\r' | tr '\n' ' ' | sed 's/ $//')"
done

# --- コンテナ間の通信 ---
section "内部通信の口（${INTERNAL_PORT}）: compose のネットワークの中では届き、ホストからは届かない"
expect_eq "backend の中で、公開側（3001）が 200 を返す" "200" "$(in_container backend curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3001/up 2>/dev/null)"
expect_eq "backend の中で、内部通信の口（${INTERNAL_PORT}）が 200 を返す（Puma は 2 つの口で待ち受ける）" "200" "$(in_container backend curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${INTERNAL_PORT}/up" 2>/dev/null)"
expect_eq "relay の BACKEND_INTERNAL_URL の口は ${INTERNAL_PORT}（内部通信の口）" "${INTERNAL_PORT}" "$(in_container relay sh -c 'echo "${BACKEND_INTERNAL_URL##*:}"' 2>/dev/null | tr -d '\r')"
expect_eq "relay から、BACKEND_INTERNAL_URL（compose のネットワークの中）で backend に届く" "200" "$(in_container relay sh -c 'curl -s -o /dev/null -w "%{http_code}" "$BACKEND_INTERNAL_URL/up"' 2>/dev/null)"
expect_eq "frontend から、BACKEND_ORIGIN（同一オリジン中継の転送先）で backend の公開側に届く" "200" \
  "$(in_container frontend node -e "fetch(process.env.BACKEND_ORIGIN + '/up').then((r) => console.log(r.status)).catch(() => console.log('error'))" 2>/dev/null | tr -d '\r')"
http_get "http://localhost:${INTERNAL_PORT}/up" --max-time 10
if [[ "$HTTP_STATUS" == "000" ]]; then
  pass "ホストからは、同じ ${INTERNAL_PORT} に届かない（コンテナ間では届く口が、ホストへは公開されていない）"
else
  fail "ホストから ${INTERNAL_PORT} に届いた（HTTP ${HTTP_STATUS}）"
fi

# --- db ---
section "db（backend だけが接続する）"
expect_eq "backend から、DATABASE_URL で db に接続でき、接続先は開発 DB（bl_development）" "bl_development" \
  "$(in_container backend sh -c 'psql "$DATABASE_URL" -tAc "select current_database()"' 2>/dev/null | tr -d '\r')"
expect_eq "開発 DB の環境の記録（ar_internal_metadata）は development（テストが開発 DB を書き換えていない）" "development" \
  "$(in_container backend sh -c 'psql "$DATABASE_URL" -tAc "select value from ar_internal_metadata where key = '"'"'environment'"'"'"' 2>/dev/null | tr -d '\r')"
expect_eq "relay・frontend には、db の資格情報（DATABASE_URL）が無い（db に接続できない）" "0" \
  "$(for service in relay frontend; do in_container "$service" sh -c 'printenv | cut -d= -f1' 2>/dev/null | grep -cxE 'DATABASE_URL|POSTGRES_USER|POSTGRES_PASSWORD'; done | awk '{sum += $1} END {print sum}')"

# --- 環境の判定・版 ---
section "環境の判定と版（backend）"
runner_output="$(in_container backend bin/rails runner 'puts [RUBY_VERSION, Rails.version, AppEnvironment.current.name, AppEnvironment.current.external_services, Time.zone.name, ActiveRecord.schema_format, Rails.application.secret_key_base == ENV["SESSION_SECRET"], ActiveRecord::Base.connection.current_database].join(",")' 2>/dev/null | tr -d '\r' | tail -n 1)"
IFS=, read -r ruby_version rails_version app_env external_services time_zone schema_format secret_matches database <<<"$runner_output"
if [[ "${ruby_version:-}" =~ ^3\.4\. ]]; then pass "Ruby は 3.4 系（${ruby_version}）"; else fail "Ruby は 3.4 系（実際: ${ruby_version:-取得できない}）"; fi
if [[ "${rails_version:-}" =~ ^8\.1\. ]]; then pass "Rails は 8.1 系（${rails_version}）"; else fail "Rails は 8.1 系（実際: ${rails_version:-取得できない}）"; fi
expect_eq "開発サーバーの環境は development（AppEnvironment）" "development" "${app_env:-}"
expect_eq "開発サーバーの外部サービスは、疑似実装（fake）" "fake" "${external_services:-}"
expect_eq "タイムゾーンは Tokyo（JST）" "Tokyo" "${time_zone:-}"
expect_eq "スキーマの形式は sql（部分一意索引・CHECK 制約を保持する）" "sql" "${schema_format:-}"
expect_eq "Rails の secret_key_base は、環境変数 SESSION_SECRET から与えられている" "true" "${secret_matches:-}"
expect_eq "Rails が接続している DB は、開発 DB（bl_development）" "bl_development" "${database:-}"

section "本番: SESSION_SECRET が未設定・空・公開済みの開発用の値なら、起動を失敗させる（起動時の確認）"
production_check() {
  # production_check <SESSION_SECRET の値 | --unset>: 本番モードで Rails を起動する（bin/rails runner）。
  # 出力と終了コードを PRODUCTION_OUT・PRODUCTION_STATUS へ入れる（--unset は、変数そのものを渡さない）
  local -a assignment=("SESSION_SECRET=$1")
  [[ "$1" == "--unset" ]] && assignment=()
  PRODUCTION_OUT="$(in_container backend env -u SESSION_SECRET RAILS_ENV=production "${assignment[@]}" bin/rails runner 'puts [Rails.env, AppEnvironment.current.external_services].join(",")' 2>&1)"
  PRODUCTION_STATUS=$?
  PRODUCTION_OUT="${PRODUCTION_OUT//$'\r'/}"
}
for variant in "--unset:未設定" ":空" "   :空白だけ"; do
  value="${variant%%:*}"
  label="${variant#*:}"
  production_check "$value"
  if [[ "$PRODUCTION_STATUS" -ne 0 ]] && grep -q 'SESSION_SECRET is required in production' <<<"$PRODUCTION_OUT"; then
    pass "本番で SESSION_SECRET が${label}なら、起動に失敗する（SESSION_SECRET is required in production）"
  else
    fail "本番で SESSION_SECRET が${label}なら、起動に失敗する（終了コード ${PRODUCTION_STATUS}）"
  fi
done
published_value="$(in_container backend ruby -r./config/app_environment -e 'puts AppEnvironment::DEVELOPMENT_SESSION_SECRET' 2>/dev/null | tr -d '\r' | tail -n 1)"
production_check "$published_value"
if [[ -n "$published_value" && "$PRODUCTION_STATUS" -ne 0 ]] && grep -q 'must not be the published development value' <<<"$PRODUCTION_OUT"; then
  pass "本番で、リポジトリに公開されている開発用の値を使うと、起動に失敗する"
else
  fail "本番で、リポジトリに公開されている開発用の値を使うと、起動に失敗する（終了コード ${PRODUCTION_STATUS}）"
fi
production_check "$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
expect_eq "対照: 本番で、有効な SESSION_SECRET なら起動できる。外部サービスは実物（live）" "production,live" "$(tail -n 1 <<<"$PRODUCTION_OUT")"

section "版と環境の判定（relay・frontend・db）"
go_version="$(in_container relay go version 2>/dev/null | tr -d '\r')"
if [[ "$go_version" =~ go1\.27 ]]; then pass "Go は 1.27 系（${go_version}）"; else fail "Go は 1.27 系（実際: ${go_version:-取得できない}）"; fi
if grep -qE 'relay: starting environment=development addr=:3002' < <("$DC" logs --no-color relay 2>&1); then
  pass "relay は、GIN_MODE=debug を development として判定して起動している（ログ: starting environment=development）"
else
  fail "relay は、GIN_MODE=debug を development として判定して起動している（ログに starting environment=development が無い）"
fi
node_version="$(in_container frontend node -v 2>/dev/null | tr -d '\r')"
if [[ "$node_version" =~ ^v22\. ]]; then pass "Node は 22 系（${node_version}）"; else fail "Node は 22 系（実際: ${node_version:-取得できない}）"; fi
next_version="$(in_container frontend node -e "console.log(require('next/package.json').version)" 2>/dev/null | tr -d '\r')"
if [[ "$next_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then pass "Next.js がインストールされている（${next_version}）"; else fail "Next.js がインストールされている（実際: ${next_version:-取得できない}）"; fi
postgres_version="$(in_container db postgres --version 2>/dev/null | tr -d '\r')"
if [[ "$postgres_version" =~ \)\ 17\. ]]; then pass "PostgreSQL は 17 系（${postgres_version}）"; else fail "PostgreSQL は 17 系（実際: ${postgres_version:-取得できない}）"; fi
expect_eq "backend の json gem は 2 系（3 系は ActiveSupport 8.1 と非互換になり得る）" "2" "$(in_container backend bundle exec ruby -rjson -e 'puts JSON::VERSION.split(".").first' 2>/dev/null | tr -d '\r' | tail -n 1)"

finish
