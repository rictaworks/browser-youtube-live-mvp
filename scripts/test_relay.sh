#!/usr/bin/env bash
# relay（Gin）の gofmt・go vet・go test を、起動中のコンテナで実行する。緑なら 0、赤なら 0 以外を返す。
# 必要なサービス（relay）は、起動していなければ起動する。停止は scripts/dc.sh stop。
#
#   scripts/test_relay.sh                  全体: gofmt の差分なし・go vet ./...・go test ./...
#   scripts/test_relay.sh ./core/...       絞り込み: go test の引数（パッケージ・オプション）を、そのまま渡す。
#                                          lint は、対象のパッケージだけ（gofmt -l <パス>・go vet <パッケージ>）
#   scripts/test_relay.sh -run TestX -v    パッケージの指定が無ければ ./... を対象にする
#
# 本番用イメージのビルドの確認: docker build --target production src/relay
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

scripts/dc.sh up -d --wait relay
exec scripts/dc.sh exec -T relay bash /scripts/test_relay.sh "$@"
