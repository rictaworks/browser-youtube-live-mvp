#!/usr/bin/env bash
# backend（Rails）のテストと lint を、起動中のコンテナで実行する。緑なら 0、赤なら 0 以外を返す。
# 必要なサービス（db・backend）は、起動していなければ起動する。停止は scripts/dc.sh stop。
#
#   scripts/test_backend.sh                        全体: RSpec の全件と、RuboCop・Brakeman・bundler-audit
#   scripts/test_backend.sh spec/domain            絞り込み: RSpec のパス・オプションを、そのまま渡す。
#                                                  lint は、対象のパスだけ（RuboCop）。Brakeman・bundler-audit は行わない
#   scripts/test_backend.sh --no-db spec/domain    DB の準備を省く。Rails を使わない素の RSpec（spec_helper だけ）を速く回す
#   scripts/test_backend.sh --db spec/models       DB の準備を必ず行う
#                                                  （--db・--no-db が無ければ、対象のパスの配下に rails_helper を読むスペックがあるときだけ準備する）
#   TEST_DB_NAME=bl_test_issue5 scripts/test_backend.sh ...
#                                                  テスト用 DB の名前を変える（既定 bl_test）。無ければ作り、スキーマを読み込む。
#                                                  並行して作業するとき、作業ごとに名前を分ける。開発 DB（bl_development）は、決して使わない
#
# テストは RAILS_ENV=test と、テスト用 DB の DATABASE_URL を明示して実行する（開発 DB を壊さない）。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TEST_DB_NAME="${TEST_DB_NAME:-bl_test}"

# テスト用 DB の名前の規則（spec/support/test_environment_guard.rb と同じ）:
# 小文字・数字・アンダースコア（先頭は小文字、63 文字まで）で、test を 1 つの語として含む。bl_development は満たさない
if [[ ! "$TEST_DB_NAME" =~ ^[a-z][a-z0-9_]{0,62}$ ]] || [[ ! "$TEST_DB_NAME" =~ (^|_)test(_|$) ]]; then
  echo "test_backend.sh: TEST_DB_NAME=\"${TEST_DB_NAME}\" は、テスト用の DB 名として使えません。" >&2
  echo "test_backend.sh: 小文字・数字・アンダースコア（先頭は小文字、63 文字まで）で、test を 1 つの語として含む名前にしてください（例: bl_test、bl_test_issue5）。開発 DB（bl_development）は使えません。" >&2
  exit 2
fi

scripts/dc.sh up -d --wait db backend
exec scripts/dc.sh exec -T -e "TEST_DB_NAME=${TEST_DB_NAME}" backend bash /scripts/test_backend.sh "$@"
