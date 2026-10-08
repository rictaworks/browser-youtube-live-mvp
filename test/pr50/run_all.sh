#!/usr/bin/env bash
# PR #50（issue #10「YouTube 連携の窓口: TokenVault・YouTubeGateway（実物・疑似）・エラー対応・取り込み先の検証」）のテスト一式。
# 対象は開発サーバー（scripts/dc.sh 経由の docker compose の backend コンテナと db コンテナ）。層をまたいで、1 回で実行する。
# 実際の Google・YouTube・本番へは接続しない（WebMock と疑似で検証する）。
#
#    1. RSpec（この issue のスペックと、関連するスペック（spec/gateways・spec/models・spec/sources）。DB を使う。同時の操作・コミットするスペックを含む）と、そのスペックの RuboCop
#    2. 同じスペックを、Rails の eager_load を有効にして（CI と同じ CI=true）
#    3. backend 全体の回帰（RSpec の全件・RuboCop の全体・Brakeman・bundler-audit。scripts/test_backend.sh）
#    4. Zeitwerk の読み込み検査（YouTube を含む定数の個別の指定。eager load ですべて読み込める）
#    5. 使い捨ての DB を用意する（6・7 が使う）
#    6. 受け入れの確認（acceptance.rb。黒箱。公開の API だけで、issue の受け入れ条件を確かめる。結果は SQL と WebMock の記録で独立に確かめる）
#    7. 開発環境（RAILS_ENV=development）での通しの確認（dev_flow_check.rb。環境の判定で疑似が選ばれ、通信なしで準備から終了まで進む。注入が続く）
#    8. 既存の画面（3 層のヘルスチェック）が、影響を受けていない
#    9. （--with-mutation のときだけ。数分かかる）変異テスト（mutate_gateway.rb）。実装を 1 か所ずつ壊し、スペックが検出すること
#   10. ソース走査器の自己検査（scan_sources.py --self-test）
#   11. ソースの走査（scan_sources.py）: 絵文字・不可視の文字・削除系コマンドの語・資格情報の形式・暗号鍵らしい値・実行権限
#   12. コミット対象の db/structure.sql を書き換えていない
#
# 使い方: このスクリプトを実行する（作業ディレクトリは問わない。場所は、このファイル自身から解決する。番号は、PR の番号に改名・置換されたあとのもの）。
#   scripts/setup_dev_env.sh                   # .env の生成（済んでいれば不要）
#   <このディレクトリ>/run_all.sh [--with-mutation]
# 環境変数（任意）:
#   TEST_DB_NAME        1〜3 に使うテスト用 DB の名前。既定は、実行のたびに新しい名前（bl_test_issue10_<日時>）。bl_test_ で始まる名前に限る
#   SCRATCH_DB_NAME     5〜7 に使う使い捨ての DB の名前（既定 <TEST_DB_NAME>_scratch）
#   MUTATION_DB_NAME    9 に使う使い捨ての DB の名前（既定 <TEST_DB_NAME>_mut）
#   STEP_TIMEOUT        1 手順の上限の秒数（既定 900）
# 終了コード: 0 = すべて成功 / 1 = 失敗がある / 2 = 準備ができていない（.env が無い・引数の誤り・コンテナに入れない など）
# ハーネスの安全（.claude/TEST-HARNESS-SAFETY.md）: 自己再帰ガード（TH1）・ulimit -u と各手順の timeout（TH3）。ファイルも DB も削除しない
# （一時ファイルは mktemp の場所に残す。使い終わった bl_test_issue10_* の DB は、必要なら手動で削除する）。秘密値（.env）は、画面へ出さない。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
cd "$ROOT_DIR" || exit 2

# TH1: 自己再帰ガード
if [[ -n "${ISSUE10_RUN_ALL_ACTIVE:-}" ]]; then
  echo "SKIP run_all.sh が自分自身を再帰的に起動しました。実行しません（TH1）"
  exit 0
fi
export ISSUE10_RUN_ALL_ACTIVE=1
# TH3: プロセス数の上限
ulimit -u 8192 2>/dev/null || {
  echo "FAIL プロセス数の上限（ulimit -u）を設定できません。中止します（TH3）"
  exit 2
}

with_mutation=0
for argument in "$@"; do
  case "$argument" in
    --with-mutation) with_mutation=1 ;;
    *)
      echo "FAIL 未知の引数です: $argument（使い方: run_all.sh [--with-mutation]）" >&2
      exit 2
      ;;
  esac
done

[[ -f "$ROOT_DIR/.env" ]] || {
  echo "FAIL .env がありません。先に scripts/setup_dev_env.sh を実行してください" >&2
  exit 2
}
for tool in curl python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "FAIL ${tool} が見つかりません（ホストに必要です）" >&2
    exit 2
  }
done

# --- テスト用 DB の名前（開発 DB は使わない）---
RSPEC_DB="${TEST_DB_NAME:-bl_test_issue10_$(date +%Y%m%d%H%M%S)}"
SCRATCH_DB="${SCRATCH_DB_NAME:-${RSPEC_DB}_scratch}"
MUTATION_DB="${MUTATION_DB_NAME:-${RSPEC_DB}_mut}"
for name in "$RSPEC_DB" "$SCRATCH_DB" "$MUTATION_DB"; do
  [[ "$name" =~ ^bl_test_[a-z0-9_]{1,50}$ ]] || {
    echo "FAIL テスト用の DB の名前ではありません: $name（bl_test_ で始まる、小文字・数字・アンダースコアの名前に限ります）" >&2
    exit 2
  }
done
[[ "$RSPEC_DB" != "$SCRATCH_DB" && "$RSPEC_DB" != "$MUTATION_DB" && "$SCRATCH_DB" != "$MUTATION_DB" ]] || {
  echo "FAIL テスト用 DB の名前が重なっています" >&2
  exit 2
}
export TEST_DB_NAME="$RSPEC_DB"
export STEP_TIMEOUT="${STEP_TIMEOUT:-900}"

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/issue10.XXXXXX")"
STRUCTURE="$ROOT_DIR/src/backend/db/structure.sql"
STRUCTURE_SHA_BEFORE="$(sha256sum "$STRUCTURE" | cut -d' ' -f1)"
echo "各手順のログの置き場（削除しません）: $LOG_DIR"
echo "テスト用 DB: $RSPEC_DB（RSpec）／$SCRATCH_DB（受け入れの確認・通しの確認）／$MUTATION_DB（変異テスト）"

# この issue のスペックと、関連するスペック（spec/gateways には #8 のスペックも入る。設定の鍵の一覧を変えたので、含める）
MY_SPECS=(
  spec/gateways
  spec/models
  spec/sources
)

results=()
status=0
step=0

# 出力から、結果の要約の行を拾う
summarize() {
  grep -hE 'examples?, [0-9]+ failures?|[0-9]+ files? inspected|No warnings found|No vulnerabilities found|^All is good|^問題ありません|^自己検査|^PASS|^すべての変異|^[0-9]+ 件成功|^ok   db/structure|^ok   使い捨ての DB|^ok   [a-z]+ のヘルスチェック' "$1" | tail -4 | tr '\n' ' '
}

# run <ラベル> <コマンド...>: 終了コード 0 = 成功、3 = 確認できなかった（SKIP）、それ以外 = 失敗。STDIN_FILE があれば標準入力へ渡す
run() {
  local label="$1"
  shift
  step=$((step + 1))
  local log="$LOG_DIR/step${step}.log"
  printf '\n######## %d. %s\n' "$step" "$label"
  local code summary
  # timeout は外部のコマンドしか実行できない。関数（step_*）も実行できるよう、子の bash を経由する（関数と変数は、下で export する）
  if [[ -n "${STDIN_FILE:-}" ]]; then
    timeout --kill-after=30 "${STEP_LIMIT:-$STEP_TIMEOUT}" bash -c '"$@"' _ "$@" <"$STDIN_FILE" 2>&1 | tee "$log"
  else
    timeout --kill-after=30 "${STEP_LIMIT:-$STEP_TIMEOUT}" bash -c '"$@"' _ "$@" 2>&1 </dev/null | tee "$log"
  fi
  code="${PIPESTATUS[0]}"
  summary="$(summarize "$log")"
  case "$code" in
    0) results+=("成功  $step. $label  [$summary]") ;;
    3) results+=("SKIP  $step. $label  [確認できなかった]") ;;
    *)
      results+=("失敗  $step. $label  [終了コード $code。$(grep -hE '^FAIL|failures?|違反' "$log" | tail -2 | tr '\n' ' ')]")
      status=1
      ;;
  esac
}

# backend のコンテナの中で、使い捨てのテスト用 DB を相手に、コマンドを実行する。標準入力は、そのまま渡す。
#   in_scratch_db <環境> <DB 名> <コマンド>
# 開発 DB を相手にしないよう、DB 名を検査し、コンテナの DATABASE_URL が開発 DB を指していることを確かめてから、DB 名を差し替える。
# スキーマの書き出し先（SCHEMA）は、コンテナの /tmp にする（コミット対象の db/structure.sql を書き換えない）。
in_scratch_db() {
  local environment="$1" db="$2" command="$3"
  [[ "$db" =~ ^bl_test_[a-z0-9_]{1,50}$ ]] || {
    echo "FAIL テスト用の DB の名前ではありません: $db" >&2
    return 2
  }
  [[ "$environment" =~ ^(test|development)$ ]] || {
    echo "FAIL 環境の名前が不正です: $environment" >&2
    return 2
  }
  scripts/dc.sh exec -T backend sh -c '
    case "$DATABASE_URL" in
      */bl_development) ;;
      *) echo "DATABASE_URL が開発 DB を指していません。中止します" >&2; exit 2 ;;
    esac
    export RAILS_ENV='"$environment"' DATABASE_URL="${DATABASE_URL%/bl_development}/'"$db"'" SCHEMA=/tmp/issue10_scratch_structure.sql
    '"$command"
}

step_prepare_scratch() {
  # スキーマの読み込みは、環境 test で行う（development で db:prepare すると、test 用の DB も触るため）。通しの確認も、同じ DB を使う
  in_scratch_db test "$SCRATCH_DB" "bin/rails db:prepare" >"$LOG_DIR/prepare_scratch.log" 2>&1 || {
    cat "$LOG_DIR/prepare_scratch.log"
    return 1
  }
  echo "ok   使い捨ての DB を用意しました（$SCRATCH_DB）"
}

step_acceptance() {
  in_scratch_db test "$SCRATCH_DB" "bundle exec ruby -" <"$HERE/acceptance.rb"
}

step_dev_flow() {
  in_scratch_db development "$SCRATCH_DB" "bundle exec ruby -" <"$HERE/dev_flow_check.rb"
}

step_zeitwerk() {
  scripts/dc.sh exec -T -e RAILS_ENV=test -e "TEST_DB_NAME=$RSPEC_DB" backend \
    sh -c 'export DATABASE_URL="${DATABASE_URL%/bl_development}/${TEST_DB_NAME}"; bin/rails zeitwerk:check'
}

# 既存の画面（3 層のヘルスチェック）が、従来どおり応答する
step_existing_endpoints() {
  local failures=0 backend_port="${BACKEND_PORT:-3001}" frontend_port="${FRONTEND_PORT:-3000}" relay_port="${RELAY_PORT:-3002}" code target
  scripts/dc.sh up -d --wait >/dev/null 2>&1 || {
    echo "FAIL docker compose の 4 サービスが、healthy になりません"
    return 1
  }
  for target in "backend|http://localhost:${backend_port}/up" "frontend|http://localhost:${frontend_port}/healthz" "relay|http://localhost:${relay_port}/health"; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "${target#*|}" 2>/dev/null || echo 000)"
    if [[ "$code" == "200" ]]; then
      echo "ok   ${target%%|*} のヘルスチェックが 200（${target#*|}）"
    else
      echo "FAIL ${target%%|*} のヘルスチェックが 200 ではありません（$code）"
      failures=$((failures + 1))
    fi
  done
  [[ "$failures" -eq 0 ]]
}

step_mutation() {
  in_scratch_db test "$MUTATION_DB" "bin/rails db:prepare" >"$LOG_DIR/prepare_mutation.log" 2>&1 || {
    cat "$LOG_DIR/prepare_mutation.log"
    return 1
  }
  scripts/dc.sh exec -T -e "ISSUE10_MUTATION_DB=$MUTATION_DB" backend ruby - <"$HERE/mutate_gateway.rb"
}

# run が子の bash で実行する関数と、関数が使う変数を渡す
export -f in_scratch_db step_prepare_scratch step_acceptance step_dev_flow step_zeitwerk step_existing_endpoints step_mutation
export HERE ROOT_DIR LOG_DIR RSPEC_DB SCRATCH_DB MUTATION_DB

# ------------------------------------------------------------------------------------------------
echo
echo "######## 0. コンテナの起動（scripts/dc.sh up -d --wait db backend）"
if ! timeout --kill-after=30 "$STEP_TIMEOUT" scripts/dc.sh up -d --wait db backend </dev/null; then
  echo "FAIL db・backend が healthy になりません。scripts/dc.sh logs --tail 100 backend を確認してください" >&2
  exit 2
fi

run "backend の RSpec と RuboCop（この issue と関連するスペック: ${MY_SPECS[*]}。テスト用 DB: $RSPEC_DB）" \
  scripts/test_backend.sh --db "${MY_SPECS[@]}"

run "同じスペックを、Rails の eager_load を有効にして（CI と同じ CI=true）" \
  scripts/dc.sh exec -T -e CI=true -e "TEST_DB_NAME=$RSPEC_DB" backend bash /scripts/test_backend.sh --db "${MY_SPECS[@]}"

STEP_LIMIT=1500 run "backend 全体の回帰（RSpec の全件・RuboCop の全体・Brakeman・bundler-audit）" \
  scripts/test_backend.sh

run "Zeitwerk の読み込み検査（YouTube を含む定数の個別の指定。eager load ですべて読み込める）" step_zeitwerk

run "使い捨ての DB を用意する（受け入れの確認・通しの確認）" step_prepare_scratch

run "受け入れの確認（黒箱。公開の API だけで、issue の受け入れ条件を確かめる）" step_acceptance

run "開発環境（RAILS_ENV=development）での通しの確認（疑似が選ばれ、通信なしで準備から終了まで進む。注入が続く）" step_dev_flow

run "既存の画面（ヘルスチェック）" step_existing_endpoints

if [[ "$with_mutation" -eq 1 ]]; then
  STEP_LIMIT=2400 run "変異テスト（実装を 1 か所ずつ壊し、スペックが検出すること）" step_mutation
else
  step=$((step + 1))
  results+=("省略  $step. 変異テスト（--with-mutation で実行。数分かかる）")
fi

run "ソース走査器の自己検査（合成したソースで、違反を見逃さず、違反でないものを誤検知しないこと）" \
  python3 -I "$HERE/scan_sources.py" --self-test

run "ソースの走査（絵文字・不可視の文字・削除系コマンドの語・資格情報の形式・暗号鍵らしい値・実行権限）" \
  python3 -I "$HERE/scan_sources.py" "$ROOT_DIR"

# この実行が、コミットされるファイルを書き換えていないこと
step=$((step + 1))
printf '\n######## %d. db/structure.sql を書き換えていない\n' "$step"
if [[ "$(sha256sum "$STRUCTURE" | cut -d' ' -f1)" == "$STRUCTURE_SHA_BEFORE" ]]; then
  echo "ok   db/structure.sql は、実行の前後で同じ"
  results+=("成功  $step. db/structure.sql を書き換えていない")
else
  echo "FAIL db/structure.sql が、実行の途中で書き換わりました"
  results+=("失敗  $step. db/structure.sql を書き換えていない")
  status=1
fi

printf '\n######## 結果（PR #50）\n'
printf '%s\n' "${results[@]}"
printf '各手順のログ（削除しません）: %s\n' "$LOG_DIR"
if [[ "$status" -ne 0 ]]; then
  printf '\nFAIL PR #50 のテストに失敗した項目があります\n'
  exit 1
fi
printf '\nPASS PR #50 のテストはすべて成功しました\n'
exit 0
