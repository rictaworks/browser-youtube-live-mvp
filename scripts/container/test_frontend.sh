#!/usr/bin/env bash
# frontend コンテナの中で実行する（docker-compose.yml が /scripts へ読み取り専用でマウントする）。
# ホストからは scripts/test_frontend.sh を使う。使い方は、そちらの冒頭を参照。
#
# 依存（node_modules）は、コンテナの起動時に npm install される。package.json を変えたあとは、
# scripts/dc.sh restart frontend（または scripts/dc.sh exec -T frontend npm install）で取り込む。
set -euo pipefail
cd /app

# 絞り込みのパス: 存在するファイル・ディレクトリの引数（Jest の引数のうち、パスとして使えるもの）
paths=()
for arg in "$@"; do
  [[ "$arg" == -* ]] && continue
  [[ -e "$arg" ]] && paths+=("$arg")
done

status=0
step() {
  echo
  echo "== $*"
  "$@" || status=1
}

if [[ "$#" -eq 0 ]]; then
  step npm run lint
  step npm run typecheck
  step npm test -- --ci
else
  if [[ "${#paths[@]}" -gt 0 ]]; then
    step npx eslint "${paths[@]}"
  else
    step npm run lint
  fi
  step npm test -- --ci "$@"
fi

echo
if [[ "$status" -eq 0 ]]; then
  echo "== 成功しました"
else
  echo "== 失敗があります"
fi
exit "$status"
