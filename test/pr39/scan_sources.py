#!/usr/bin/env python3
"""issue #5 のソース（Domain Core・スペック・このテスト）に、混入してはならないものが無いことを確かめる（読み取りのみ）。

使い方: python3 -I scan_sources.py <リポジトリのルート>

検査（CI の hygiene と同じ規則を、コメントの行も含めて、より厳しく適用する）
  deletion   削除系コマンド（ファイル・ディレクトリを消すコマンド・削除のオプション・git の削除系・docker の削除系・
             不要な資源の一括削除・言語の削除の呼び出し・Rails の削除タスク）が無い
  emoji      絵文字が無い（CI の絵文字の範囲と同じ表。アイコンは FontAwesome。CLAUDE.md）
  invisible  不可視の書式文字（ゼロ幅スペースなど。Unicode の分類 Cf・Zl・Zp）が、素のまま入っていない
             （表記は、エスケープ（バックスラッシュ + u + 波括弧）で書く。ツール経由の書き込みで、エスケープが生の文字へ
             変換される事故を検知する）
  utf8       UTF-8 として読める
削除系の語は、このファイルのソースにも素のまま書かない（語の途中で分け、連結して組み立てる）。
"""
import os
import re
import sys
import unicodedata

ROOT = os.path.abspath(sys.argv[1])
HERE = os.path.dirname(os.path.abspath(__file__))

# 検査するディレクトリ（リポジトリのルートからの相対パス）。このテスト自身のディレクトリも含める
TARGETS = [
    "src/backend/app/domain",
    "src/backend/spec/domain",
    os.path.relpath(HERE, ROOT),
]
SKIP_DIRS = {"node_modules", ".cache", "vendor", ".next", "tmp", "__pycache__"}

# CI の hygiene（.github/workflows/ci.yml の「src/ に絵文字が無いこと」）と同じ範囲の表（コードポイントの 16 進数。A-B は範囲）
EMOJI_TABLE = """
    231A-231B 2328 23CF 23E9-23F3 23F8-23FA 25FD-25FE
    2600-2604 260E 2611 2614-2615 2618 261D 2620 2622-2623 2626 262A 262E-262F 2638-263A 2640 2642
    2648-2653 265F-2660 2663 2665-2666 2668 267B 267E-267F 2692-2697 2699 269B-269C 26A0-26A1 26A7
    26AA-26AB 26B0-26B1 26BD-26BE 26C4-26C5 26C8 26CE-26CF 26D1 26D3-26D4 26E9-26EA 26F0-26F5 26F7-26FA 26FD
    2702 2705 2708-270D 270F 2712 2714 2716 271D 2721 2728 2733-2734 2744 2747 274C 274E 2753-2755 2757
    2763-2764 2795-2797 27A1 27B0 27BF 2934-2935 2B05-2B07 2B1B-2B1C 2B50 2B55
    1F000-1FAFF
    FE0F 20E3 E0020-E007F
"""


def emoji_pattern():
    parts = []
    for token in EMOJI_TABLE.split():
        low, _, high = token.partition("-")
        parts.append(re.escape(chr(int(low, 16))) + "-" + re.escape(chr(int(high or low, 16))))
    return re.compile("[" + "".join(parts) + "]")


def deletion_rules():
    """(分類, 正規表現) の一覧。語は、連結して組み立てる（このファイルに、素の語を書かない）。"""
    before = r"(?<![A-Za-z0-9_.-])"
    after = r"(?![A-Za-z0-9_./-])"
    option_before = r"(?<![A-Za-z0-9_-])"
    option_after = r"(?![A-Za-z0-9_-])"
    words = "(?:r" + "m(?:dir|i)?|un" + "link|sh" + "red)"
    options = "--?d" + "elete(?:-[a-z]+)?"
    git = "git\\s+(?:cl" + "ean|worktree\\s+r" + "emove|branch\\s+-[A-Za-z]*[dD][A-Za-z]*)"
    docker_down = "docker[^#\\n]*\\sd" + "own"
    docker_rm = "--r" + "m"
    bulk = "pr" + "une"
    calls = "(?<![A-Za-z0-9_])(?:FileUtils|File|Dir|Pathname|fs|os|shutil)\\.(?:r" + "m\\w*|[Rr]" + "emove\\w*|d" + "elete\\w*|un" + "link\\w*)"
    recursive_form = "rim" + "raf"
    rails_clear = "(?:log|tmp):cl" + "ear"
    rails_clobber = "assets:cl" + "obber"
    return [
        ("ファイル・ディレクトリを消すコマンド", re.compile(before + words + after)),
        ("削除のオプション", re.compile(option_before + options + option_after)),
        ("git の削除系", re.compile(option_before + git + option_after)),
        ("docker の削除系", re.compile(option_before + docker_down + option_after)),
        ("docker の削除系（オプション）", re.compile(option_before + docker_rm + option_after)),
        ("不要な資源の一括削除", re.compile(option_before + bulk + option_after)),
        ("言語・道具のファイル削除の呼び出し", re.compile(calls)),
        ("言語・道具のファイル削除の呼び出し（再帰）", re.compile(option_before + recursive_form + option_after)),
        ("Rails のファイル削除タスク", re.compile(option_before + rails_clear + option_after)),
        ("Rails のファイル削除タスク（アセット）", re.compile(option_before + rails_clobber + option_after)),
    ]


def target_files():
    found = []
    for target in TARGETS:
        base = os.path.join(ROOT, target)
        if not os.path.isdir(base):
            print(f"対象のディレクトリがありません: {target}")
            sys.exit(2)
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
            for name in sorted(filenames):
                path = os.path.join(dirpath, name)
                if not os.path.islink(path):
                    found.append(path)
    return found


def main():
    emoji = emoji_pattern()
    rules = deletion_rules()
    problems = []
    checked = 0
    for path in target_files():
        rel = os.path.relpath(path, ROOT)
        with open(path, "rb") as handle:
            data = handle.read()
        if b"\0" in data[:8000]:
            continue  # バイナリ
        checked += 1
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError as error:
            problems.append(f"{rel}: UTF-8 として読めません（{error}）")
            continue
        for number, line in enumerate(text.split("\n"), start=1):
            for match in emoji.finditer(line):
                problems.append(f"{rel}:{number}: 絵文字があります U+{ord(match.group()):04X}")
            for char in line:
                if unicodedata.category(char) in ("Cf", "Zl", "Zp"):
                    problems.append(f"{rel}:{number}: 不可視の書式文字が、素のまま入っています U+{ord(char):04X}")
            for label, pattern in rules:
                if pattern.search(line):
                    problems.append(f"{rel}:{number}: 削除系コマンドです（{label}）")
    print(f"{checked} ファイルを検査しました（{len(TARGETS)} 領域）")
    if problems:
        print("問題:")
        for item in problems:
            print("  - " + item)
        return 1
    print("問題ありません（削除系コマンド・絵文字・不可視の書式文字・UTF-8）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
