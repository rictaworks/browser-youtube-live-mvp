#!/usr/bin/env bash
# pr33-timeout: 1800
# 起動と接続（issue #1「起動と接続」の受け入れ条件）。対象は開発サーバー。
#   - .env が生成済みで、gitignore されていて、所有者・権限が正しい（値は読まない）
#   - scripts/dc.sh up -d --wait で、db・backend・relay・frontend の 4 サービスが healthy になる
#   - 起動済みの環境に、もう一度 up -d --wait を実行しても、コンテナを作り直さない（冪等）
#   - 公開ポートは frontend 3000・backend 3001（公開側）・relay 3002 だけ（3101・db は公開しない）
#
# 初回の起動は、gem・npm パッケージ・Go モジュールの取得とビルドのため、数分かかる。
set -uo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_tools docker jq git stat
require_env_file

# --- .env（値は読まない） ---
section ".env（実際の開発用。値は読まない）"
expect_eq ".env の権限は 600（秘密値を含むため）" "600" "$(stat -c '%a' "$ENV_FILE_REAL")"
expect_eq ".env の所有者はホストのユーザー" "$HOST_UID" "$(stat -c '%u' "$ENV_FILE_REAL")"
check ".env は gitignore されている（git status に出ない）" git -C "$ROOT_DIR" check-ignore -q -- .env
if [[ -z "$(git -C "$ROOT_DIR" ls-files -- .env)" ]]; then pass ".env は git の追跡対象ではない"; else fail ".env は git の追跡対象ではない（追跡されている）"; fi
if git -C "$ROOT_DIR" status --short | grep -qE '(^|[ /])\.env$'; then fail ".env が git status に出ている"; else pass ".env が git status に出ない"; fi

# --- up -d --wait ---
section "scripts/dc.sh up -d --wait"
up_output="$("$DC" up -d --wait 2>&1)"
up_status=$?
if [[ "$up_status" -eq 0 ]]; then
  pass "up -d --wait が成功した（終了コード 0）"
else
  fail "up -d --wait が失敗した（終了コード ${up_status}）。出力の末尾: $(tail -n 5 <<<"$up_output" | tr '\n' ' ')"
fi

state_lines="$(stack_state_lines)"
for service in "${STACK_SERVICES[@]}"; do
  if grep -qx "$service running healthy" <<<"$state_lines"; then
    pass "${service} は running・healthy"
  else
    fail "${service} は running・healthy（実際: $(grep "^$service " <<<"$state_lines" | head -n 1)）"
  fi
done
expect_eq "サービスは 4 つだけ（db・backend・relay・frontend）" "backend db frontend relay" "$(awk '{print $1}' <<<"$state_lines" | sort | tr '\n' ' ' | sed 's/ $//')"

# --- 冪等: もう一度 up -d --wait を実行しても、コンテナを作り直さない ---
section "冪等: 起動済みの環境に up -d --wait を実行しても、作り直さない"
snapshot_containers() {
  local ids
  ids="$("$DC" ps -q 2>/dev/null)"
  [[ -n "$ids" ]] || return 1
  # shellcheck disable=SC2086
  docker inspect --format '{{.Name}} {{.Id}} {{.State.StartedAt}}' $ids | sort
}
before="$(snapshot_containers)"
"$DC" up -d --wait >/dev/null 2>&1
second_status=$?
after="$(snapshot_containers)"
expect_eq "2 回目の up -d --wait も成功する" "0" "$second_status"
if [[ -n "$before" && "$before" == "$after" ]]; then
  pass "2 回目の up -d --wait で、コンテナの ID・起動時刻が変わらない（作り直さない）"
else
  fail "2 回目の up -d --wait で、コンテナが作り直された、または取得できなかった"
fi

# --- 公開ポート ---
section "公開ポート（ホストへ公開するのは 3 つだけ）"
ps_json="$("$DC" ps --format json 2>/dev/null | jq -s '.')"
published="$(jq -r '[.[] | .Publishers[]? | select(.PublishedPort > 0) | "\(.PublishedPort)"] | unique | join(" ")' <<<"$ps_json")"
expected_published="$(printf '%s\n' "$FRONTEND_PORT" "$BACKEND_PORT" "$RELAY_PORT" | sort -n | tr '\n' ' ' | sed 's/ $//')"
expect_eq "ホストへ公開するポートは frontend・backend（公開側）・relay の 3 つだけ" "$expected_published" "$published"
expect_json "frontend は ${FRONTEND_PORT}、backend は ${BACKEND_PORT}（公開側）、relay は ${RELAY_PORT} を公開する" \
  "([.[] | select(.Service == \"frontend\") | .Publishers[]? | select(.PublishedPort > 0) | .PublishedPort] | unique == [${FRONTEND_PORT}])
   and ([.[] | select(.Service == \"backend\") | .Publishers[]? | select(.PublishedPort > 0) | .PublishedPort] | unique == [${BACKEND_PORT}])
   and ([.[] | select(.Service == \"relay\") | .Publishers[]? | select(.PublishedPort > 0) | .PublishedPort] | unique == [${RELAY_PORT}])" "$ps_json"
expect_json "backend の内部通信の口（${INTERNAL_PORT}）は、compose のネットワークの中だけ（ホストへ公開しない）" \
  "[.[] | select(.Service == \"backend\") | .Publishers[]? | select(.TargetPort == ${INTERNAL_PORT})] | all(.PublishedPort == 0)" "$ps_json"
expect_json "db（${DB_PORT}）は、ホストへ公開しない" \
  '[.[] | select(.Service == "db") | .Publishers[]? | select(.PublishedPort > 0)] | length == 0' "$ps_json"

finish
