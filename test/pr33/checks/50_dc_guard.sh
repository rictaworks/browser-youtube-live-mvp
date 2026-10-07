#!/usr/bin/env bash
# pr33-timeout: 600
# scripts/dc.sh が、削除につながる操作を拒否することの確認（受け入れテスト。CLAUDE.md「削除系コマンドの禁止」）。
#   - 拒否する操作は、終了コード 2 で、docker を呼ばずに（コンテナを触らずに）拒否される
#   - 通してよい操作（止める・見る・実行する）は、誤って拒否されない。docker の終了コードがそのまま返る
#   - root では実行できない（コンテナが root 所有のファイルを作るため）
#   - 拒否の前後で、実際の開発サーバーのコンテナ（ID・起動時刻・状態）が変わらない
#
# 安全のため、拒否の確認は、すべて偽の docker（fixtures/spy_bin/docker。呼ばれたことを記録して失敗する）を PATH の先頭に置いて行う。
# 本物の docker・開発サーバーへ、削除系の操作を渡さない（拒否が働かなかった場合も、何も削除されない）。
# 実装担当の単体テスト（scripts/tests/test_dc.sh）が、拒否の一覧の各項目を確かめる。ここでは、
#   (1) 呼び出しの記録（ファイル）で「docker を呼ばなかった」ことを確かめる  (2) 実際の開発サーバーが無傷なことを確かめる
#   (3) 絶対パス・別の道具・語を含む無害な引数など、境界の書き方を確かめる
# 削除系コマンドの語は、このテストのソースにそのまま書かない（lib/common.sh の W_* から組み立てる）。
set -uo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_tools docker jq grep wc tail
SPY_DIR="$PR33_DIR/fixtures/spy_bin"
ROOT_DIR_FAKE="$PR33_DIR/fixtures/root_bin"
[[ -x "$SPY_DIR/docker" && -x "$ROOT_DIR_FAKE/id" ]] || abort "fixtures の偽の docker・id が実行できません"
require_stack_healthy

work="$(new_tmpdir dcguard)"
SPY_LOG="$work/spy.log"
: >"$SPY_LOG"

# 実際の開発サーバーのコンテナの状態（名前・ID・状態・起動時刻）
snapshot_stack() {
  local ids
  ids="$("$DC" ps -q 2>/dev/null)"
  [[ -n "$ids" ]] || return 1
  # shellcheck disable=SC2086
  docker inspect --format '{{.Name}} {{.Id}} {{.State.Status}} {{.State.StartedAt}}' $ids | sort
}
stack_before="$(snapshot_stack)"
volumes_before="$(docker volume ls --format '{{.Name}}' | grep -c '_db_data$' || true)"

# run_dc <dc.sh への引数...>: 偽の docker を PATH の先頭に置いて、scripts/dc.sh を実行する。
# 終了コードを DC_STATUS、出力を DC_OUT、偽の docker が呼ばれた回数と内容を DC_CALLS・DC_CALL_LINES へ入れる
DC_OUT=""
DC_STATUS=0
DC_CALLS=0
DC_CALL_LINES=""
run_dc() {
  local before after
  before="$(wc -l <"$SPY_LOG")"
  DC_OUT="$(PATH="$SPY_DIR:$PATH" PR33_SPY_LOG="$SPY_LOG" "$DC" "$@" 2>&1)"
  DC_STATUS=$?
  after="$(wc -l <"$SPY_LOG")"
  DC_CALLS=$((after - before))
  DC_CALL_LINES="$(tail -n +$((before + 1)) "$SPY_LOG")"
}

# 拒否する: 終了コード 2・docker を呼ばない・理由のメッセージ（「dc.sh: 拒否」で始まる行）
expect_denied() {
  local label="$1"
  shift
  run_dc "$@"
  if [[ "$DC_STATUS" -eq 2 && "$DC_CALLS" -eq 0 ]] && grep -q '^dc.sh: 拒否' <<<"$DC_OUT"; then
    pass "拒否: ${label}"
  else
    fail "拒否: ${label}（終了コード ${DC_STATUS}。docker の呼び出し ${DC_CALLS} 回。出力: $(head -c 100 <<<"$DC_OUT" | tr '\n' ' ')）"
  fi
}

# 通す: docker compose へ同じ引数が渡り、docker の終了コード（偽の docker は 97）がそのまま返る
expect_allowed() {
  local label="$1"
  shift
  run_dc "$@"
  if [[ "$DC_STATUS" -eq 97 && "$DC_CALLS" -eq 1 && "$DC_CALL_LINES" == "compose $*" ]]; then
    pass "通す: ${label}"
  else
    fail "通す: ${label}（終了コード ${DC_STATUS}。docker の呼び出し ${DC_CALLS} 回: ${DC_CALL_LINES:-なし}。出力: $(head -c 100 <<<"$DC_OUT" | tr '\n' ' ')）"
  fi
}

# --- 拒否する: docker compose のサブコマンド・オプション ---
section "拒否する: docker compose の、削除につながるサブコマンド・オプション"
expect_denied "${W_DOWN}（コンテナ・ネットワークの削除）" "$W_DOWN"
expect_denied "${W_DOWN} -v" "$W_DOWN" -v
expect_denied "${W_DOWN} --volumes（データのボリュームの削除）" "$W_DOWN" --volumes
expect_denied "${W_DOWN} --rmi all（イメージの削除）" "$W_DOWN" --rmi all
expect_denied "${W_RM}（停止したコンテナの削除）" "$W_RM"
expect_denied "${W_RM} -sf db" "$W_RM" -sf db
expect_denied "${W_KILL}" "$W_KILL"
expect_denied "${W_KILL} relay" "$W_KILL" relay
expect_denied "${W_PRUNE}" "$W_PRUNE"
expect_denied "run --${W_RM}（実行後にコンテナを削除する）" run "--${W_RM}" backend true
expect_denied "run --${W_RM}=true" run "--${W_RM}=true" backend true
expect_denied "up --remove-orphans（孤立したコンテナの削除）" up -d --remove-orphans
expect_denied "up --force-recreate（コンテナを作り直す = 削除して作る）" up -d --force-recreate
expect_denied "up -V（匿名ボリュームを作り直す）" up -d -V
expect_denied "up --renew-anon-volumes" up -d --renew-anon-volumes
expect_denied "create --force-recreate" create --force-recreate
expect_denied "${W_DOWN} が、オプションの後ろにあっても（--profile x）" --profile x "$W_DOWN"
expect_denied "${W_DOWN} が、-f の後ろにあっても" -f docker-compose.yml "$W_DOWN"
expect_denied "${W_RM} が、--project-name の後ろにあっても" --project-name x "$W_RM"
expect_denied "${W_DOWN} を、サービス名のあとに書いても" up -d backend "$W_DOWN"

# --- 拒否する: コンテナの中で実行する削除系 ---
section "拒否する: exec に渡した、コンテナの中の削除系コマンド"
expect_denied "exec で ${W_RM} -rf" exec -T backend "$W_RM" -rf /app/tmp
expect_denied "exec で ${W_RM}（シェルの文字列）" exec -T backend sh -c "${W_RM} -rf /app/tmp"
expect_denied "exec で ${W_RM}（&& の後ろ）" exec -T backend sh -c "cd /app && ${W_RM} x"
expect_denied "exec で ${W_RM}（; の後ろ）" exec -T backend sh -c "cd /app; ${W_RM} x"
expect_denied "exec で ${W_RM}（| xargs）" exec -T backend sh -c "ls | xargs ${W_RM}"
expect_denied "exec で ${W_RM}（env 経由）" exec -T backend env "$W_RM" x
expect_denied "exec で ${W_RM}（busybox 経由）" exec -T backend busybox "$W_RM" x
expect_denied "exec で ${W_RMDIR}" exec -T backend "$W_RMDIR" x
expect_denied "exec で ${W_UNLINK}" exec -T backend "$W_UNLINK" x
expect_denied "exec で ${W_SHRED}" exec -T backend "$W_SHRED" x
expect_denied "exec で find -${W_DELETE}" exec -T backend find /app -name x "-${W_DELETE}"
expect_denied "exec で find -exec ${W_RM}" exec -T backend find . -name x -exec "$W_RM" {} +
expect_denied "exec で git ${W_CLEAN}" exec -T backend git "$W_CLEAN" -fdx
expect_denied "exec で FileUtils.${W_RM}_rf（Ruby）" exec -T backend ruby -e "FileUtils.${W_RM}_rf('x')"
expect_denied "exec で File.${W_DELETE}（Ruby）" exec -T backend ruby -e "File.${W_DELETE}('x')"
expect_denied "exec で Dir.${W_RMDIR}（Ruby）" exec -T backend ruby -e "Dir.${W_RMDIR}('x')"
expect_denied "exec で fs.${W_RM}Sync（Node.js）" exec -T frontend node -e "const fs = require('fs'); fs.${W_RM}Sync('x')"
expect_denied "exec で log:${W_CLEAR}（Rails）" exec -T backend bin/rails "log:${W_CLEAR}"
expect_denied "exec で tmp:${W_CLEAR}（Rails）" exec -T backend bin/rails "tmp:${W_CLEAR}"
expect_denied "run 経由でも（--${W_RM} が無くても、削除系のコマンドを渡せば拒否する）" run backend "$W_RM" -rf x

# --- 絶対パスで指定した削除コマンド ---
section "拒否する: 絶対パスで指定した削除コマンド（/bin/…・/usr/bin/…）"
expect_denied "exec で /bin/${W_RM}" exec -T backend "/bin/${W_RM}" -rf /app/tmp
expect_denied "exec で /usr/bin/${W_RM}" exec -T backend "/usr/bin/${W_RM}" -rf /app/tmp
expect_denied "exec で /bin/${W_RMDIR}" exec -T backend "/bin/${W_RMDIR}" x
expect_denied "exec で /usr/bin/${W_UNLINK}" exec -T backend "/usr/bin/${W_UNLINK}" x
expect_denied "exec で シェルの文字列の中の /bin/${W_RM}" exec -T backend sh -c "/bin/${W_RM} -rf /app/tmp"

# --- 通してよい操作 ---
section "通す: 止める・見る・実行するための操作（誤って拒否しない）"
expect_allowed "ps" ps
expect_allowed "ps --all --format json" ps --all --format json
expect_allowed "config --quiet" config --quiet
expect_allowed "up -d --wait" up -d --wait
expect_allowed "up -d --wait db backend" up -d --wait db backend
expect_allowed "up -d --wait --build" up -d --wait --build
expect_allowed "stop（コンテナは stop で止める）" stop
expect_allowed "start" start
expect_allowed "restart relay" restart relay
expect_allowed "logs --tail 10 backend" logs --tail 10 backend
expect_allowed "build backend" build backend
expect_allowed "exec -T backend bin/rails about" exec -T backend bin/rails about
expect_allowed "exec -T backend sh -c（複数のコマンド）" exec -T backend sh -c "cd /app && ls -la && echo done"
expect_allowed "exec -T relay go version" exec -T relay go version
expect_allowed "--env-file を渡す" --env-file /tmp/x.env config --quiet
section "通す: 削除系の語に似ているが、無害な引数（語の一部・パスの一部）"
expect_allowed "exec のパスに norm・firm・farm を含む" exec -T backend ls /norm/firm/farm
expect_allowed "exec の文字列に perform・storm・form・term を含む" exec -T backend sh -c "echo perform storm form term"
expect_allowed "exec の RSpec のファイル名に farm を含む" exec -T backend bundle exec rspec spec/models/farm_spec.rb
expect_allowed "exec の git log の書式" exec -T backend git log --format=%h
expect_allowed "exec の go test の絞り込み" exec -T relay go test -run TestFormat ./...
expect_allowed "exec の eslint の --fix（ファイルを直す。削除ではない）" exec -T frontend npm run lint -- --fix

# --- root では実行できない ---
section "root では実行できない（コンテナが root 所有のファイルを作るため）"
before="$(wc -l <"$SPY_LOG")"
root_out="$(PATH="$ROOT_DIR_FAKE:$SPY_DIR:$PATH" PR33_SPY_LOG="$SPY_LOG" "$DC" ps 2>&1)"
root_status=$?
after="$(wc -l <"$SPY_LOG")"
if [[ "$root_status" -eq 2 && "$((after - before))" -eq 0 ]] && grep -q 'root' <<<"$root_out"; then
  pass "root（UID 0）として実行すると、終了コード 2 で拒否され、docker を呼ばない"
else
  fail "root（UID 0）として実行すると、終了コード 2 で拒否され、docker を呼ばない（終了コード ${root_status}。docker の呼び出し $((after - before)) 回）"
fi

# --- 拒否のメッセージ ---
section "拒否のメッセージ（利用者が、次に何をすればよいか分かる）"
run_dc "$W_DOWN"
if grep -q 'stop' <<<"$DC_OUT"; then pass "拒否のメッセージが、コンテナは stop で止めると案内する"; else fail "拒否のメッセージが、コンテナは stop で止めると案内する"; fi
if grep -q '手動' <<<"$DC_OUT"; then pass "拒否のメッセージが、削除が必要な場合は手動で行うと案内する"; else fail "拒否のメッセージが、削除が必要な場合は手動で行うと案内する"; fi
if grep -q "$W_DOWN" <<<"$DC_OUT"; then pass "拒否のメッセージが、拒否した操作の名前を示す"; else fail "拒否のメッセージが、拒否した操作の名前を示す"; fi

# --- 別のディレクトリから・本物の docker での通過 ---
section "本物の docker（読み取りだけ）: どのディレクトリから実行しても、同じ結果になる"
(cd / && "$DC" config --quiet >/dev/null 2>&1)
expect_eq "cwd が / でも、config --quiet が成功する（dc.sh が、リポジトリの docker-compose.yml を使う）" "0" "$?"
expect_eq "本物の docker で ps が成功し、4 サービスが healthy" "0" "$(stack_is_healthy; echo $?)"

# --- 拒否の限界（受け入れ条件の外の観察） ---
section "観察: 拒否の一覧の外にある削除の手段（既知の限界。偽の docker で、通ってしまうものを調べる）"
passed_through=()
probe_limit() {
  local label="$1"
  shift
  run_dc "$@"
  [[ "$DC_STATUS" -ne 2 ]] && passed_through+=("$label")
}
probe_limit "Pathname#${W_UNLINK}（Ruby）" exec -T backend ruby -e "Pathname('x').${W_UNLINK}"
probe_limit "require('fs').${W_RM}Sync（Node.js）" exec -T frontend node -e "require('fs').${W_RM}Sync('x')"
probe_limit "npx ${W_RIMRAF}" exec -T frontend npx "$W_RIMRAF" .next
probe_limit "shutil.${W_RM}tree（Python）" exec -T backend python3 -c "import shutil; shutil.${W_RM}tree('x')"
probe_limit "go ${W_CLEAN} -modcache" exec -T relay go "$W_CLEAN" -modcache
probe_limit "bin/rails db:drop（データベースの削除）" exec -T backend bin/rails db:drop
if [[ "${#passed_through[@]}" -eq 0 ]]; then
  pass "調べた削除の手段は、すべて拒否された"
else
  note "拒否の一覧（scripts/dc.sh の DENIED_TOKENS・DENIED_PATTERNS）の外にあり、通ってしまう削除の手段: ${passed_through[*]}。完全な防止は、拒否の一覧では不可能なため、受け入れ条件の外として記録する"
fi

# --- 実際の開発サーバーは無傷 ---
section "拒否の前後で、実際の開発サーバーが変わらない（コンテナを触らない）"
stack_after="$(snapshot_stack)"
if [[ -n "$stack_before" && "$stack_before" == "$stack_after" ]]; then
  pass "実際の 4 つのコンテナの ID・状態・起動時刻が、このテストの前後で同じ"
else
  fail "実際のコンテナの ID・状態・起動時刻が、このテストの前後で変わった"
fi
if stack_is_healthy; then pass "このテストの後も、4 サービスが running・healthy"; else fail "このテストの後は、4 サービスが running・healthy ではない"; fi
volumes_after="$(docker volume ls --format '{{.Name}}' | grep -c '_db_data$' || true)"
expect_eq "db のデータのボリューム（*_db_data）の数が変わらない" "$volumes_before" "$volumes_after"

finish
