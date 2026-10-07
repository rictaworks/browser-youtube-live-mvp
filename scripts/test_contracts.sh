#!/usr/bin/env bash
# 契約（src/contracts）のテストを、起動中のコンテナで実行する。緑なら 0、赤なら 0 以外を返す。
# Node 22 の標準のテストランナー（node --test）だけを使う。依存パッケージはない。
# 必要なサービス（frontend。Node が入っているコンテナ）は、起動していなければ起動する。停止は scripts/dc.sh stop。
#
#   scripts/test_contracts.sh                       契約の全テスト（src/contracts/test/*.test.mjs）
#   scripts/test_contracts.sh --test-name-pattern 拒否理由
#                                                   node --test のオプションを、そのまま渡せる（テスト名の絞り込みなど）
#
# src/contracts は、コンテナの /contracts へ読み取り専用でマウントされる（docker-compose.yml）。テストは、
# /contracts・../contracts・../../contracts・テストの隣の順に契約のディレクトリを探し、見つからなければ、
# 探した場所を並べて失敗する（黙ってスキップしない）。
#
# 3 層の定数モジュール（契約の JSON との一致）のテストは、それぞれの層のスクリプトで実行する:
#   scripts/test_backend.sh --no-db spec/domain/contract
#   scripts/test_frontend.sh core/contract
#   scripts/test_relay.sh ./core/contract/...
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

scripts/dc.sh up -d --wait frontend
# テストのファイルは、コンテナの中のシェルに展開させる。1 つも見つからなければ、パターンのまま node へ渡り、失敗する
exec scripts/dc.sh exec -T frontend sh -c 'exec node --test "$@" /contracts/test/*.test.mjs' sh "$@"
