#!/usr/bin/env python3
"""requirements.md の変更が、8 章の制限値の表への 1 行の追記だけであることを確かめる（読み取りのみ）。

issue #5 の「requirements.md への追記（CLAUDE.md U4）」: 20.4 が設定値に挙げているのに、8 章の表と 19 章の設定の一覧に無かった
「bot 判定のスコアの閾値」を、8 章の制限値の表へ 1 行追記する。既存の記述は書き換えない（追記のみ）。

使い方: python3 -I check_requirements_diff.py <リポジトリのルート>
検査
  1. 分岐元（main との merge-base。無ければ HEAD）から、作業ツリーまでの requirements.md の差分が、追記 1 行・削除 0 行
     （作業ブランチにコミットしたあとも、コミット前も、同じ検査になる。差分が無いときは、その行を追加したコミットの差分で検査する）
  2. 追記した行が、期待する行（既定値 0.5・仮置きの注記・単位と区切り・計上の時点）と一致し、8 章の表の最後の行である
  3. 8 章の表は 8 行（日次利用枠・開始試行・同時配信数・時間上限・受付要求の頻度・転送量の予算・API の割り当て・bot 判定の閾値）
  4. 20.4 の「制限値・設定」は 9 件で、8 章の表の 8 行 + 受付停止 = 契約の setting_key の 9 件と矛盾しない
  5. 19 章の「設定」の画面は「8 章の制限値」を指す（本文の変更は不要）
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(sys.argv[1])
os.chdir(ROOT)

REQUIREMENTS = "requirements.md"
EXPECTED_ROW = (
    "| bot 判定のスコアの閾値 | 0.5（仮置き。reCAPTCHA v3 で一般に目安とされる値。運用で実測してから見直す） "
    "| 0〜1 のスコア。システム全体 | ログイン開始・YouTube 接続開始・配信の開始要求の検証 |"
)
EXPECTED_LABELS = [
    "配信の日次利用枠",
    "開始試行",
    "同時配信数",
    "1 配信の時間上限",
    "受付要求の頻度",
    "月次の送信転送量の予算",
    "YouTube API の割り当て",
    "bot 判定のスコアの閾値",
]

failures = []


def ok(message):
    print("ok   " + message)


def ng(message):
    print("FAIL " + message)
    failures.append(message)


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=False)


def base_commit():
    """作業ブランチの分岐元。main（または origin/main）との merge-base。どちらも無ければ HEAD。"""
    for ref in ("main", "origin/main"):
        result = git("merge-base", "HEAD", ref)
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip(), ref
    return git("rev-parse", "HEAD").stdout.strip(), "HEAD"


def added_removed(diff_text):
    added = [line[1:] for line in diff_text.split("\n") if line.startswith("+") and not line.startswith("+++")]
    removed = [line[1:] for line in diff_text.split("\n") if line.startswith("-") and not line.startswith("---")]
    return added, removed


def introducing_commit():
    """その行を追加したコミット（最も古いもの）。見つからなければ None。"""
    result = git("log", "--reverse", "--format=%H", "-S| bot 判定のスコアの閾値 |", "--", REQUIREMENTS)
    commits = [line for line in result.stdout.split("\n") if line.strip()]
    return commits[0] if commits else None


def section(text, heading):
    """見出し（## で始まる行）から、次の同じ階層の見出しの直前までの本文。"""
    start = text.index(heading)
    following = re.search(r"^## ", text[start + len(heading):], re.MULTILINE)
    return text[start: start + len(heading) + following.start()] if following else text[start:]


def table_rows(block):
    """最初の表の、データ行（ヘッダと区切りを除く）のセルの一覧。"""
    rows = []
    in_table = False
    for line in block.split("\n"):
        if line.startswith("|"):
            in_table = True
            rows.append([cell.strip() for cell in line.strip().strip("|").split("|")])
        elif in_table:
            break
    return rows[2:]


def main():
    base, ref = base_commit()
    print(f"分岐元: {base[:12]}（{ref} との merge-base）")
    diff = git("diff", "-U0", base, "--", REQUIREMENTS).stdout
    source = "分岐元から作業ツリーまでの差分"
    if not diff.strip():
        commit = introducing_commit()
        if commit is None:
            ng("requirements.md に、差分も、追記したコミットもありません（8 章の表へ、bot 判定のスコアの閾値の行を追記してください）")
            return finish()
        diff = git("show", "-U0", "--format=", commit, "--", REQUIREMENTS).stdout
        source = f"その行を追加したコミット {commit[:12]} の差分（すでに取り込み済み）"
    print(f"検査する差分: {source}")

    added, removed = added_removed(diff)
    hunks = re.findall(r"^@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@", diff, re.MULTILINE)
    if len(added) == 1 and len(removed) == 0:
        ok("requirements.md の変更は、追記 1 行・削除 0 行")
    else:
        ng(f"requirements.md の変更が、追記 1 行・削除 0 行ではありません（追記 {len(added)} 行・削除 {len(removed)} 行）")
    if len(hunks) == 1 and hunks[0][0] == "0" and hunks[0][1] in ("", "1"):
        ok("変更は、1 か所の純粋な挿入（既存の行を、書き換えていない）")
    else:
        ng(f"変更が、1 か所の純粋な挿入ではありません（ハンク {hunks}）")
    if added == [EXPECTED_ROW]:
        ok("追記した行が、期待する行と一致する（既定値 0.5・仮置きの注記・0〜1 のスコア・システム全体・計上の時点）")
    else:
        ng(f"追記した行が、期待する行と一致しません: {added}")

    with open(REQUIREMENTS, encoding="utf-8") as handle:
        text = handle.read()
    chapter8 = section(text, "## 8. 利用制限仕様")
    rows = table_rows(chapter8)
    labels = [row[0] for row in rows]
    if labels == EXPECTED_LABELS:
        ok("8 章の制限値の表は 8 行で、bot 判定のスコアの閾値が最後の行")
    else:
        ng(f"8 章の制限値の表の行が想定と違います: {labels}")
    if all(len(row) == 4 for row in rows):
        ok("8 章の表の各行は、4 つのセル（制限・既定値・単位と区切り・計上の時点）")
    else:
        ng("8 章の表に、セルの数が 4 でない行があります")

    chapter20 = section(text, "## 20. データ設計")
    match = re.search(r"^\| 制限値・設定 \| (\d+) \| (.+) \|$", chapter20, re.MULTILINE)
    with open("src/contracts/enums.json", encoding="utf-8") as handle:
        setting_keys = json.load(handle)["enums"]["setting_key"]["values"]
    if match and int(match.group(1)) == 9 and "bot 判定の閾値" in match.group(2) and len(setting_keys) == 9:
        ok("20.4 の「制限値・設定」は 9 件（bot 判定の閾値を含む）で、契約の setting_key の 9 件と一致する")
    else:
        ng("20.4 の「制限値・設定」の件数・内容が、9 件と一致しません")
    if len(rows) + 1 == len(setting_keys):
        ok("8 章の表の 8 行 + 受付停止（19 章の切り替え）= 設定 9 件（Settings の 9 設定と矛盾しない）")
    else:
        ng(f"8 章の表の行数 {len(rows)} + 受付停止 1 が、設定 {len(setting_keys)} 件と一致しません")

    chapter19 = section(text, "## 19. 管理画面仕様")
    if re.search(r"^\| 設定 \| 8 章の制限値と、受付停止の切り替え \|$", chapter19, re.MULTILINE):
        ok("19 章の「設定」の画面は「8 章の制限値」を指す（本文の変更は不要）")
    else:
        ng("19 章の「設定」の画面の記述が、想定と違います")
    return finish()


def finish():
    if failures:
        print(f"\nFAIL {len(failures)} 件の失敗があります")
        return 1
    print("\nPASS requirements.md の変更は、8 章の表への 1 行の追記だけです")
    return 0


if __name__ == "__main__":
    sys.exit(main())
