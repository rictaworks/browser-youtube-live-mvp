#!/usr/bin/env bash
# 開発用の .env を生成する。冪等で、既存の値を上書きせず、ファイルを削除しない（不足している変数だけを末尾へ追記する）。
#
#   乱数            : SESSION_SECRET・TOKEN_ENCRYPTION_KEY・RELAY_SHARED_SECRET・BFF_SHARED_SECRET・
#                     ADMIN_BASIC_PASSWORD・POSTGRES_PASSWORD
#   開発用の固定値  : ADMIN_BASIC_USER・POSTGRES_USER・BACKEND_ORIGIN・BACKEND_INTERNAL_URL・RELAY_PUBLIC_URL
#   空のまま        : GOOGLE_*・RECAPTCHA_*（開発・テストは疑似実装を使う。実際の値を試すときは、利用者が自分で書く）
#
# 書かない変数:
#   RAILS_ENV    テストが development 環境で走る事故を防ぐため。docker-compose.yml と scripts/test_backend.sh が明示する
#   DATABASE_URL 開発環境は docker-compose.yml が POSTGRES_USER・POSTGRES_PASSWORD から組み立てる
#
# RELAY_PUBLIC_URL の既定値の口は、RELAY_PORT（環境変数、なければ .env の値、なければ 3002）。
# 並行して複数の環境を起動するとき（docker-compose.yml の RELAY_PORT を変えるとき）に、ブラウザが正しい中継へつながるようにする。
#
# 値は画面へ出さない（名前だけを出す）。ENV_FILE で書き込み先を変えられる（テスト用。既定はリポジトリ直下の .env）。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"

# 名前:種類:引数 （random は乱数のバイト数、fixed は値、empty は空のまま。引数は最初の 2 つの : より後ろをすべて使う。
# fixed の値の @RELAY_PORT@ は、relay_port の値に置き換える）
readonly VARIABLES=(
  "GOOGLE_CLIENT_ID:empty:"
  "GOOGLE_CLIENT_SECRET:empty:"
  "TOKEN_ENCRYPTION_KEY:random:32"
  "SESSION_SECRET:random:64"
  "RECAPTCHA_SITE_KEY:empty:"
  "RECAPTCHA_SECRET_KEY:empty:"
  "ADMIN_BASIC_USER:fixed:admin"
  "ADMIN_BASIC_PASSWORD:random:32"
  "RELAY_PUBLIC_URL:fixed:ws://localhost:@RELAY_PORT@/ws"
  "BACKEND_ORIGIN:fixed:http://backend:3001"
  "BACKEND_INTERNAL_URL:fixed:http://backend:3101"
  "RELAY_SHARED_SECRET:random:32"
  "BFF_SHARED_SECRET:random:32"
  "POSTGRES_USER:fixed:bl"
  "POSTGRES_PASSWORD:random:32"
)

die() {
  echo "setup_dev_env.sh: $*" >&2
  exit 1
}

# 乱数を 16 進文字列で返す。引数はバイト数
random_hex() {
  od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
}

# 行頭の空白と export は許す（compose の .env の書式）
assignment_pattern() {
  printf '^[[:space:]]*(export[[:space:]]+)?%s=' "$1"
}

has_name() {
  grep -qE "$(assignment_pattern "$1")" "$ENV_FILE"
}

# 最後の NAME=値 の行から、前後の空白と引用符を除いた値を返す
value_of() {
  local raw
  raw="$(grep -E "$(assignment_pattern "$1")" "$ENV_FILE" | tail -n 1 | cut -d= -f2-)"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  raw="${raw#[\"\']}"
  raw="${raw%[\"\']}"
  printf '%s' "$raw"
}

# 中継の公開ポート（ホスト側）。環境変数 RELAY_PORT、なければ .env の RELAY_PORT、なければ 3002
relay_port() {
  local port="${RELAY_PORT:-}"
  if [[ -z "$port" ]] && [[ -e "$ENV_FILE" ]] && has_name RELAY_PORT; then
    port="$(value_of RELAY_PORT)"
  fi
  port="${port:-3002}"
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || die "RELAY_PORT=\"$port\" は、ポート番号ではありません。"
  printf '%s' "$port"
}

# 書き込む前に、すべての条件を確かめる（失敗したときに .env を変えないため）
preflight() {
  relay_port >/dev/null

  if [[ "$ENV_FILE" == "$ROOT_DIR"/* ]]; then
    command -v git >/dev/null || die "git が見つかりません。.env が gitignore されているかを確認できないため、中止します。"
    git -C "$ROOT_DIR" check-ignore -q -- "$ENV_FILE" ||
      die "$ENV_FILE が gitignore されていません（または追跡されています）。.gitignore に .env を追加してから、もう一度実行してください。"
  fi

  if [[ -e "$ENV_FILE" ]] && grep -qE '^[[:space:]]*(export[[:space:]]+)?RAILS_ENV=' "$ENV_FILE"; then
    die "$ENV_FILE に RAILS_ENV が書かれています。テストが development 環境で走る事故のもとになるため、その行を手動で消してから、もう一度実行してください。"
  fi

  local spec name kind
  for spec in "${VARIABLES[@]}"; do
    IFS=: read -r name kind _ <<<"$spec"
    if [[ "$kind" != "empty" ]] && [[ -e "$ENV_FILE" ]] && has_name "$name" && [[ -z "$(value_of "$name")" ]]; then
      die "$name の値が空です。値を書くか、その行を手動で消してから、もう一度実行してください（既存の行は書き換えません）。"
    fi
  done
}

# ファイルの末尾が改行でなければ、改行を足す（既存の最終行を壊さないため）
ensure_trailing_newline() {
  if [[ -s "$ENV_FILE" ]] && [[ "$(tail -c 1 "$ENV_FILE" | wc -l)" -eq 0 ]]; then
    printf '\n' >>"$ENV_FILE"
  fi
}

main() {
  preflight

  umask 077
  [[ -e "$ENV_FILE" ]] || : >"$ENV_FILE"
  chmod 600 "$ENV_FILE"

  local spec name kind arg added=()
  local header_written=0
  for spec in "${VARIABLES[@]}"; do
    IFS=: read -r name kind arg <<<"$spec"
    has_name "$name" && continue

    ensure_trailing_newline
    if [[ "$header_written" -eq 0 ]]; then
      printf '# --- scripts/setup_dev_env.sh が追記した開発用の値（コミットしない） ---\n' >>"$ENV_FILE"
      header_written=1
    fi
    case "$kind" in
      random) printf '%s=%s\n' "$name" "$(random_hex "$arg")" >>"$ENV_FILE" ;;
      fixed) printf '%s=%s\n' "$name" "${arg//@RELAY_PORT@/$(relay_port)}" >>"$ENV_FILE" ;;
      empty) printf '%s=\n' "$name" >>"$ENV_FILE" ;;
      *) die "内部エラー: 未知の種類 $kind（$name）" ;;
    esac
    added+=("$name")
  done

  if [[ "${#added[@]}" -eq 0 ]]; then
    echo "追記する変数はありません（$ENV_FILE は最新です）。"
  else
    echo "$ENV_FILE へ追記した変数: ${added[*]}"
    echo "値は表示しません。GOOGLE_*・RECAPTCHA_* は空のままです（開発・テストは疑似実装を使います）。"
  fi
  echo "コミットの前に git status を実行し、.env がステージされていないことを確認してください。"
}

main "$@"
