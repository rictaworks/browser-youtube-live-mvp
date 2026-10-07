#!/usr/bin/env bash
# PR #36（issue #22 フロントエンド基盤）のテスト一式。対象は開発サーバー（scripts/dc.sh 経由の docker compose。ホストの localhost）。
#
#   1. scripts/test_frontend.sh（ESLint・tsc・Jest。トークンのコントラスト・ハードコード・絵文字の検知を含む）
#   2. 本番ビルド（next build。自己ホストするフォントの取得を含む）
#   3. 画面の smoke（curl）：/terms・/privacy が 200・日本語・ページごとの <title>・フッターに 2 つのリンク・
#      外部の CDN（フォント・アイコン）へ接続しない・連絡先が info@rictaworks.jp。404 の画面にもフッター。/healthz が従来どおり
#
# 使い方: test/pr36/run_all.sh [--stop]
# 終了コード: 0 = すべて成功 / 1 = 失敗がある
# ハーネスの安全（.claude/TEST-HARNESS-SAFETY.md）: 自己再帰ガード・ulimit -u・各手順の timeout。ファイルは削除しない。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
cd "$ROOT_DIR" || exit 1

if [[ -n "${PR36_RUN_ALL_ACTIVE:-}" ]]; then
  echo "SKIP run_all.sh が自分自身を再帰的に起動しました。実行しません（TH1）"
  exit 0
fi
export PR36_RUN_ALL_ACTIVE=1
ulimit -u 8192 2>/dev/null || {
  echo "FAIL プロセス数の上限（ulimit -u）を設定できません。中止します（TH3）"
  exit 2
}
[[ -f "$ROOT_DIR/.env" ]] || {
  echo "FAIL .env がありません。先に scripts/setup_dev_env.sh を実行してください" >&2
  exit 2
}

FRONTEND_PORT="${FRONTEND_PORT:-3000}"
[[ "$FRONTEND_PORT" =~ ^[0-9]{1,5}$ ]] || {
  echo "FAIL FRONTEND_PORT がポート番号ではありません" >&2
  exit 2
}
BASE="http://localhost:${FRONTEND_PORT}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pr36.XXXXXX")"

failures=0
ok() { printf 'ok   %s\n' "$*"; }
ng() {
  printf 'FAIL %s\n' "$*"
  failures=$((failures + 1))
}

fetch() { # fetch <パス> <出力ファイル> → HTTP ステータスを標準出力へ
  curl -sS -o "$2" -w '%{http_code}' --max-time 120 "${BASE}$1" 2>/dev/null || echo "000"
}

printf '\n######## 1. scripts/test_frontend.sh\n'
if timeout --kill-after=30 900 scripts/test_frontend.sh; then ok "scripts/test_frontend.sh"; else ng "scripts/test_frontend.sh"; fi

printf '\n######## 2. 本番ビルド\n'
if timeout --kill-after=30 900 scripts/dc.sh exec -T frontend npm run build; then ok "next build"; else ng "next build"; fi

printf '\n######## 3. 画面の smoke（%s）\n' "$BASE"
scripts/dc.sh up -d --wait frontend >/dev/null 2>&1 || ng "frontend を起動できません"

for page in terms privacy; do
  file="$TMP_DIR/$page.html"
  code="$(fetch "/$page" "$file")"
  [[ "$code" == "200" ]] && ok "/$page が 200" || ng "/$page が 200 ではありません（$code）"
  grep -q '<html lang="ja"' "$file" && ok "/$page は lang=ja" || ng "/$page に lang=ja がありません"
  grep -qE '<title>[^<]+ \| ' "$file" && ok "/$page に、ページごとの title がある" || ng "/$page の title が想定の形ではありません"
  [[ "$(grep -oE 'href="/terms"' "$file" | wc -l)" -ge 1 && "$(grep -oE 'href="/privacy"' "$file" | wc -l)" -ge 1 ]] \
    && ok "/$page に、利用規約とプライバシーポリシーへのリンクがある（全画面のフッター）" || ng "/$page に、2 つのリンクがありません"
  if grep -qE 'fonts\.googleapis\.com|fonts\.gstatic\.com|cdnjs\.cloudflare\.com|use\.fontawesome\.com' "$file"; then
    ng "/$page が、外部の CDN（フォント・アイコン）を参照しています"
  else
    ok "/$page は、外部の CDN を参照しない（フォントは自己ホスト）"
  fi
  grep -q 'info@rictaworks\.jp' "$file" && ok "/$page の連絡先が info@rictaworks.jp" || ng "/$page に連絡先 info@rictaworks.jp がありません"
done

code="$(fetch "/this-page-does-not-exist" "$TMP_DIR/notfound.html")"
[[ "$code" == "404" ]] && ok "存在しないページは 404" || ng "存在しないページが 404 ではありません（$code）"
grep -q 'href="/terms"' "$TMP_DIR/notfound.html" && ok "404 の画面にも、フッターのリンクがある" || ng "404 の画面に、フッターのリンクがありません"

code="$(fetch "/healthz" "$TMP_DIR/healthz.json")"
{ [[ "$code" == "200" ]] && grep -q '"status":"ok"' "$TMP_DIR/healthz.json"; } && ok "/healthz は従来どおり" || ng "/healthz が従来と異なります（$code）"

if [[ "${1:-}" == "--stop" ]]; then
  printf '\n--- 止めます（scripts/dc.sh stop）\n'
  scripts/dc.sh stop || ng "停止に失敗しました"
fi

printf '\n'
if [[ "$failures" -ne 0 ]]; then
  printf 'FAIL PR #36 のテストに失敗した項目があります（%d 件）\n' "$failures"
  exit 1
fi
printf 'PASS PR #36 のテストはすべて成功しました\n'
exit 0
