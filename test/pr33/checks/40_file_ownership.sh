#!/usr/bin/env bash
# pr33-timeout: 300
# コンテナ内で作られたファイルの所有者（issue #1「所有者と安全」: root 所有のファイルを作らない）。
# コンテナは、ホストの UID・GID で動く（docker-compose.yml の user）。コンテナが作った依存パッケージ・ビルド・ログ・キャッシュが、
# ホストのユーザー所有であり、ホストのユーザーが（手動で）後始末できることを確かめる。
#
#   - find src scripts test（node_modules・vendor・.cache・.next を含む）に、ホストの UID・GID 以外のものが無い
#   - 確認の対象（コンテナが作ったファイル）が、実際に存在する（空振りで成功しない）
#   - すべてのディレクトリに、所有者の書き込み・検索の権限がある（Go のモジュールキャッシュは、既定で読み取り専用になる。-modcacherw で防ぐ）
#   - 特権ビット（setuid・setgid）・誰でも書き込める権限を持つファイルを作らない
set -uo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_tools find stat wc head

cd "$ROOT_DIR" || abort "リポジトリのディレクトリへ移れません"

# --- コンテナが作ったファイルが、実際にある（空振りでないこと） ---
section "コンテナが作ったファイルが、実際にある（確認の対象）"
container_made=(
  "src/frontend/node_modules:100"
  "src/frontend/.next:10"
  "src/backend/vendor/bundle:100"
  "src/backend/.cache:1"
  "src/backend/log:1"
  "src/relay/.cache:100"
)
for entry in "${container_made[@]}"; do
  tree="${entry%%:*}"
  minimum="${entry##*:}"
  count="$(find "$tree" -type f 2>/dev/null | wc -l)"
  if [[ "$count" -ge "$minimum" ]]; then
    pass "${tree}: ${count} ファイルがある（確認の対象。${minimum} 以上）"
  else
    fail "${tree}: コンテナが作ったファイルが少ない（${count} ファイル。${minimum} 以上のはず。開発サーバーを起動したか確認してください）"
  fi
done
if [[ -x src/relay/.cache/bin/relay ]]; then pass "src/relay/.cache/bin/relay（relay の開発用バイナリ）がある"; else fail "src/relay/.cache/bin/relay（relay の開発用バイナリ）がある"; fi
if [[ -f src/backend/log/development.log ]]; then pass "src/backend/log/development.log（Rails のログ）がある"; else fail "src/backend/log/development.log（Rails のログ）がある"; fi

# --- 所有者 ---
section "所有者は、ホストのユーザー（UID ${HOST_UID}・GID ${HOST_GID}）だけ"
foreign="$(find src scripts test -not -user "$(id -un)" -print 2>/dev/null | head -n 20)"
foreign_ids="$(find src scripts test \( ! -uid "$HOST_UID" -o ! -gid "$HOST_GID" \) -print 2>/dev/null | head -n 20)"
total_files="$(find src scripts test 2>/dev/null | wc -l)"
if [[ -z "$foreign" && -z "$foreign_ids" ]]; then
  pass "find src scripts test（node_modules・vendor・.cache・.next を含む ${total_files} 件）に、ホストのユーザー・グループ以外の所有は無い"
else
  fail "ホストのユーザー・グループ以外が所有するファイルがある（先頭 20 件）: $(oneline "${foreign_ids:-$foreign}")"
fi
for tree in src/frontend/node_modules src/frontend/.next src/backend/vendor/bundle src/backend/.cache src/backend/log src/relay/.cache; do
  other="$(find "$tree" \( ! -uid "$HOST_UID" -o ! -gid "$HOST_GID" \) 2>/dev/null | wc -l)"
  expect_eq "${tree}: ホストのユーザー・グループ以外の所有が 0 件" "0" "$other"
done
root_level="$(find . -maxdepth 1 \( ! -uid "$HOST_UID" -o ! -gid "$HOST_GID" \) -print 2>/dev/null | head -n 10)"
expect_eq "リポジトリ直下（docker-compose.yml・README.md・.env・.env.example・.gitignore を含む）に、ホストのユーザー・グループ以外の所有が無い" "" "$(oneline "$root_level")"
bind_dirs=("src/contracts" "scripts/container" "src/backend" "src/relay" "src/frontend")
for dir in "${bind_dirs[@]}"; do
  expect_eq "bind マウントの元 ${dir}: 所有者は ${HOST_UID}:${HOST_GID}（Docker が root 所有で作っていない）" "${HOST_UID}:${HOST_GID}" "$(stat -c '%u:%g' "$dir")"
done

# --- 権限 ---
section "権限（後始末ができる・特権を持たない）"
unwritable_dirs="$(find src scripts test -type d ! -perm -u+w 2>/dev/null | wc -l)"
expect_eq "すべてのディレクトリに、所有者の書き込み権限がある（Go のモジュールキャッシュが読み取り専用になっていない）" "0" "$unwritable_dirs"
unsearchable_dirs="$(find src scripts test -type d ! -perm -u+x 2>/dev/null | wc -l)"
expect_eq "すべてのディレクトリに、所有者の検索（x）権限がある" "0" "$unsearchable_dirs"
privileged="$(find src scripts -type f \( -perm -4000 -o -perm -2000 \) -print 2>/dev/null | head -n 10)"
expect_eq "setuid・setgid のファイルが無い" "" "$(oneline "$privileged")"
world_writable="$(find src scripts -type f -perm -0002 -print 2>/dev/null | head -n 10)"
expect_eq "誰でも書き込めるファイルが無い" "" "$(oneline "$world_writable")"
if [[ "$(find src/frontend/node_modules src/backend/vendor/bundle src/relay/.cache -type l 2>/dev/null | head -n 1)" != "" ]]; then
  broken_links="$(find src/frontend/node_modules/.bin -xtype l 2>/dev/null | head -n 5)"
  expect_eq "node_modules/.bin のシンボリックリンクが、壊れていない（コンテナの中のパスを指していない）" "" "$(oneline "$broken_links")"
fi

finish
