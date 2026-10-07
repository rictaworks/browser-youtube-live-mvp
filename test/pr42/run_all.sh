#!/usr/bin/env bash
# PR #42（issue #23「同一オリジン中継（BFF）・API クライアント・bot 判定・ランディング・アカウント画面」）のテスト一式。
# 対象は開発サーバー（scripts/dc.sh 経由の docker compose の frontend・backend コンテナ。ホストの localhost）と、ホストの Node（実ブラウザ・走査）。
#
#   1. ESLint と Jest（scripts/test_frontend.sh <この issue の範囲>。実装担当のテスト。中継・API クライアント・bot 判定・画面・文言の方針の走査を含む）
#   2. 型検査（tsc --noEmit。この issue の範囲と、その依存。プロジェクト全体の型検査は、CI の担当）
#   3. 本番ビルド（npm run build）と、経路の表（/・/account・/api/[...path] が、要求のたびに描画される動的な経路であること）
#   4. 同一オリジン中継の結合（lib/bff_e2e.cjs。frontend コンテナの中で、next start（本番の構成）と使い捨てのスタブのバックエンドを起動し、素の HTTP で確かめる）
#   5. 開発サーバーへの curl（lib/curl_smoke.sh。/・/account の HTML・/api/... の転送（実物のバックエンド）・中継の拒否）
#   6. 実ブラウザ（Playwright の Chromium。lib/browser_check.cjs）: 描画・フォーカス・外部ドメインへ通信しない・ログイン・確認のダイアログ・アクセシビリティ。
#      Playwright・Chromium が無ければ SKIP（確認できなかった）
#   7. ソースの走査（lib/scan_sources.cjs）: 削除系の語・絵文字・alert/confirm/prompt・日本語の直書き・通信と環境変数の置き場・保存先・HTML の差し込み
#
# 使い方: このファイルを実行する（リポジトリのどこからでもよい。場所は、このファイル自身から解決する）
#   test/pr42/run_all.sh [--strict] [工程の番号...]
#     --strict   SKIP（確認できなかった）を、失敗として扱う（CI・受け入れの記録用）
#     番号       指定した工程だけを実行する（例: run_all.sh 5 6）。省略すると、1〜7 のすべて
#   事前に scripts/setup_dev_env.sh で .env を作る。コンテナは、このスクリプトが起動する（止める場合は scripts/dc.sh stop）
#   環境変数: PLAYWRIGHT_DIR（playwright のディレクトリ。無ければ、npx のキャッシュなどから探す）・ARTIFACT_DIR（スクリーンショットの置き場）・
#             FRONTEND_PORT・BACKEND_PORT（ポート。既定 3000・3001）・STEP_TIMEOUT（1 工程の上限の秒数。既定 900）・
#             E2E_APP_DIR（工程 4 を、ビルド済みの別の frontend のディレクトリに対して、ホストの Node で実行する。工程 3 の成否に依らない）
# 終了コード: 0 = 失敗なし（SKIP があっても 0。SKIP は成功に数えず、件数を表示する。--strict では SKIP も失敗） / 1 = 失敗がある / 2 = 前提の不備
# 共有の作業ツリーでは、ほかの issue の作業中のファイルが、工程 3（ビルドは、プロジェクト全体を型検査する）と工程 1 の方針の走査に影響しうる。
# ハーネスの安全（.claude/TEST-HARNESS-SAFETY.md）: 自己再帰ガード（TH1）・ulimit -u と各工程の timeout（TH3）。ファイルは削除しない（一時ファイルは、置いたままにする）。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
cd "$ROOT_DIR" || exit 1

# TH1: 自己再帰ガード。子の工程にだけ環境変数を渡し、子の側で検知したら SKIP する（変数名の 42 は、PR の番号に置き換わる）
if [[ -n "${PR42_RUN_ALL_ACTIVE:-}" ]]; then
  echo "SKIP run_all.sh が自分自身を再帰的に起動しました。実行しません（TH1）"
  exit 0
fi
export PR42_RUN_ALL_ACTIVE=1

# TH3: プロセス数の上限（下げることはできる）。設定できなければ、中止する
ulimit -u 8192 2>/dev/null || {
  echo "FAIL プロセス数の上限（ulimit -u）を設定できません。中止します（TH3）"
  exit 2
}

strict=0
declare -a only=()
for arg in "$@"; do
  case "$arg" in
    --strict) strict=1 ;;
    [1-7]) only+=("$arg") ;;
    *)
      echo "FAIL 不明な引数です: $arg（使い方: run_all.sh [--strict] [工程の番号 1〜7...]）" >&2
      exit 2
      ;;
  esac
done

[[ -f "$ROOT_DIR/.env" ]] || {
  echo "FAIL .env がありません。先に scripts/setup_dev_env.sh を実行してください" >&2
  exit 2
}
for tool in node curl; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "FAIL ${tool} が見つかりません（ホストに必要です）" >&2
    exit 2
  }
done
[[ -x "$ROOT_DIR/scripts/dc.sh" ]] || {
  echo "FAIL scripts/dc.sh が実行できません" >&2
  exit 2
}

STEP_TIMEOUT="${STEP_TIMEOUT:-900}"
export FRONTEND_PORT="${FRONTEND_PORT:-3000}"
export BACKEND_PORT="${BACKEND_PORT:-3001}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/issue_run_all.XXXXXX")"
export ARTIFACT_DIR="${ARTIFACT_DIR:-$TMP_DIR/screenshots}"

declare -a labels=() results=() seconds=() detail=()

wanted() { # wanted <工程の番号>: この工程を実行するか
  [[ "${#only[@]}" -eq 0 ]] && return 0
  local n
  for n in "${only[@]}"; do
    [[ "$n" == "$1" ]] && return 0
  done
  return 1
}

# 出力ファイルの行のうち、先頭が ok・FAIL・SKIP のものの件数（「ok 12 / FAIL 0 / SKIP 1」の形）
inner_counts() {
  local file="$1" ok failed skipped
  ok="$(grep -c '^ok  ' "$file" 2>/dev/null || true)"
  failed="$(grep -c '^FAIL ' "$file" 2>/dev/null || true)"
  skipped="$(grep -c '^SKIP ' "$file" 2>/dev/null || true)"
  printf 'ok %s / FAIL %s / SKIP %s' "${ok:-0}" "${failed:-0}" "${skipped:-0}"
}

record() { # record <ラベル> <成功|失敗|SKIP> <秒> <補足>
  labels+=("$1")
  results+=("$2")
  seconds+=("$3")
  detail+=("$4")
}

# run_step <番号> <ラベル> <出力ファイル> <コマンド...>
#   時間制限つきで実行し、出力を画面とファイルの両方へ。終了コード 0 = 成功、3 = 確認できなかった（SKIP）、それ以外 = 失敗
run_step() {
  local number="$1" label="$2" out="$3"
  shift 3
  printf '\n######## 工程 %s: %s\n' "$number" "$label"
  local started=$SECONDS code
  timeout --kill-after=30 "$STEP_TIMEOUT" "$@" 2>&1 | tee "$out"
  code="${PIPESTATUS[0]}"
  local elapsed=$((SECONDS - started)) counts
  counts="$(inner_counts "$out")"
  case "$code" in
    0) record "$number. $label" 成功 "$elapsed" "$counts" ;;
    3) record "$number. $label" SKIP "$elapsed" "$counts（確認できなかった）" ;;
    124 | 137) record "$number. $label" 失敗 "$elapsed" "時間切れ（${STEP_TIMEOUT} 秒）" ;;
    *) record "$number. $label" 失敗 "$elapsed" "終了コード $code。$counts" ;;
  esac
  return 0
}

skip_step() { # skip_step <番号> <ラベル> <理由>
  printf '\n######## 工程 %s: %s\nSKIP %s\n' "$1" "$2" "$3"
  record "$1. $2" SKIP 0 "$3"
}

fail_step() { # fail_step <番号> <ラベル> <理由>
  printf '\n######## 工程 %s: %s\nFAIL %s\n' "$1" "$2" "$3"
  record "$1. $2" 失敗 0 "$3"
}

# ---------------------------------------------------------------------------------------------
# コンテナの起動（frontend は必須。backend は、実物への転送の確認に使う。起動できなくても、その確認だけを省略する）
# ---------------------------------------------------------------------------------------------
printf '######## 0. コンテナの起動（scripts/dc.sh up -d --wait）\n'
if ! timeout --kill-after=30 "$STEP_TIMEOUT" scripts/dc.sh up -d --wait frontend; then
  echo "FAIL frontend コンテナを起動できません。scripts/dc.sh logs --tail 100 frontend を確認してください" >&2
  exit 2
fi
if ! timeout --kill-after=30 "$STEP_TIMEOUT" scripts/dc.sh up -d --wait backend; then
  echo "NOTE backend コンテナを起動できません。実物のバックエンドへの転送の確認は、省略されます（工程 5・6 の SKIP の行を参照）"
fi

# ---------------------------------------------------------------------------------------------
# 工程 1: ESLint と Jest（この issue の範囲）
# ---------------------------------------------------------------------------------------------
JEST_SCOPE=(
  app/api app/account app/page.tsx app/page.test.tsx app/layout.tsx app/layout.providers.test.tsx
  app/web-analytics.tsx app/web-analytics.test.tsx
  lib/api lib/recaptcha components/landing components/account messages lib/source-policy
)
if wanted 1; then
  run_step 1 "ESLint と Jest（scripts/test_frontend.sh。この issue の範囲）" "$TMP_DIR/step1.txt" scripts/test_frontend.sh "${JEST_SCOPE[@]}"
  jest_summary="$(grep -E '^(Tests|Test Suites):' "$TMP_DIR/step1.txt" | tr -s ' ' | tr '\n' ' ')"
  printf '（Jest の件数: %s）\n' "${jest_summary:-取得できませんでした}"
  detail[${#detail[@]}-1]="${jest_summary:-Jest の件数を取得できませんでした}"
fi

# ---------------------------------------------------------------------------------------------
# 工程 2: 型検査（この issue の範囲と、その依存）。設定ファイルは、コンテナの /tmp に作る（作業ツリーを変えない）
# ---------------------------------------------------------------------------------------------
TYPECHECK_SCRIPT='cat > /tmp/tsconfig.issue-scope.json <<JSON
{
  "extends": "/app/tsconfig.json",
  "include": [
    "/app/next-env.d.ts",
    "/app/jest.setup.ts",
    "/app/app/api/**/*.ts",
    "/app/app/account/**/*.ts",
    "/app/app/account/**/*.tsx",
    "/app/app/page.tsx",
    "/app/app/page.test.tsx",
    "/app/app/layout.tsx",
    "/app/app/layout.providers.test.tsx",
    "/app/app/web-analytics.tsx",
    "/app/app/web-analytics.test.tsx",
    "/app/lib/api/**/*.ts",
    "/app/lib/recaptcha/**/*.ts",
    "/app/lib/recaptcha/**/*.tsx",
    "/app/components/landing/**/*.ts",
    "/app/components/landing/**/*.tsx",
    "/app/components/account/**/*.ts",
    "/app/components/account/**/*.tsx",
    "/app/messages/**/*.ts"
  ],
  "compilerOptions": { "noEmit": true, "incremental": false, "plugins": [], "typeRoots": ["/app/node_modules/@types"] }
}
JSON
npx next typegen && npx tsc -p /tmp/tsconfig.issue-scope.json && echo "型検査: 問題はありません"'
if wanted 2; then
  run_step 2 "型検査（tsc --noEmit。この issue の範囲と、その依存）" "$TMP_DIR/step2.txt" scripts/dc.sh exec -T frontend sh -c "$TYPECHECK_SCRIPT"
fi

# ---------------------------------------------------------------------------------------------
# 工程 3: 本番ビルドと、経路の表
# ---------------------------------------------------------------------------------------------
build_ok=0
build_skipped=0
if wanted 3 || wanted 4; then
  if wanted 3; then
    run_step 3 "本番ビルド（npm run build）" "$TMP_DIR/step3.txt" scripts/dc.sh exec -T frontend npm run build
    if [[ "${results[${#results[@]}-1]}" == "失敗" ]]; then
      # ビルドは、プロジェクト全体を型検査する。失敗の原因が、この issue の範囲か、ほかの issue の作業中のファイルかを示す
      printf '\n-- ビルドが失敗した原因（型検査のエラーのあるファイル）\n'
      error_files="$(grep -oE '^[^ (]+\.tsx?\(' "$TMP_DIR/step3.txt" | sed 's/($//' | sort -u)"
      in_scope=0
      out_of_scope=0
      while IFS= read -r error_file; do
        [[ -n "$error_file" ]] || continue
        if [[ "$error_file" =~ ^(app/api/|app/account/|app/page\.|app/layout\.|app/web-analytics\.|lib/api/|lib/recaptcha/|components/landing/|components/account/|messages/) ]]; then
          in_scope=$((in_scope + 1))
          echo "  この issue の範囲: ${error_file}"
        else
          out_of_scope=$((out_of_scope + 1))
          echo "  範囲外（ほかの issue の作業中のファイルの可能性）: ${error_file}"
        fi
      done <<<"$error_files"
      detail[${#detail[@]}-1]="型エラーのあるファイル: この issue の範囲 ${in_scope} 件・範囲外 ${out_of_scope} 件"
      if [[ "$in_scope" -eq 0 && "$out_of_scope" -gt 0 ]]; then
        # この issue の範囲に、型エラーは無い。ビルドが通らないのは、ほかの issue の作業中のファイルのため、この issue のビルドは、確認できなかった
        results[${#results[@]}-1]="SKIP"
        detail[${#detail[@]}-1]="確認できなかった: ビルドは、範囲外（ほかの issue の作業中の可能性）のファイル ${out_of_scope} 件の型エラーで失敗した。この issue の範囲に、型エラーは無い。PR のブランチの状態で、もう一度実行してください"
        build_skipped=1
      fi
    fi
    if [[ "${results[${#results[@]}-1]}" == "成功" ]]; then
      build_ok=1
      # 経路の表: ƒ = 要求のたびに描画（動的）、○ = 静的。/ と /account は、サイトキーを要求ごとに読むため、動的でなければならない
      printf '\n-- 経路の表の確認\n'
      table_ok=1
      for route in '/' '/account' '/api/\[...path\]' '/healthz'; do
        if grep -Eq "^[^A-Za-z0-9]*ƒ[[:space:]]+${route}([[:space:]]|\$)" "$TMP_DIR/step3.txt"; then
          echo "ok   ${route//\\/} は、要求のたびに描画される動的な経路（ƒ）"
        else
          echo "FAIL ${route//\\/} が、動的な経路（ƒ）として、ビルドの経路の表に無い"
          table_ok=0
        fi
      done
      if [[ "$table_ok" -ne 1 ]]; then
        results[${#results[@]}-1]="失敗"
        detail[${#detail[@]}-1]="経路の表に、期待した動的な経路が無い"
        build_ok=0
      fi
    fi
  else
    # 工程 4 だけを実行するとき: 既存のビルドを使う（古いビルドの可能性は、READMEに記す）
    build_ok=1
  fi
fi

# ---------------------------------------------------------------------------------------------
# 工程 4: 同一オリジン中継の結合
# ---------------------------------------------------------------------------------------------
if wanted 4; then
  if [[ -n "${E2E_APP_DIR:-}" ]]; then
    # ビルド済みの別のディレクトリ（共有の作業ツリーでビルドできないとき、変更前の状態にこの issue のファイルを重ねたもの）を、ホストの Node で確かめる
    if [[ -d "$E2E_APP_DIR/.next" && -f "$E2E_APP_DIR/node_modules/next/dist/bin/next" ]]; then
      run_step 4 "同一オリジン中継の結合（ホストの Node。${E2E_APP_DIR} のビルド。bff_e2e.cjs）" "$TMP_DIR/step4.txt" env BFF_E2E_APP_DIR="$E2E_APP_DIR" node "$HERE/lib/bff_e2e.cjs"
    else
      fail_step 4 "同一オリジン中継の結合（ホストの Node。bff_e2e.cjs）" "E2E_APP_DIR（${E2E_APP_DIR}）に、ビルド（.next）と依存（node_modules）がありません"
    fi
  elif [[ "$build_ok" -eq 1 ]]; then
    run_step 4 "同一オリジン中継の結合（next start とスタブのバックエンド。bff_e2e.cjs）" "$TMP_DIR/step4.txt" bash -c 'scripts/dc.sh exec -T frontend node - < "$1"' _ "$HERE/lib/bff_e2e.cjs"
  elif [[ "$build_skipped" -eq 1 ]]; then
    skip_step 4 "同一オリジン中継の結合（next start とスタブのバックエンド。bff_e2e.cjs）" "本番ビルドを確認できなかったため（工程 3）、実行しない（古いビルドを、確かめない）"
  else
    fail_step 4 "同一オリジン中継の結合（next start とスタブのバックエンド。bff_e2e.cjs）" "本番ビルドに失敗したため、実行しない（古いビルドを、確かめない）"
  fi
fi

# ---------------------------------------------------------------------------------------------
# 工程 5: curl
# ---------------------------------------------------------------------------------------------
if wanted 5; then
  run_step 5 "開発サーバーへの curl（curl_smoke.sh）" "$TMP_DIR/step5.txt" bash "$HERE/lib/curl_smoke.sh"
fi

# ---------------------------------------------------------------------------------------------
# 工程 6: 実ブラウザ（Playwright の Chromium）
# ---------------------------------------------------------------------------------------------
find_playwright() {
  local candidate
  local -a candidates=()
  [[ -n "${PLAYWRIGHT_DIR:-}" ]] && candidates+=("$PLAYWRIGHT_DIR")
  candidates+=("$HERE/node_modules/playwright" "$ROOT_DIR/node_modules/playwright")
  if command -v npm >/dev/null 2>&1; then
    candidates+=("$(npm root -g 2>/dev/null)/playwright")
  fi
  while IFS= read -r candidate; do
    candidates+=("$candidate")
  done < <(ls -dt "${HOME:-/nonexistent}"/.npm/_npx/*/node_modules/playwright 2>/dev/null)
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate/package.json" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}
if wanted 6; then
  if playwright_dir="$(find_playwright)"; then
    echo "NOTE Playwright: ${playwright_dir}"
    export PLAYWRIGHT_DIR="$playwright_dir"
    run_step 6 "実ブラウザ（Playwright の Chromium。browser_check.cjs）" "$TMP_DIR/step6.txt" node "$HERE/lib/browser_check.cjs" --repo "$ROOT_DIR"
  else
    skip_step 6 "実ブラウザ（Playwright の Chromium。browser_check.cjs）" "Playwright が見つからず、確認できなかった（PLAYWRIGHT_DIR に playwright のディレクトリを指定すると実行できる。導入は README.md）"
  fi
fi

# ---------------------------------------------------------------------------------------------
# 工程 7: ソースの走査
# ---------------------------------------------------------------------------------------------
if wanted 7; then
  run_step 7 "ソースの走査（scan_sources.cjs）" "$TMP_DIR/step7.txt" node "$HERE/lib/scan_sources.cjs" --repo "$ROOT_DIR"
fi

# ---------------------------------------------------------------------------------------------
# 結果
# ---------------------------------------------------------------------------------------------
passed=0
failed=0
skipped=0
printf '\n######## 結果（PR #42 / issue #23）\n'
for i in "${!labels[@]}"; do
  case "${results[$i]}" in
    成功) passed=$((passed + 1)) ;;
    失敗) failed=$((failed + 1)) ;;
    SKIP) skipped=$((skipped + 1)) ;;
  esac
  printf '%s  %s（%s 秒）  %s\n' "${results[$i]}" "${labels[$i]}" "${seconds[$i]}" "${detail[$i]}"
done
printf '\n合計: 成功 %d 件・SKIP %d 件・失敗 %d 件（工程の単位）\n' "$passed" "$skipped" "$failed"
if [[ "${#labels[@]}" -eq 0 ]]; then
  echo "FAIL 実行した工程がありません"
  exit 1
fi
if [[ "$skipped" -gt 0 ]]; then
  printf 'SKIP した工程は、確認できなかったことです（成功には数えていません）。\n'
  if [[ "$strict" -eq 1 ]]; then
    failed=$((failed + skipped))
    printf '--strict のため、SKIP を失敗として扱います。\n'
  fi
fi
printf '一時ファイル・スクリーンショットの置き場: %s\n' "$TMP_DIR"
if [[ "$failed" -ne 0 ]]; then
  printf '\nFAIL PR #42 のテストに失敗した項目があります\n'
  exit 1
fi
printf '\nPASS PR #42 のテストに、失敗はありません（SKIP %d 件）\n' "$skipped"
exit 0
