#!/usr/bin/env bash
# pr33-timeout: 300
# docker compose config（scripts/dc.sh config）の出力の検査（システムテスト。実際の .env を使う）。
# 出力には秘密値が展開されるため、変数名・真偽・非機密の項目だけを取り出し、値は端末へ出さない。
#
#   - サービスは db・backend・relay・frontend の 4 つ
#   - 公開ポートは frontend 3000・backend 3001（公開側）・relay 3002 だけ。db・内部通信の口 3101 は公開しない
#   - backend・relay・frontend の user は、ホストの UID・GID（root 所有のファイルを作らない）
#   - /contracts は、すべてのサービスへ、読み取り専用の bind マウントで入る
#   - 環境変数（requirements.md 29.4）が、層ごとに必要なものだけ渡る（不足も、余分な漏れも無い）
#   - 秘密値が docker-compose.yml に直書きされていない（すべて ${...} の展開）
#   - ホストの機密領域（docker.sock など）をマウントしない・特権を持たない
set -uo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/requirements_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/requirements_env.sh"

require_tools docker jq grep awk sed
require_env_file

cfg="$("$DC" config --format json 2>/dev/null)"
cfg_status=$?
if [[ "$cfg_status" -ne 0 || -z "$cfg" ]]; then
  abort "scripts/dc.sh config が失敗しました（.env に不足がある可能性があります。scripts/setup_dev_env.sh を実行してください）"
fi

cfg_get() { jq -r "$1" <<<"$cfg"; }

# --- サービス ---
section "サービス"
expect_eq "サービスは db・backend・relay・frontend の 4 つだけ" "backend db frontend relay" "$(cfg_get '.services | keys | join(" ")')"
expect_eq "プロジェクト名は browser-youtube-live-mvp（COMPOSE_PROJECT_NAME が無いとき）" "${COMPOSE_PROJECT_NAME:-browser-youtube-live-mvp}" "$(cfg_get '.name')"

# --- 公開ポート ---
section "公開ポート"
expect_eq "frontend の公開ポートは ${FRONTEND_PORT}（コンテナ側 3000）だけ" "${FRONTEND_PORT}:3000" "$(cfg_get '.services.frontend.ports | map("\(.published):\(.target)") | join(" ")')"
expect_eq "backend の公開ポートは ${BACKEND_PORT}（コンテナ側 3001。公開側）だけ" "${BACKEND_PORT}:3001" "$(cfg_get '.services.backend.ports | map("\(.published):\(.target)") | join(" ")')"
expect_eq "relay の公開ポートは ${RELAY_PORT}（コンテナ側 3002）だけ" "${RELAY_PORT}:3002" "$(cfg_get '.services.relay.ports | map("\(.published):\(.target)") | join(" ")')"
expect_json "db は、ホストへポートを公開しない（ports が空）" '.services.db.ports | length == 0' "$cfg"
expect_json "どのサービスも、${INTERNAL_PORT}・${DB_PORT} をホストへ公開しない" \
  "[.services[] | .ports[]? | .target, (.published | tonumber)] | (index(${INTERNAL_PORT}) == null) and (index(${DB_PORT}) == null)" "$cfg"
expect_json "backend の内部通信の口（${INTERNAL_PORT}）は、expose だけ（compose のネットワークの中でだけ届く）" \
  ".services.backend.expose | map(tonumber) | index(${INTERNAL_PORT}) != null" "$cfg"
expect_json "host ネットワーク（network_mode）・特権（privileged）・追加の権限（cap_add）・デバイスを使わない" \
  '[.services[] | select(has("network_mode") or has("privileged") or has("cap_add") or has("devices") or has("pid") or has("ipc"))] | length == 0' "$cfg"
if [[ "$(cfg_get '.services.frontend.ports[0].host_ip')" == "null" ]]; then
  note "公開ポートは、ホストのすべてのインターフェース（0.0.0.0）へ束縛される。開発専用なら 127.0.0.1 への束縛（例: 127.0.0.1:3000:3000）にすると、同じネットワークの他の端末から、開発サーバー（デバッグ画面を含む）へ届かない"
fi

# --- ホストの UID・GID ---
section "user（ホストの UID・GID）"
for service in "${APP_SERVICES[@]}"; do
  expect_eq "${service} の user は、ホストの UID:GID（${HOST_UID}:${HOST_GID}）" "${HOST_UID}:${HOST_GID}" "$(cfg_get ".services.${service}.user")"
done
expect_eq "HOST_UID は 0（root）ではない" "1" "$([[ "$HOST_UID" -ne 0 ]] && echo 1 || echo 0)"

# --- /contracts ---
section "/contracts（3 層の契約の置き場）を、すべてのサービスへ読み取り専用でマウントする"
contracts_dir="$(cd "$ROOT_DIR/src/contracts" 2>/dev/null && pwd)"
if [[ -n "$contracts_dir" && -f "$ROOT_DIR/src/contracts/.gitkeep" ]]; then
  pass "src/contracts/.gitkeep がある（ディレクトリが無いと、Docker が root 所有で作ってしまう）"
else
  fail "src/contracts/.gitkeep がある"
fi
for service in "${STACK_SERVICES[@]}"; do
  expect_json "${service}: /contracts は、src/contracts の bind マウントで、読み取り専用（read_only: true）。1 つだけ" \
    "[.services.${service}.volumes[] | select(.target == \"/contracts\")] | (length == 1) and (.[0].type == \"bind\") and (.[0].read_only == true) and (.[0].source == \"${contracts_dir}\")" "$cfg"
done

# --- 環境変数 ---
section "環境変数（requirements.md 29.4）が、層ごとに必要なものだけ渡る"
all_known="$(printf '%s\nPOSTGRES_USER\nPOSTGRES_PASSWORD\nPOSTGRES_DB\n' "$(requirements_env_names)")"
for service in "${APP_SERVICES[@]}"; do
  have="$(cfg_get ".services.${service}.environment | keys[]")"
  expected="$(requirements_env_names_for "$service")"
  missing="$(set_minus "$expected" "$have")"
  expect_eq "${service}: 29.4 が求める変数がすべて渡る（$(oneline "$expected")）" "" "$(oneline "$missing")"
  leaked="$(comm -12 <(sort -u <<<"$have") <(sort -u <<<"$all_known") | comm -23 - <(sort -u <<<"$expected"))"
  expect_eq "${service}: 29.4 が求めない変数（他の層の秘密値・db の資格情報）は渡らない" "" "$(oneline "$leaked")"
done
expect_eq "db: 渡る変数は POSTGRES_DB・POSTGRES_PASSWORD・POSTGRES_USER だけ（アプリケーションの秘密値は渡らない）" \
  "POSTGRES_DB POSTGRES_PASSWORD POSTGRES_USER" "$(cfg_get '.services.db.environment | keys | join(" ")')"

# 値が入っていること（空ではないこと）。GOOGLE_*・RECAPTCHA_* は、開発・テストでは空でよい（名前があることだけを確かめる）
optional_names="GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET RECAPTCHA_SITE_KEY RECAPTCHA_SECRET_KEY"
for service in "${APP_SERVICES[@]}"; do
  empty_names=""
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    grep -qw "$name" <<<"$optional_names" && continue
    [[ "$name" == "DATABASE_URL" ]] && continue
    if ! jq -e ".services.${service}.environment.${name} | length > 0" <<<"$cfg" >/dev/null 2>&1; then
      empty_names+="${name} "
    fi
  done <<<"$(requirements_env_names_for "$service")"
  expect_eq "${service}: 必須の環境変数に、空の値が無い（GOOGLE_*・RECAPTCHA_* を除く）" "" "$empty_names"
done
expect_json "backend の DATABASE_URL は、db:5432 の開発 DB（bl_development）を指す PostgreSQL の URL" \
  '.services.backend.environment.DATABASE_URL | test("^postgres://[^:/@]+:[^@/]+@db:5432/bl_development$")' "$cfg"
expect_json "frontend の BACKEND_ORIGIN は、backend の公開側の口（http://backend:3001）" '.services.frontend.environment.BACKEND_ORIGIN == "http://backend:3001"' "$cfg"
expect_json "relay の BACKEND_INTERNAL_URL は、backend の内部通信の口（http://backend:${INTERNAL_PORT}）" ".services.relay.environment.BACKEND_INTERNAL_URL == \"http://backend:${INTERNAL_PORT}\"" "$cfg"
expect_json "backend の RELAY_PUBLIC_URL は、ブラウザから届く完全な WebSocket の URL（ws://localhost:…/ws）" \
  '.services.backend.environment.RELAY_PUBLIC_URL | test("^wss?://[^/ ]+/ws$")' "$cfg"
expect_json "env_file を使わない（.env の全変数を、全サービスへ渡さない）" '[.services[] | select(has("env_file"))] | length == 0' "$cfg"

# --- 環境の判定 ---
section "環境の判定（開発サーバーは development）"
expect_eq "backend: RAILS_ENV は development（.env に書かせず、docker-compose.yml が明示する）" "development" "$(cfg_get '.services.backend.environment.RAILS_ENV')"
expect_eq "relay: GIN_MODE は debug（development）" "debug" "$(cfg_get '.services.relay.environment.GIN_MODE')"
expect_json "frontend: 開発サーバー（next dev）で起動する" '.services.frontend.command | join(" ") | test("npm run dev")' "$cfg"

# --- 秘密値を docker-compose.yml へ直書きしない ---
section "秘密値を docker-compose.yml へ直書きしない（requirements.md 28.1）"
# POSTGRES_DB は、秘密ではない固定の名前（bl_development）。直書きでよいので、対象にしない
credential_names="$(printf '%s\nPOSTGRES_USER\nPOSTGRES_PASSWORD\n' "$(requirements_env_names)")"
hardcoded=""
checked=0
while IFS= read -r name; do
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    checked=$((checked + 1))
    grep -q '\${' <<<"$line" || hardcoded+="${name} "
  done < <(grep -E "^[[:space:]]+${name}:" "$ROOT_DIR/docker-compose.yml")
done <<<"$credential_names"
expect_eq "29.4 の変数と POSTGRES_USER・POSTGRES_PASSWORD の値は、すべて \${...} の展開（直書きが無い）" "" "$hardcoded"
if [[ "$checked" -ge 14 ]]; then pass "上の確認の対象は、docker-compose.yml の ${checked} 行（確認の前提。空振りではない）"; else fail "上の確認の対象が少なすぎる（${checked} 行）"; fi
# 名前に PASSWORD・SECRET・TOKEN・_KEY を含む YAML のキーは、値が空でなく、\${...} の展開を含まなければ、直書き
suspicious="$(grep -E '^[[:space:]]+[A-Za-z0-9_]*(PASSWORD|SECRET|TOKEN|_KEY)[A-Za-z0-9_]*:[[:space:]]*[^[:space:]#]' "$ROOT_DIR/docker-compose.yml" | grep -v '\${' | sed -E 's/^[[:space:]]+([A-Za-z0-9_]+):.*/\1/' | tr '\n' ' ')"
expect_eq "名前に PASSWORD・SECRET・TOKEN・_KEY を含むキーに、直書きの値が無い" "" "$suspicious"
if grep -qE '[0-9a-f]{32,}' "$ROOT_DIR/docker-compose.yml"; then fail "docker-compose.yml に、乱数に見える長い 16 進数が無い"; else pass "docker-compose.yml に、乱数に見える長い 16 進数が無い"; fi

# --- マウント ---
section "マウント（ホストの機密領域を、コンテナへ渡さない）"
outside="$(jq -r --arg root "$ROOT_DIR" '[.services[] | .volumes[]? | select(.type == "bind") | .source | select((startswith($root + "/")) | not)] | join(" ")' <<<"$cfg")"
expect_eq "bind マウントの元は、すべてこのリポジトリの中（docker.sock・ホームディレクトリなどを渡さない）" "" "$outside"
for service in backend relay frontend; do
  expect_json "${service}: /scripts（scripts/container）は読み取り専用" \
    "[.services.${service}.volumes[] | select(.target == \"/scripts\")] | (length == 1) and (.[0].read_only == true)" "$cfg"
done
expect_json "db のデータは、名前付きボリューム（db_data）に置く（ホストのファイルを作らない）" \
  '[.services.db.volumes[] | select(.target == "/var/lib/postgresql/data")] | (length == 1) and (.[0].type == "volume") and (.[0].source == "db_data")' "$cfg"

# --- ヘルスチェックと起動順序 ---
section "ヘルスチェックと起動順序"
expect_json "backend のヘルスチェックは、公開側の口の /up（127.0.0.1:3001）" '.services.backend.healthcheck.test | join(" ") | test("127\\.0\\.0\\.1:3001/up")' "$cfg"
expect_json "relay のヘルスチェックは、/health（127.0.0.1:3002）" '.services.relay.healthcheck.test | join(" ") | test("127\\.0\\.0\\.1:3002/health")' "$cfg"
expect_json "frontend のヘルスチェックは、/healthz（127.0.0.1:3000）" '.services.frontend.healthcheck.test | join(" ") | test("127\\.0\\.0\\.1:3000/healthz")' "$cfg"
expect_json "db のヘルスチェックは pg_isready" '.services.db.healthcheck.test | join(" ") | test("pg_isready")' "$cfg"
expect_json "backend は、db が healthy になってから起動する（up -d --wait の順序）" '.services.backend.depends_on.db.condition == "service_healthy"' "$cfg"

# --- イメージ ---
section "イメージ（版を固定する。latest を使わない）"
expect_eq "db は postgres:17" "postgres:17" "$(cfg_get '.services.db.image')"
expect_eq "frontend は node:22-slim（Node 22）" "node:22-slim" "$(cfg_get '.services.frontend.image')"
expect_eq "relay の開発用イメージは、Dockerfile の dev 段" "dev" "$(cfg_get '.services.relay.build.target')"
if grep -qE '^FROM ruby:3\.4' "$ROOT_DIR/src/backend/Dockerfile"; then pass "backend の Dockerfile は ruby:3.4（Ruby 3.4）"; else fail "backend の Dockerfile は ruby:3.4"; fi
if grep -qE '^FROM golang:1\.27-bookworm' "$ROOT_DIR/src/relay/Dockerfile"; then pass "relay の Dockerfile は golang:1.27-bookworm（Go 1.27）"; else fail "relay の Dockerfile は golang:1.27-bookworm"; fi
if grep -hE '^(FROM|[[:space:]]+image:)' "$ROOT_DIR/docker-compose.yml" "$ROOT_DIR/src/backend/Dockerfile" "$ROOT_DIR/src/relay/Dockerfile" | grep -qE ':latest|image:[[:space:]]*[a-z0-9./_-]+[[:space:]]*$'; then
  fail "latest・版の指定の無いイメージを使わない"
else
  pass "latest・版の指定の無いイメージを使わない"
fi

finish
