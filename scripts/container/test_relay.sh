#!/usr/bin/env bash
# relay コンテナの中で実行する（docker-compose.yml が /scripts へ読み取り専用でマウントする）。
# ホストからは scripts/test_relay.sh を使う。使い方は、そちらの冒頭を参照。

# check_gofmt・go_files は、step 経由（間接）で呼ばれる
# shellcheck disable=SC2317
set -euo pipefail
cd /app

# テストは test モードで実行する（環境の判定は GIN_MODE。debug→development・test→test・release→production）
export GIN_MODE=test

# 絞り込みのパッケージ: ./ や ../ で始まる引数、または存在するパス（./core/... の /... は除いて調べる）
packages=()
for arg in "$@"; do
  [[ "$arg" == -* ]] && continue
  dir="${arg%/...}"
  if [[ "$arg" == ./* || "$arg" == ../* || "$arg" == "..." || -e "$dir" ]]; then
    packages+=("$arg")
  fi
done

test_args=("$@")
vet_targets=("${packages[@]}")
fmt_targets=()
if [[ "${#packages[@]}" -eq 0 ]]; then
  test_args+=("./...")
  vet_targets=("./...")
  fmt_targets=(".")
else
  for package in "${packages[@]}"; do
    dir="${package%/...}"
    [[ "$dir" == "..." ]] && dir="."
    fmt_targets+=("$dir")
  done
fi

# gofmt の対象の Go ファイル（キャッシュの置き場 .cache は除く）
go_files() {
  local target
  for target in "$@"; do
    if [[ -f "$target" ]]; then
      echo "$target"
    else
      find "$target" -name '*.go' -not -path './.cache/*'
    fi
  done
}

check_gofmt() {
  local unformatted
  unformatted="$(go_files "${fmt_targets[@]}" | xargs --no-run-if-empty gofmt -l)"
  if [[ -n "$unformatted" ]]; then
    echo "gofmt の差分があります（gofmt -w で整えてください）:"
    echo "$unformatted"
    return 1
  fi
}

status=0
step() {
  echo
  echo "== $*"
  "$@" || status=1
}

step check_gofmt
step go vet "${vet_targets[@]}"
step go test "${test_args[@]}"

echo
if [[ "$status" -eq 0 ]]; then
  echo "== 成功しました"
else
  echo "== 失敗があります"
fi
exit "$status"
