#!/usr/bin/env python3
"""issue #6（配信の生命周期の Domain Core）の変更ファイルに、絵文字と削除系コマンドの語が無いことを確かめる（読み取りのみ）。

対象
  src/backend/app/domain/ の issue #6 のファイル（DOMAIN_FILES）
  src/backend/spec/domain/lifecycle/ のすべてのテキストファイル
  このスクリプトのあるディレクトリのすべてのテキストファイル

使い方: python3 -I scan_text_hygiene.py <リポジトリのルート>

CI の hygiene（.github/workflows/ci.yml の deletion・emoji）と同じ種類の語を、対象のすべての行（コメントの行を除く。
Markdown は、見出しの行も含めて検査する）に対して、CI より厳しく（シェル・実行権限つきのファイルに限らず）検査する。
削除系コマンドの語は、このファイルのソースにそのまま書かない（断片を連結して組み立てる。CI の hygiene が検査する）。
"""
import os
import re
import sys

ROOT = os.path.abspath(sys.argv[1])
HERE = os.path.dirname(os.path.abspath(__file__))

DOMAIN_FILES = [
    "lifecycle_checks", "lifecycle_time_units", "directive", "broadcast_snapshot", "broadcast_state_machine",
    "termination_planner", "deadline_evaluator", "settlement_rules", "prior_settlement_check",
    "stream_replacement_policy", "retention_policy",
]
TEXT_SUFFIXES = {".md", ".json", ".rb", ".sh", ".py", ".txt", ".yml", ".yaml"}
SKIP_DIRS = {"node_modules", ".cache", "vendor", "__pycache__"}

# 絵文字・絵記号の主な範囲（文章に使う記号（矢印・丸数字など）は含めない）。このファイルに絵文字を書かないよう、コードポイントで持つ
EMOJI_RANGES = [
    (0x1F000, 0x1FAFF), (0x2600, 0x26FF), (0x2700, 0x27BF), (0x2300, 0x23FF), (0x2900, 0x297F), (0x2B00, 0x2BFF),
    (0xFE0F, 0xFE0F), (0x20E3, 0x20E3), (0xE0020, 0xE007F),
]
# 文章に使う記号（絵文字の範囲に含まれるが、異体字選択子が付かない限り、絵文字としない）
PROSE_SYMBOLS = {0x2190, 0x2191, 0x2192, 0x2193, 0x2194, 0x25B6, 0x25C0, 0x2B05, 0x2B06, 0x2B07, 0x2B1B, 0x2B1C}
EMOJI = re.compile("[" + "".join(chr(low) + "-" + chr(high) for low, high in EMOJI_RANGES) + "]")


def w(*parts):
    """語の断片を連結する。"""
    return "".join(parts)


# CI の hygiene（deletion）の規則と同じ種類。語は、断片を連結して組み立てる
BEFORE = r"(?<![A-Za-z0-9_.-])"
AFTER = r"(?![A-Za-z0-9_./-])"
OPT_BEFORE = r"(?<![A-Za-z0-9_-])"
OPT_AFTER = r"(?![A-Za-z0-9_-])"
RULES = [
    ("ファイル・ディレクトリを消すコマンド", re.compile(BEFORE + "(?:" + w("r", "m") + "(?:dir|i)?|" + w("un", "link") + "|" + w("sh", "red") + ")" + AFTER)),
    ("削除のオプション", re.compile(OPT_BEFORE + "--?" + w("d", "elete") + "(?:-[a-z]+)?" + OPT_AFTER)),
    ("git の削除系", re.compile(OPT_BEFORE + "git\\s+(?:" + w("cl", "ean") + "|worktree\\s+" + w("r", "emove") + "|branch\\s+-[A-Za-z]*[dD][A-Za-z]*)" + OPT_AFTER)),
    ("docker の削除系", re.compile(OPT_BEFORE + "docker[^#\\n]*\\s" + w("d", "own") + OPT_AFTER)),
    ("docker の削除系（オプション）", re.compile(OPT_BEFORE + "--" + w("r", "m") + OPT_AFTER)),
    ("不要な資源の一括削除", re.compile(OPT_BEFORE + w("pr", "une") + OPT_AFTER)),
    (
        "言語・道具のファイル削除の呼び出し",
        re.compile(
            r"(?<![A-Za-z0-9_])(?:FileUtils|File|Dir|Pathname|fs|os|shutil)\.(?:"
            + w("r", "m") + r"\w*|[Rr]" + w("e", "move") + r"\w*|" + w("d", "elete") + r"\w*|" + w("un", "link") + r"\w*)"
        ),
    ),
    ("再帰的な削除の道具", re.compile(OPT_BEFORE + w("rim", "raf") + OPT_AFTER)),
    ("Rails のファイル削除タスク", re.compile(OPT_BEFORE + "(?:log|tmp):" + w("cl", "ear") + OPT_AFTER)),
]


def target_files():
    paths = [os.path.join(ROOT, "src", "backend", "app", "domain", name + ".rb") for name in DOMAIN_FILES]
    for base in (os.path.join(ROOT, "src", "backend", "spec", "domain", "lifecycle"), HERE):
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in filenames:
                if os.path.splitext(name)[1] in TEXT_SUFFIXES:
                    paths.append(os.path.join(dirpath, name))
    return sorted(set(paths))


def is_comment_line(path, line):
    # Markdown の # は見出しなので、コメントとして除かない
    return os.path.splitext(path)[1] != ".md" and line.lstrip().startswith("#")


def has_emoji(line):
    for match in EMOJI.finditer(line):
        if ord(match.group(0)) not in PROSE_SYMBOLS:
            return True
    return False


def main():
    problems = []
    checked_files = 0
    checked_lines = 0
    for path in target_files():
        rel = os.path.relpath(path, ROOT)
        if not os.path.isfile(path):
            problems.append(f"{rel}: 対象のファイルがありません")
            continue
        checked_files += 1
        with open(path, encoding="utf-8") as handle:
            for number, line in enumerate(handle, start=1):
                checked_lines += 1
                if has_emoji(line):
                    problems.append(f"{rel}:{number}: 絵文字があります")
                if is_comment_line(path, line):
                    continue
                for label, pattern in RULES:
                    if pattern.search(line):
                        problems.append(f"{rel}:{number}: {label}の語があります")
                        break

    print(f"{checked_files} ファイル・{checked_lines} 行を検査しました")
    if problems:
        print("問題:")
        for item in problems:
            print("  - " + item)
        return 1
    print("問題ありません（絵文字・削除系コマンドの語は、ありません）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
