#!/usr/bin/env bash
# scripts/test_backend.sh・test_frontend.sh・test_relay.sh（ホスト側のスクリプト）のテスト。
# 偽の docker（fixtures/bin/docker）を PATH の先頭に置き、本物の docker を呼ばずに、次を確かめる。
#   1. 必要なサービスを up -d --wait してから、コンテナの中のスクリプト（/scripts/...）を exec で実行する
#   2. 引数を、そのままコンテナの中のスクリプトへ渡す（テスト対象を絞れる）
#   3. backend は、TEST_DB_NAME（既定 bl_test）をコンテナへ渡す。テスト用ではない名前（開発 DB など）は、docker を呼ばずに拒否する
#   4. 失敗の終了コードを返す
# コンテナの中のスクリプトの動作は、実際のコンテナで確かめる（README.md のテストの節）。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$HERE/.."
export PATH="$HERE/fixtures/bin:$PATH"

# 環境変数が、テストの結果に影響しないようにする
unset TEST_DB_NAME FAKE_DOCKER_EXIT

failures=0

pass() { printf 'ok   %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}

# 実行して、出力された docker compose の呼び出し（FAKE_DOCKER_ARGS= の行）を、順に返す
docker_calls() {
  "$@" 2>&1 | grep '^FAKE_DOCKER_ARGS=' | sed 's/^FAKE_DOCKER_ARGS=//'
}

expect_calls() {
  local label="$1" expected="$2"
  shift 2
  local actual
  actual="$(docker_calls "$@")"
  if [ "$actual" = "$expected" ]; then pass "$label"; else fail "$label（期待: $expected / 実際: $actual）"; fi
}

# --- backend ---
expect_calls "backend: 引数なし" \
  $'compose up -d --wait db backend\ncompose exec -T -e TEST_DB_NAME=bl_test backend bash /scripts/test_backend.sh' \
  "$SCRIPTS/test_backend.sh"

expect_calls "backend: RSpec のパスを渡せる" \
  $'compose up -d --wait db backend\ncompose exec -T -e TEST_DB_NAME=bl_test backend bash /scripts/test_backend.sh spec/domain' \
  "$SCRIPTS/test_backend.sh" spec/domain

expect_calls "backend: RSpec のオプションを渡せる" \
  $'compose up -d --wait db backend\ncompose exec -T -e TEST_DB_NAME=bl_test backend bash /scripts/test_backend.sh --no-db spec/domain --tag focus -e some_name' \
  "$SCRIPTS/test_backend.sh" --no-db spec/domain --tag focus -e some_name

expect_calls "backend: 引数の空白を保つ" \
  $'compose up -d --wait db backend\ncompose exec -T -e TEST_DB_NAME=bl_test backend bash /scripts/test_backend.sh -e two words' \
  "$SCRIPTS/test_backend.sh" -e "two words"

out="$(TEST_DB_NAME=bl_test_issue5 "$SCRIPTS/test_backend.sh" spec/domain 2>&1)"
if grep -qx 'FAKE_DOCKER_ARGS=compose exec -T -e TEST_DB_NAME=bl_test_issue5 backend bash /scripts/test_backend.sh spec/domain' <<<"$out"; then
  pass "backend: TEST_DB_NAME でテスト用 DB の名前を変えられる"
else
  fail "backend: TEST_DB_NAME でテスト用 DB の名前を変えられる（出力: $out）"
fi

out="$(TEST_DB_NAME='' "$SCRIPTS/test_backend.sh" 2>&1)"
if grep -qx 'FAKE_DOCKER_ARGS=compose exec -T -e TEST_DB_NAME=bl_test backend bash /scripts/test_backend.sh' <<<"$out"; then
  pass "backend: TEST_DB_NAME が空なら既定の bl_test"
else
  fail "backend: TEST_DB_NAME が空なら既定の bl_test（出力: $out）"
fi

# テスト用ではない名前は、docker を呼ばずに拒否する（開発 DB を、決して使わない）
for name in bl_development postgres template1 bl_production bl_testing BL_TEST bl-test 'bl_test;x' '1_test' "$(printf 'a%.0s' {1..60})_test"; do
  out="$(TEST_DB_NAME="$name" "$SCRIPTS/test_backend.sh" 2>&1)"
  status=$?
  if [ "$status" -eq 2 ] && grep -q 'TEST_DB_NAME' <<<"$out" && ! grep -q 'FAKE_DOCKER_ARGS' <<<"$out"; then
    pass "backend: テスト用ではない名前 ${name:0:24} は、docker を呼ばずに拒否する"
  else
    fail "backend: テスト用ではない名前 ${name:0:24} は拒否する（終了コード $status。出力: $out）"
  fi
done

FAKE_DOCKER_EXIT=3 "$SCRIPTS/test_backend.sh" >/dev/null 2>&1
if [ "$?" -eq 3 ]; then pass "backend: 失敗の終了コードを返す"; else fail "backend: 失敗の終了コードを返す"; fi

# --- frontend ---
expect_calls "frontend: 引数なし" \
  $'compose up -d --wait frontend\ncompose exec -T frontend bash /scripts/test_frontend.sh' \
  "$SCRIPTS/test_frontend.sh"

expect_calls "frontend: テスト対象を絞れる" \
  $'compose up -d --wait frontend\ncompose exec -T frontend bash /scripts/test_frontend.sh core/contract' \
  "$SCRIPTS/test_frontend.sh" core/contract

FAKE_DOCKER_EXIT=4 "$SCRIPTS/test_frontend.sh" >/dev/null 2>&1
if [ "$?" -eq 4 ]; then pass "frontend: 失敗の終了コードを返す"; else fail "frontend: 失敗の終了コードを返す"; fi

# --- relay ---
expect_calls "relay: 引数なし" \
  $'compose up -d --wait relay\ncompose exec -T relay bash /scripts/test_relay.sh' \
  "$SCRIPTS/test_relay.sh"

expect_calls "relay: テスト対象を絞れる" \
  $'compose up -d --wait relay\ncompose exec -T relay bash /scripts/test_relay.sh ./core/...' \
  "$SCRIPTS/test_relay.sh" ./core/...

FAKE_DOCKER_EXIT=5 "$SCRIPTS/test_relay.sh" >/dev/null 2>&1
if [ "$?" -eq 5 ]; then pass "relay: 失敗の終了コードを返す"; else fail "relay: 失敗の終了コードを返す"; fi

if [ "$failures" -ne 0 ]; then
  printf '\n%d 件失敗しました\n' "$failures"
  exit 1
fi
printf '\nすべて成功しました\n'
