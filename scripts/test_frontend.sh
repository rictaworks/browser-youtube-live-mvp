#!/usr/bin/env bash
# frontend（Next.js）の lint・型検査・テストを、起動中のコンテナで実行する。緑なら 0、赤なら 0 以外を返す。
# 必要なサービス（frontend）は、起動していなければ起動する。停止は scripts/dc.sh stop。
#
#   scripts/test_frontend.sh                    全体: ESLint・tsc --noEmit（next typegen を含む）・Jest の全件
#   scripts/test_frontend.sh core/contract      絞り込み: Jest の引数（テストのパスの正規表現・オプション）を、そのまま渡す。
#                                               lint は、対象のパスだけ（eslint <パス>）。型検査は、プロジェクト全体の検査なので行わない
#
# 本番ビルドの確認: scripts/dc.sh exec -T frontend npm run build
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

scripts/dc.sh up -d --wait frontend
exec scripts/dc.sh exec -T frontend bash /scripts/test_frontend.sh "$@"
