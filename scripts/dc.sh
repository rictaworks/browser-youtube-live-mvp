#!/usr/bin/env bash
# docker compose の薄いラッパー。開発環境の docker compose は、必ずこのスクリプトを経由して呼ぶ。
#
#   1. ホストの UID・GID を HOST_UID・HOST_GID として渡す。
#      コンテナはこの UID・GID で動くため、コンテナが作るファイル（依存パッケージ・ビルド・ログ）の所有者は
#      ホストのユーザーになる（root 所有のファイルを作らない）。
#   2. 削除につながる操作を拒否する（CLAUDE.md「削除系コマンドの禁止」）。
#      コンテナは stop で止める。コンテナ・ボリューム・イメージの削除が必要な場合は、手動で行う。
#
# 使い方の例:
#   scripts/dc.sh up -d --wait          # 4 サービスを起動し、healthy になるまで待つ
#   scripts/dc.sh exec -T backend ...   # 起動中のコンテナで実行する（run は使わない）
#   scripts/dc.sh stop                  # 止める
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- 拒否する操作 ---
# docker compose のサブコマンド・オプション（引数と完全に一致したものを拒否する）
readonly DENIED_TOKENS=(
  down rm kill prune
  --rm --remove-orphans --force-recreate --renew-anon-volumes --volumes -V
)
# コンテナの中で実行する削除系（exec・run に渡した引数をつなげた文字列に、含まれていれば拒否する）
readonly DENIED_PATTERNS=(
  # 先頭側は「/」を除外しない（/bin/rm・/usr/bin/rm のような絶対パスの指定も拒否するため）。
  # 末尾側は「. / - _」と英数字を除外する（rm.md・rm_foo のような名前を誤って拒否しないため）
  '(^|[^[:alnum:]_.-])(rm|rmdir|unlink|shred)([^[:alnum:]_./-]|$)'
  '(^|[[:space:]])-delete([[:space:]]|$)'
  'git[[:space:]]+clean'
  '(FileUtils|File|Dir)\.(rm|rm_r|rm_rf|rm_f|remove|remove_entry|delete|unlink|rmdir)'
  '(fs|os)\.(rm|rmSync|rmdir|rmdirSync|unlink|unlinkSync|Remove|RemoveAll)'
  '(log|tmp):clear'
)

deny() {
  echo "dc.sh: 拒否しました。$1" >&2
  echo "dc.sh: 削除系の操作は行いません（CLAUDE.md）。コンテナを止めるときは stop を使います。削除が必要な場合は、手動で行ってください。" >&2
  exit 2
}

check_denied_tokens() {
  local arg denied
  for arg in "$@"; do
    for denied in "${DENIED_TOKENS[@]}"; do
      if [[ "$arg" == "$denied" ]]; then
        deny "削除につながる操作です: ${arg}"
      fi
    done
    case "$arg" in
      --rm=* | --volumes=*)
        deny "削除につながるオプションです: ${arg}"
        ;;
    esac
  done
}

check_denied_patterns() {
  local joined="$*"
  local pattern
  for pattern in "${DENIED_PATTERNS[@]}"; do
    if [[ "$joined" =~ $pattern ]]; then
      deny "コンテナの中で削除系のコマンドを実行する指定です: ${BASH_REMATCH[0]}"
    fi
  done
}

check_denied_tokens "$@"
check_denied_patterns "$@"

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
if [[ "$HOST_UID" -eq 0 ]]; then
  echo "dc.sh: root では実行できません。コンテナが root 所有のファイルを作るためです。ホストの一般ユーザーで実行してください。" >&2
  exit 2
fi
export HOST_UID HOST_GID

cd "$ROOT_DIR"
exec docker compose "$@"
