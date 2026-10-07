#!/usr/bin/env bash
# 削除系コマンドの走査（CLAUDE.md「削除系コマンドの禁止」）。common.sh を読み込んだあとに source する。
#
# 「実行される位置にある削除系コマンド」だけを検出する。次のものは、検出しない（実行されないため）。
#   - コメント（行全体が #・//・* で始まる行）
#   - scripts/dc.sh の拒否の一覧（配列・正規表現の文字列。コマンドの位置にない）
#   - 文書（README.md）の本文中の説明（コードブロックの中だけを走査する）
#
# 検出の対象:
#   シェル・Dockerfile・compose の command・文書のコードブロック（scan_deletion_in_shell）
#     1. コマンドの位置（行頭・; & | ( ` $( の直後・then do exec sudo xargs env command time nohup -exec RUN CMD の直後・YAML の - の直後）にある
#        削除系コマンド（絶対パス /bin/…・/usr/bin/… を含む）
#     2. docker の削除系のサブコマンド（down・rm・rmi・kill・prune・system prune など）と、docker・dc.sh の呼び出しに付いた --rm・
#        --remove-orphans・--force-recreate・--renew-anon-volumes
#     3. apt-get clean・autoclean・autoremove
#     4. find の -delete・git clean・rsync の --delete
#     5. Rails の log:clear・tmp:clear・assets:clobber
#   各言語のコード（scan_deletion_in_code）
#     FileUtils.rm*・File.delete・Dir.rmdir・Pathname の rmtree・fs.rm*・os.Remove*・rimraf・shutil.rmtree
#
# このファイルのソースに、削除系コマンドの語をそのまま書かないため、common.sh の W_* から正規表現を組み立てる。

_DEL_CMDS="(${W_RM}|${W_RMDIR}|${W_UNLINK}|${W_SHRED})"
_DEL_PATH="((/usr)?/s?bin/)?"
# コマンドの終端: 空白・行末・; &。| と ) は含めない（scripts/dc.sh の拒否の一覧にある正規表現「(…|…)」を、コマンドと誤認しないため）
_DEL_BOUNDARY="([[:space:]]|\$|;|&)"
# コマンドの位置
_DEL_POS="(^|[;&|(\`]|\\\$\\(|[[:space:]](then|do|exec|sudo|xargs|env|command|time|nohup|-exec|RUN|CMD|ENTRYPOINT)[[:space:]]|^[[:space:]]*(RUN|CMD|ENTRYPOINT)[[:space:]]|^[[:space:]]*-[[:space:]]+)"

DEL_RE_COMMAND="${_DEL_POS}[[:space:]]*${_DEL_PATH}${_DEL_CMDS}${_DEL_BOUNDARY}"
# exec 形式・YAML の配列: ["rm", ...]・- rm
DEL_RE_ARRAY="\\[[[:space:]]*[\"']${_DEL_PATH}${_DEL_CMDS}[\"']"
DEL_RE_DOCKER="docker(-compose)?[[:space:]]+(compose[[:space:]]+)?(${W_DOWN}|${W_RM}|rmi|${W_KILL}|${W_PRUNE})([[:space:]]|\$)"
DEL_RE_DOCKER_SYSTEM="docker[[:space:]]+(system|volume|network|image|container|builder|compose)[[:space:]]+(${W_PRUNE}|${W_RM})([[:space:]]|\$)"
DEL_RE_DOCKER_FLAG="(docker|dc\\.sh)[^#]*[[:space:]]--(${W_RM}|remove-orphans|force-recreate|renew-anon-volumes)([[:space:]=]|\$)"
DEL_RE_APT="apt(-get)?[[:space:]]+(${W_CLEAN}|auto${W_CLEAN}|autoremove)([[:space:]]|\$)"
DEL_RE_FIND="find[^#]*[[:space:]]-${W_DELETE}([[:space:]]|\$)|git[[:space:]]+${W_CLEAN}([[:space:]]|\$)|rsync[^#]*--${W_DELETE}"
DEL_RE_RAILS="(log|tmp):${W_CLEAR}|assets:clobber"
DEL_RE_CODE="FileUtils\\.(${W_RM}|remove)|File\\.(${W_DELETE}|${W_UNLINK})|Dir\\.(${W_RMDIR}|${W_DELETE}|${W_UNLINK})|Pathname[^#]*\\.(${W_RM}tree|${W_UNLINK})|(^|[^[:alnum:]_])fs\\.(${W_RM}|${W_RM}Sync|${W_RMDIR}|${W_UNLINK})|(^|[^[:alnum:]_])os\\.Remove|${W_RIMRAF}|shutil\\.${W_RM}tree"

# 行全体がコメントの行を除いて出す（行番号を保つため、コメントの行は空にする）
_strip_comment_lines() {
  sed -E 's/^[[:space:]]*(#|\/\/|\/\*|\*([[:space:]]|$)).*$//'
}

# scan_deletion_in_shell <ファイル...>: 「ファイル:行番号: 内容」を、違反ごとに 1 行出す。違反が無ければ何も出さない
scan_deletion_in_shell() {
  local file
  for file in "$@"; do
    [[ -f "$file" ]] || continue
    _strip_comment_lines <"$file" | grep -nE -e "$DEL_RE_COMMAND" -e "$DEL_RE_ARRAY" -e "$DEL_RE_DOCKER" -e "$DEL_RE_DOCKER_SYSTEM" \
      -e "$DEL_RE_DOCKER_FLAG" -e "$DEL_RE_APT" -e "$DEL_RE_FIND" -e "$DEL_RE_RAILS" | sed "s|^|${file}:|" | cut -c1-200
  done
}

# scan_deletion_in_code <ファイル...>: Ruby・TypeScript・Go のコードの、削除系の呼び出し
scan_deletion_in_code() {
  local file
  for file in "$@"; do
    [[ -f "$file" ]] || continue
    _strip_comment_lines <"$file" | grep -nE "$DEL_RE_CODE" | sed "s|^|${file}:|" | cut -c1-200
  done
}

# scan_deletion_in_markdown <ファイル...>: コードブロック（```）の中だけを、シェルとして走査する
scan_deletion_in_markdown() {
  local file
  for file in "$@"; do
    [[ -f "$file" ]] || continue
    # コードブロックの中の行だけを残す（それ以外は空行にして、行番号を保つ）
    awk 'BEGIN { in_code = 0 } /^```/ { in_code = !in_code; print ""; next } { if (in_code) print; else print "" }' "$file" |
      _strip_comment_lines | grep -nE -e "$DEL_RE_COMMAND" -e "$DEL_RE_ARRAY" -e "$DEL_RE_DOCKER" -e "$DEL_RE_DOCKER_SYSTEM" \
        -e "$DEL_RE_DOCKER_FLAG" -e "$DEL_RE_APT" -e "$DEL_RE_FIND" -e "$DEL_RE_RAILS" | sed "s|^|${file}:|" | cut -c1-200
  done
}
