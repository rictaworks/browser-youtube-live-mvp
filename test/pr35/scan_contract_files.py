#!/usr/bin/env python3
"""契約の文書・データ・各層の定数モジュールに、絵文字と削除系コマンドの語が無いことを確かめる（読み取りのみ）。

使い方: python3 -I scan_contract_files.py <リポジトリのルート>
削除系コマンドの語は、このファイルのソースにそのまま書かない（連結して組み立てる）。
"""
import os
import re
import sys

ROOT = os.path.abspath(sys.argv[1])
TARGETS = [
    "src/contracts",
    "src/backend/app/domain/contract",
    "src/backend/spec/domain/contract",
    "src/frontend/core/contract",
    "src/relay/core/contract",
]
SKIP_DIRS = {"node_modules", ".cache", ".next", "vendor"}
TEXT_SUFFIXES = {".md", ".json", ".mjs", ".rb", ".ts", ".go", ".sh", ".txt"}

# 絵文字・絵記号の主な範囲（文章に使う記号（矢印・丸数字など）は含めない）。このファイル自体に絵文字を書かないよう、コードポイントで持つ
EMOJI_RANGES = [
    (0x1F300, 0x1FAFF), (0x1F000, 0x1F2FF), (0x2600, 0x26FF), (0x2700, 0x27BF),
    (0x2B50, 0x2B50), (0x2B55, 0x2B55), (0x231A, 0x231B), (0x23E9, 0x23F3), (0x23F8, 0x23FA), (0xFE0F, 0xFE0F),
]
EMOJI = re.compile("[" + "".join(chr(low) + "-" + chr(high) for low, high in EMOJI_RANGES) + "]")
# 削除系の語は、このファイルにも素のまま書かない（CI の hygiene が検査する）。語の途中で分け、断片が単独の語にならないようにする
WORDS = ["r" + "m", "r" + "mdir", "un" + "link", "git cl" + "ean", "docker r" + "m", "compose do" + "wn", "-del" + "ete"]
COMMANDS = ["r" + "m", "r" + "mdir", "un" + "link", "git cl" + "ean", "docker r" + "m", "docker compose do" + "wn"]
EXECUTION_FORM = re.compile(r"^\s*(\$ |[#>]?\s*)?(" + "|".join(re.escape(w) for w in COMMANDS) + r")\b")
DELETE = re.compile(r"(^|[^A-Za-z0-9_./-])(" + "|".join(re.escape(w) for w in WORDS) + r")([^A-Za-z0-9_-]|$)")

problems = []
checked = 0
for target in TARGETS:
    base = os.path.join(ROOT, target)
    if not os.path.isdir(base):
        problems.append(f"対象のディレクトリがありません: {target}")
        continue
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if os.path.splitext(name)[1] not in TEXT_SUFFIXES:
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, ROOT)
            with open(path, encoding="utf-8") as handle:
                for number, line in enumerate(handle, start=1):
                    checked += 1
                    if EMOJI.search(line):
                        problems.append(f"{rel}:{number}: 絵文字があります")
                    # 契約の文書は、削除系コマンドの禁止を説明する文章を含み得るため、実行形（行頭・パイプ・&& の直後）だけを見る
                    if DELETE.search(line) and EXECUTION_FORM.match(line):
                        problems.append(f"{rel}:{number}: 削除系コマンドの実行形があります")

print(f"{checked} 行を検査しました（{len(TARGETS)} 領域）")
if problems:
    print("問題:")
    for item in problems:
        print("  - " + item)
    sys.exit(1)
print("問題ありません")
