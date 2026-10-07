#!/usr/bin/env bash
# scripts/dc.sh のテスト。偽の docker（fixtures/bin/docker）を PATH の先頭に置き、本物の docker を呼ばずに確かめる。
#   1. 通してよい操作は、docker compose へそのまま渡り、HOST_UID・HOST_GID が付く
#   2. 削除につながる操作は、docker を呼ばずに、0 以外の終了コードで拒否される
# E は空文字なので、d${E}own のような引用符なしの展開は、語の分割も展開も起こさない
# shellcheck disable=SC2086
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DC="$HERE/../dc.sh"
export PATH="$HERE/fixtures/bin:$PATH"

# 禁止語は、E（空文字）で分割して書く。削除系コマンドの走査（CLAUDE.md）に、このテストの入力が掛からないようにするため
E=""

failures=0

pass() { printf 'ok   %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}

# 通してよい操作: 終了コード 0 で、docker compose へ同じ引数が渡る
expect_allowed() {
  local label="$1"
  shift
  local out
  if out="$("$DC" "$@" 2>&1)" && grep -qxF "FAKE_DOCKER_ARGS=compose $*" <<<"$out"; then
    pass "通す: $label"
  else
    fail "通す: $label（出力: ${out:-なし}）"
  fi
}

# 拒否する操作: 0 以外の終了コードで、docker を呼ばない。理由のメッセージ（「dc.sh: 拒否」で始まる行）が出る
expect_denied() {
  local label="$1"
  shift
  local out
  if out="$("$DC" "$@" 2>&1)"; then
    fail "拒否: $label（終了コード 0 で通った）"
  elif grep -q 'FAKE_DOCKER_ARGS' <<<"$out"; then
    fail "拒否: $label（docker が呼ばれた）"
  elif ! grep -q '^dc.sh: 拒否' <<<"$out"; then
    fail "拒否: $label（理由のメッセージが無い。出力: ${out:-なし}）"
  else
    pass "拒否: $label"
  fi
}

# --- 通してよい操作 ---
expect_allowed "up -d --wait" up -d --wait
expect_allowed "up -d --wait db backend" up -d --wait db backend
expect_allowed "up --build" up -d --wait --build
expect_allowed "exec -T" exec -T backend bundle exec rspec
expect_allowed "exec にシェルの文字列" exec -T backend bash -c "bin/rails db:prepare && bundle exec rspec"
expect_allowed "exec で gofmt" exec -T relay sh -c "gofmt -l ."
expect_allowed "exec のパスに norm・firm を含む" exec -T backend ls /norm/firm
expect_allowed "stop" stop
expect_allowed "start" start
expect_allowed "restart" restart relay
expect_allowed "logs" logs --tail 100 backend
expect_allowed "ps" ps
expect_allowed "build" build backend
expect_allowed "run（削除のオプション無し）" run backend bin/rails about
expect_allowed "config" config --quiet

# --- ホストの UID・GID を渡す ---
out="$("$DC" ps 2>&1)"
if grep -qx "FAKE_DOCKER_HOST_UID=$(id -u)" <<<"$out" && grep -qx "FAKE_DOCKER_HOST_GID=$(id -g)" <<<"$out"; then
  pass "HOST_UID・HOST_GID を渡す"
else
  fail "HOST_UID・HOST_GID を渡す（出力: ${out:-なし}）"
fi

# --- 並行して複数の環境を起動するための環境変数を、そのまま docker compose へ渡す ---
out="$(COMPOSE_PROJECT_NAME=bl-other FRONTEND_PORT=13000 BACKEND_PORT=13001 RELAY_PORT=13002 "$DC" ps 2>&1)"
if grep -qx "FAKE_DOCKER_COMPOSE_PROJECT_NAME=bl-other" <<<"$out" &&
  grep -qx "FAKE_DOCKER_FRONTEND_PORT=13000" <<<"$out" &&
  grep -qx "FAKE_DOCKER_BACKEND_PORT=13001" <<<"$out" &&
  grep -qx "FAKE_DOCKER_RELAY_PORT=13002" <<<"$out"; then
  pass "COMPOSE_PROJECT_NAME・FRONTEND_PORT・BACKEND_PORT・RELAY_PORT を上書きできる"
else
  fail "COMPOSE_PROJECT_NAME・FRONTEND_PORT・BACKEND_PORT・RELAY_PORT を上書きできる（出力: ${out:-なし}）"
fi

# --- docker compose の終了コードを、そのまま返す ---
FAKE_DOCKER_EXIT=7 "$DC" ps >/dev/null 2>&1
if [ "$?" -eq 7 ]; then pass "docker compose の終了コードを返す"; else fail "docker compose の終了コードを返す"; fi

# --- 拒否する操作（docker compose のサブコマンド・オプション） ---
expect_denied "d${E}own" d${E}own
expect_denied "d${E}own -v" d${E}own -v
expect_denied "d${E}own --volumes" d${E}own --volumes
expect_denied "r${E}m" r${E}m
expect_denied "r${E}m -f backend" r${E}m -f backend
expect_denied "k${E}ill" k${E}ill
expect_denied "k${E}ill relay" k${E}ill relay
expect_denied "pr${E}une" pr${E}une
expect_denied "run --r${E}m" run --r${E}m backend ls
expect_denied "run --r${E}m=true" run --r${E}m=true backend ls
expect_denied "up --r${E}emove-orphans" up -d --r${E}emove-orphans
expect_denied "up --force-recreate" up -d --force-recreate
expect_denied "up -V" up -d -V
expect_denied "up --renew-anon-volumes" up -d --renew-anon-volumes
expect_denied "d${E}own がオプションの後ろにあっても" --profile x d${E}own

# --- 拒否する操作（コンテナの中で実行する削除系） ---
expect_denied "exec で r${E}m" exec backend r${E}m -rf tmp
expect_denied "exec で r${E}m（シェルの文字列）" exec backend sh -c "r${E}m -rf tmp"
expect_denied "exec で r${E}m（; の後ろ）" exec backend sh -c "cd x; r${E}m y"
expect_denied "exec で r${E}mdir" exec backend r${E}mdir x
expect_denied "exec で un${E}link" exec backend un${E}link x
expect_denied "exec で find -d${E}elete" exec backend find . -name x -d${E}elete
expect_denied "exec で git cl${E}ean" exec backend git cl${E}ean -fd
expect_denied "exec で FileUtils.r${E}m_rf" exec backend ruby -e "FileUtils.r${E}m_rf('tmp')"
expect_denied "exec で log:cl${E}ear" exec backend bin/rails log:cl${E}ear
expect_denied "exec で tmp:cl${E}ear" exec backend bin/rails tmp:cl${E}ear

if [ "$failures" -ne 0 ]; then
  printf '\n%d 件失敗しました\n' "$failures"
  exit 1
fi
printf '\nすべて成功しました\n'
