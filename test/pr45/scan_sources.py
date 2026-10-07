#!/usr/bin/env python3
"""この PR の成果物（サービス・スペック・スペックの補助・このディレクトリ）を走査する（読み取りのみ）。

使い方: python3 -I scan_sources.py <リポジトリのルート>
終了コード: 0 = 問題なし / 1 = 問題あり

  1. 絵文字が無い（アイコンは FontAwesome。CLAUDE.md）。範囲は、.github/workflows/ci.yml の hygiene の表と同じ
  2. 削除系コマンドが無い（CLAUDE.md「削除系コマンドの禁止」）。語の判定は、ci.yml の hygiene と同じ規則。
     CI は、実行権限つきのファイルと scripts/ などだけを検査するが、ここでは、この PR の成果物すべて（実行権限の無い Ruby を含む）を検査する。
     検査しない行は、コメントの行（行頭の空白のあとが #）だけ
  3. 資格情報らしい文字列が無い（鍵のブロック・主な API キーの形式。値は、テストを含め、明らかなダミーだけ）

実時計の参照・日本語の文字列リテラル・契約の固定値の直書きは、Ruby の字句解析が要るため、scan_services.rb が検査する。
削除系の語は、このファイルにも素のまま書かない（ci.yml と同じく、語の 1 文字を [] で囲む）。
"""
import glob
import os
import re
import sys

ROOT = os.path.abspath(sys.argv[1])

# このスクリプトのあるディレクトリ（PR の番号が決まる前後で名前が変わる）。ROOT からの相対パスで、自分の場所を解く
OWN_DIR = os.path.relpath(os.path.dirname(os.path.abspath(__file__)), ROOT)

# この PR の成果物。app/services と spec/services には、ほかの issue のファイルも入るため、ファイル名を挙げる
PATTERNS = [
    "src/backend/app/services/daily_allowance.rb",
    "src/backend/app/services/quota_ledger.rb",
    "src/backend/app/services/quota_ledger/*.rb",
    "src/backend/app/services/transfer_budget.rb",
    "src/backend/app/services/settings_store.rb",
    "src/backend/spec/services/daily_allowance_spec.rb",
    "src/backend/spec/services/daily_allowance_concurrency_spec.rb",
    "src/backend/spec/services/quota_ledger_*_spec.rb",
    "src/backend/spec/services/service_sources_spec.rb",
    "src/backend/spec/services/settings_store_spec.rb",
    "src/backend/spec/services/transfer_budget_spec.rb",
    "src/backend/spec/services/transfer_budget_concurrency_spec.rb",
    "src/backend/spec/services/support/ledger_support.rb",
    f"{OWN_DIR}/*",
]


def deletion_rules():
    # ci.yml の hygiene（削除系コマンド）と同じ規則。語の 1 文字を [] で囲み、この定義自身が掛からないようにする
    before = r"(?<![A-Za-z0-9_.-])"
    after = r"(?![A-Za-z0-9_./-])"
    option_before = r"(?<![A-Za-z0-9_-])"
    option_after = r"(?![A-Za-z0-9_-])"
    return [
        ("ファイル・ディレクトリを消すコマンド", [before + r"(?:r[m](?:dir|i)?|un[l]ink|sh[r]ed)" + after]),
        ("削除のオプション", [option_before + r"--?d[e]lete(?:-[a-z]+)?" + option_after]),
        ("git の削除系", [option_before + r"git\s+(?:cl[e]an|worktree\s+r[e]move|branch\s+-[A-Za-z]*[dD][A-Za-z]*)" + option_after]),
        (
            "docker の削除系",
            [option_before + r"docker[^#\n]*\sd[o]wn" + option_after, option_before + r"--r[m]" + option_after],
        ),
        ("不要な資源の一括削除", [option_before + r"pr[u]ne" + option_after]),
        (
            "言語・道具のファイル削除の呼び出し",
            [
                r"(?<![A-Za-z0-9_])(?:FileUtils|File|Dir|Pathname|fs|os|shutil)\.(?:r[m]\w*|[Rr]emove\w*|d[e]lete\w*|un[l]ink\w*)",
                option_before + r"rim[r]af" + option_after,
            ],
        ),
        (
            "Rails のファイル削除タスク",
            [option_before + r"(?:log|tmp):cl[e]ar" + option_after, option_before + r"assets:cl[o]bber" + option_after],
        ),
    ]


def emoji_pattern():
    # 絵文字の範囲（16 進数のコードポイント。A-B は範囲）。ci.yml の hygiene（絵文字）と同じ表
    table = """
        231A-231B 2328 23CF 23E9-23F3 23F8-23FA 25FD-25FE
        2600-2604 260E 2611 2614-2615 2618 261D 2620 2622-2623 2626 262A 262E-262F 2638-263A 2640 2642
        2648-2653 265F-2660 2663 2665-2666 2668 267B 267E-267F 2692-2697 2699 269B-269C 26A0-26A1 26A7
        26AA-26AB 26B0-26B1 26BD-26BE 26C4-26C5 26C8 26CE-26CF 26D1 26D3-26D4 26E9-26EA 26F0-26F5 26F7-26FA 26FD
        2702 2705 2708-270D 270F 2712 2714 2716 271D 2721 2728 2733-2734 2744 2747 274C 274E 2753-2755 2757
        2763-2764 2795-2797 27A1 27B0 27BF 2934-2935 2B05-2B07 2B1B-2B1C 2B50 2B55
        1F000-1FAFF
        FE0F 20E3 E0020-E007F
    """
    ranges = []
    for token in table.split():
        low, _, high = token.partition("-")
        ranges.append(f"\\U{int(low, 16):08X}-\\U{int(high or low, 16):08X}")
    return re.compile("[" + "".join(ranges) + "]")


SECRET_PATTERNS = [
    ("秘密鍵のブロック", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("Google の API キーの形式", re.compile(r"AIza[0-9A-Za-z_-]{35}")),
    ("Google のアクセストークンの形式", re.compile(r"\bya29\.[0-9A-Za-z_-]{20,}")),
    ("Slack のトークンの形式", re.compile(r"\bxox[baprs]-[0-9A-Za-z-]{10,}")),
    ("GitHub のトークンの形式", re.compile(r"\bgh[pousr]_[0-9A-Za-z]{36,}")),
    ("AWS のアクセスキーの形式", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
]


def is_comment(line):
    return line.lstrip().startswith("#")


def collect_files():
    found = set()
    for pattern in PATTERNS:
        for path in glob.glob(os.path.join(ROOT, pattern), recursive=True):
            if os.path.isfile(path) and not os.path.islink(path):
                found.add(path)
    return sorted(found)


def main():
    rules = [(label, [re.compile(p) for p in patterns]) for label, patterns in deletion_rules()]
    emoji = emoji_pattern()
    files = collect_files()
    problems = []
    lines_checked = 0

    for path in files:
        rel = os.path.relpath(path, ROOT)
        with open(path, "rb") as handle:
            data = handle.read()
        if b"\0" in data[:8000]:
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError as error:
            problems.append(f"{rel}: UTF-8 として読めない（判定できないため、失敗にする）: {error}")
            continue
        for number, line in enumerate(text.split("\n"), 1):
            lines_checked += 1
            match = emoji.search(line)
            if match:
                problems.append(f"{rel}:{number}: 絵文字があります（U+{ord(match.group()):04X}）")
            for label, found in SECRET_PATTERNS:
                if found.search(line):
                    problems.append(f"{rel}:{number}: 資格情報らしい文字列があります（{label}）")
            if is_comment(line):
                continue
            for label, patterns in rules:
                if any(pattern.search(line) for pattern in patterns):
                    problems.append(f"{rel}:{number}: 削除系コマンドの語があります（{label}）: {line.strip()[:120]}")

    print(f"走査したファイル {len(files)} 件・{lines_checked} 行（絵文字・削除系コマンドの語・資格情報の形式）")
    if len(files) < 20:
        problems.append(f"走査したファイルが少なすぎます（{len(files)} 件）。対象のパターンが、成果物に合っていません")
    if problems:
        print("問題:")
        for item in problems:
            print("  - " + item)
        return 1
    print("問題ありません")
    return 0


if __name__ == "__main__":
    sys.exit(main())
