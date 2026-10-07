#!/usr/bin/env bash
# test/pr33 の共通部品。各チェック（checks/*.sh）が source して使う。
#
# 出力の書式は scripts/tests/*.sh と同じ。
#   ok   説明     成功
#   FAIL 説明     失敗。チェックは、最後に終了コード 1 を返す
#   SKIP 説明     前提が無く、確認できなかった。失敗にはしないが、ランナーの集計に出る
#   NOTE 説明     受け入れ条件の外の観察（既知の限界など）。失敗にはしない
#
# 守ること（README.md「安全上の約束」）
#   - 対象は開発サーバー（scripts/dc.sh 経由の docker compose。ホストの localhost）。本番へ接続しない。
#     接続先のホスト名は変えられない（変えられるのはポート番号だけ）
#   - 削除系のコマンドを実行しない。後始末が要る場面でも削除せず、新しい名前の一時ディレクトリを作る
#   - .env の値を、標準出力・標準エラー・コマンドの引数へ出さない
#   - git の状態を変えない（読み取りのみ）
#
# 注意: このファイルは、シェルオプション（set -e など）を設定しない。呼び出し側が set -uo pipefail を設定する
# （失敗しても、残りの確認を続けるため、-e は使わない）。

# このファイルの変数は、source した呼び出し側（checks/*.sh）が使う
# shellcheck disable=SC2034

if [[ -n "${PR33_COMMON_LOADED:-}" ]]; then
  return 0
fi
PR33_COMMON_LOADED=1

PR33_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR33_DIR="$(cd "$PR33_LIB_DIR/.." && pwd)"
ROOT_DIR="$(cd "$PR33_DIR/../.." && pwd)"
DC="$ROOT_DIR/scripts/dc.sh"
ENV_FILE_REAL="$ROOT_DIR/.env"

# --- 削除系コマンドの語 ---
# この PR のテストのソース自体に、削除系コマンドの語をそのまま書かない（CLAUDE.md の走査に掛からないようにする）。
# 拒否の確認や、走査の対照データを作るときは、ここから組み立てる。
readonly W_RM="r""m"
readonly W_RMDIR="rm""dir"
readonly W_UNLINK="un""link"
readonly W_SHRED="sh""red"
readonly W_DOWN="do""wn"
readonly W_KILL="ki""ll"
readonly W_PRUNE="pr""une"
readonly W_DELETE="de""lete"
readonly W_CLEAN="cl""ean"
readonly W_CLEAR="cl""ear"
readonly W_RIMRAF="rim""raf"

# --- 結果の出力 ---
PR33_FAILURES=0

pass() { printf 'ok   %s\n' "$*"; }
fail() {
  printf 'FAIL %s\n' "$*"
  PR33_FAILURES=$((PR33_FAILURES + 1))
}
skip() { printf 'SKIP %s\n' "$*"; }
note() { printf 'NOTE %s\n' "$*"; }
section() { printf '\n-- %s\n' "$*"; }

# 終了する。失敗があれば 1、なければ 0
finish() {
  if [[ "$PR33_FAILURES" -ne 0 ]]; then
    printf '\n%d 件失敗しました\n' "$PR33_FAILURES"
    exit 1
  fi
  printf '\nすべて成功しました\n'
  exit 0
}

# 前提を満たさず、実行できない（終了コード 2。ランナーは失敗として扱う）
abort() {
  printf 'FAIL %s\n' "$*"
  printf '\n前提を満たさないため、実行できません\n'
  exit 2
}

# check <説明> <コマンド...>: コマンドが成功（終了コード 0）すれば ok
check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label"
  fi
}

# expect_eq <説明> <期待値> <実際の値>（値は非機密のときだけ使う）
expect_eq() {
  if [[ "$3" == "$2" ]]; then
    pass "$1"
  else
    fail "$1（期待: $2 / 実際: $3）"
  fi
}

# expect_json <説明> <jq の式> <JSON>: 式が true（jq -e）なら ok。値は出さない
expect_json() {
  if jq -e "$2" <<<"$3" >/dev/null 2>&1; then
    pass "$1"
  else
    fail "$1"
  fi
}

# --- 前提の確認 ---
require_tools() {
  local tool missing=()
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if [[ "${#missing[@]}" -ne 0 ]]; then
    abort "必要なコマンドがありません: ${missing[*]}"
  fi
}

# 実際の .env があること（値は読まない。compose が読む）
require_env_file() {
  [[ -f "$ENV_FILE_REAL" ]] || abort ".env がありません。scripts/setup_dev_env.sh を実行してください"
}

# --- 接続先（開発サーバー。ホストは localhost に固定。ポートだけ、並行して複数の環境を起動するときの環境変数で変えられる） ---
port_or_default() {
  local value="${!1:-$2}"
  if [[ ! "$value" =~ ^[0-9]{1,5}$ ]]; then
    printf 'FAIL %s は、ポート番号ではありません（%q）\n' "$1" "$value"
    exit 2
  fi
  printf '%s' "$value"
}

FRONTEND_PORT="$(port_or_default FRONTEND_PORT 3000)"
BACKEND_PORT="$(port_or_default BACKEND_PORT 3001)"
RELAY_PORT="$(port_or_default RELAY_PORT 3002)"
# backend の内部通信の口（src/backend/config/server_ports.rb の ServerPorts::INTERNAL）。ホストへは公開しない
INTERNAL_PORT=3101
DB_PORT=5432
FRONTEND_URL="http://localhost:${FRONTEND_PORT}"
BACKEND_URL="http://localhost:${BACKEND_PORT}"
RELAY_URL="http://localhost:${RELAY_PORT}"

readonly STACK_SERVICES=(db backend relay frontend)
readonly APP_SERVICES=(backend relay frontend)

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

# --- HTTP ---
# http_get <URL> [curl の追加引数...]
#   HTTP_CURL_EXIT（curl の終了コード。接続できなければ 0 以外）・HTTP_STATUS（接続できなければ 000）・
#   HTTP_HEADERS・HTTP_BODY を設定する。リダイレクトは追わない
HTTP_CURL_EXIT=0
HTTP_STATUS="000"
HTTP_HEADERS=""
HTTP_BODY=""
http_get() {
  local url="$1"
  shift
  local raw
  raw="$(curl --silent --show-error --globoff --include --max-time "${PR33_HTTP_TIMEOUT:-60}" "$@" "$url" 2>/dev/null)"
  HTTP_CURL_EXIT=$?
  HTTP_STATUS="000"
  HTTP_HEADERS=""
  HTTP_BODY=""
  if [[ "$HTTP_CURL_EXIT" -eq 0 && -n "$raw" ]]; then
    local head="${raw%%$'\r\n\r\n'*}"
    HTTP_BODY="${raw#*$'\r\n\r\n'}"
    HTTP_STATUS="$(head -n 1 <<<"$head" | awk '{print $2}')"
    HTTP_HEADERS="$(tail -n +2 <<<"$head" | tr -d '\r')"
  fi
}

# header_value <ヘッダ名>: 直前の http_get の応答ヘッダの値（無ければ空）
header_value() {
  grep -i -m 1 "^$1:" <<<"$HTTP_HEADERS" | sed -E 's/^[^:]*:[[:space:]]*//'
}

# 前後の空白と改行を除く
trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# --- docker compose（必ず scripts/dc.sh 経由） ---
# in_container <サービス> <コマンド...>: 起動中のコンテナで実行する（run は使わない）
in_container() {
  local service="$1"
  shift
  "$DC" exec -T "$service" "$@"
}

# 4 サービスの状態を「サービス 状態 ヘルス」で 1 行ずつ返す
stack_state_lines() {
  "$DC" ps --all --format json 2>/dev/null | jq -rs '.[] | "\(.Service) \(.State) \(.Health)"' | sort
}

# 4 サービスがすべて running・healthy か（0: はい）
stack_is_healthy() {
  local lines service
  lines="$(stack_state_lines)"
  for service in "${STACK_SERVICES[@]}"; do
    grep -qx "$service running healthy" <<<"$lines" || return 1
  done
  return 0
}

# 開発サーバーが healthy でなければ、実行できない（終了コード 2）
require_stack_healthy() {
  if ! stack_is_healthy; then
    printf 'FAIL 開発サーバー（db・backend・relay・frontend）が healthy ではありません。現在の状態:\n'
    stack_state_lines | sed 's/^/     /'
    abort "scripts/dc.sh up -d --wait を実行してから、もう一度実行してください"
  fi
}

# --- 一時領域 ---
# 新しい一時ディレクトリを作り、そのパスを返す（後始末は OS の一時領域の掃除に任せる。削除しない）
new_tmpdir() {
  mktemp -d "${TMPDIR:-/tmp}/pr33_${1:-work}.XXXXXX"
}

# --- 秘密値 ---
# .env の「秘密とみなす値」（名前に SECRET・PASSWORD・_KEY・TOKEN を含む変数の、8 文字以上の値）を 1 行ずつ出す。
# 端末へ直接出さない。grep -f の入力としてのみ使う（grep -f <(secret_values) の形）。
secret_values() {
  local file="${1:-$ENV_FILE_REAL}"
  [[ -r "$file" ]] || return 0
  grep -E '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*(SECRET|PASSWORD|_KEY|TOKEN)[A-Za-z0-9_]*=' "$file" |
    sed -E 's/^[^=]*=//; s/^[[:space:]]+//; s/[[:space:]]+$//; s/^["'\'']//; s/["'\'']$//' |
    awk 'length($0) >= 8'
}

# コミット対象になるファイル（追跡済み＋未追跡で、gitignore されていないもの）を、リポジトリ直下からの相対パスで 1 行ずつ返す
commit_set() {
  git -C "$ROOT_DIR" ls-files -co --exclude-standard
}

# --- 並び替えた集合の比較 ---
# 2 つの改行区切りの集合が等しいか
same_set() {
  [[ "$(sort -u <<<"$1")" == "$(sort -u <<<"$2")" ]]
}

# 集合 a から集合 b を除いたものを返す
set_minus() {
  comm -23 <(sort -u <<<"$1") <(sort -u <<<"$2")
}

# 1 行にまとめる（失敗メッセージ用）
oneline() {
  tr '\n' ' ' <<<"$1" | sed -E 's/[[:space:]]+$//'
}
