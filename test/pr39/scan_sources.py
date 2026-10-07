#!/usr/bin/env python3
"""issue #5 のソース（Domain Core・スペック・このテスト）に、混入してはならないものが無いことを確かめる（読み取りのみ）。

使い方
  python3 -I scan_sources.py <リポジトリのルート>   ソースを走査する
  python3 -I scan_sources.py --self-test            走査器の自己検査（合成した小さなソースで、違反を見逃さず、誤検知しないことを確かめる）

検査（CI の hygiene と同じ規則を、コメントの行も含めて、より厳しく適用する）
  deletion   削除系コマンド（ファイル・ディレクトリを消すコマンド・削除のオプション・git の削除系・docker の削除系・
             不要な資源の一括削除・言語の削除の呼び出し・Rails の削除タスク）が無い
  implicit   Ruby の標準ライブラリが、ブロックの終了や GC のときに、自動でファイル・ディレクトリを削除する呼び出しが無い
             （ブロック形式の一時ディレクトリの作成・一時ファイルのクラス。CLAUDE.md の削除の禁止は、自動の判断を含む。
             一時ディレクトリは、ブロックなしで作り、後始末は OS に任せる。対象は Ruby のソース（.rb）だけ）
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

# 検査するディレクトリ（リポジトリのルートからの相対パス）。このテスト自身のディレクトリも、実行時に加える
TARGETS = [
    "src/backend/app/domain",
    "src/backend/spec/domain",
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

# 検出の種類（キー）と、報告の文言
MESSAGES = {
    "deletion": "削除系コマンドです",
    "implicit": "標準ライブラリが、自動でファイル・ディレクトリを削除する呼び出しです（一時ディレクトリは、ブロックなしで作り、後始末は OS に任せる）",
    "emoji": "絵文字があります",
    "invisible": "不可視の書式文字が、素のまま入っています",
}


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


def implicit_deletion_rules():
    """Ruby のソースの、(分類, 正規表現) の一覧。標準ライブラリが、自動でファイル・ディレクトリを削除する呼び出し。

    ブロック形式は、呼び出しのあとに、引数（括弧つき・入れ子 2 段まで・複数行も可。または括弧なし）、そして、同じ行の do か波括弧
    （または &block の引き渡し）が続くもの。ブロックなしの作成（後始末は OS に任せる）と、コメントの行・別の名前（MyDir など）は、含めない。
    """
    before = r"(?<![A-Za-z0-9_])"  # 別の名前の一部（MyDir など）を除く。::Dir は対象
    dot = r"\s*\.\s*"
    paren_args = r"\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)"
    with_block = (
        r"(?:[ \t]*" + paren_args + r"[ \t]*(?:do\b|\{)"  # 括弧つきの引数 + do か波括弧
        r"|[ \t]*(?:do\b|\{)"  # 引数なし + do か波括弧
        r"|[ \t]+[^\n#(){}]*?[ \t]do\b"  # 括弧なしの引数 + do
        r"|[ \t]*\((?:[^()&]|\((?:[^()]|\([^()]*\))*\))*&\s*[A-Za-z_:])"  # &block の引き渡し
    )
    return [
        ("Dir.mktmpdir のブロック形式（ブロックの終了時に、ディレクトリを中身ごと削除する）", re.compile(before + r"Dir" + dot + r"mktmpdir\b" + with_block)),
        ("Tempfile.create のブロック形式（ブロックの終了時に、ファイルを削除する）", re.compile(before + r"Tempfile" + dot + r"create\b" + with_block)),
        ("Tempfile.new・Tempfile.open（GC のときに、ファイルを削除する）", re.compile(before + r"Tempfile" + dot + r"(?:new|open)\b")),
    ]


EMOJI = emoji_pattern()
DELETION = deletion_rules()
IMPLICIT = implicit_deletion_rules()


def without_comment_lines(text):
    """行全体がコメント（先頭の空白のあとが # ）の行を、空行にする（行番号は変えない）。"""
    return "\n".join("" if line.lstrip().startswith("#") else line for line in text.split("\n"))


def scan_text(text, ruby):
    """text の違反を、(行番号, 種類のキー, 詳細) の一覧で返す。ruby が真のときだけ、標準ライブラリの自動削除（implicit）を検査する。"""
    found = []
    for number, line in enumerate(text.split("\n"), start=1):
        for match in EMOJI.finditer(line):
            found.append((number, "emoji", f"U+{ord(match.group()):04X}"))
        for char in line:
            if unicodedata.category(char) in ("Cf", "Zl", "Zp"):
                found.append((number, "invisible", f"U+{ord(char):04X}"))
        for label, pattern in DELETION:
            if pattern.search(line):
                found.append((number, "deletion", label))
    if ruby:
        code = without_comment_lines(text)
        for label, pattern in IMPLICIT:
            for match in pattern.finditer(code):
                found.append((code.count("\n", 0, match.start()) + 1, "implicit", label))
    return found


def self_test_cases():
    """(説明, ソース, Ruby か, 期待する種類のキーの集合) の一覧。語・文字は、連結して組み立てる（このファイルに、素の語・絵文字を書かない）。"""
    w_rm = "r" + "m"
    w_unlink = "un" + "link"
    w_clean = "cl" + "ean"
    w_delete = "de" + "lete"
    w_down = "do" + "wn"
    emoji = chr(0x1F600)
    check_mark = chr(0x2705)
    zero_width = chr(0x200B)
    line_separator = chr(0x2028)
    ideographic_space = chr(0x3000)
    arrow = chr(0x2192)
    wave_dash = chr(0x301C)
    reference_mark = chr(0x203B)

    cases = []

    def add(label, source, ruby, expected):
        cases.append((label, source, ruby, set(expected)))

    # 削除系の語・呼び出し（deletion）
    add("削除系: ファイルを消すコマンド", f"{w_rm} -rf build", False, ["deletion"])
    add("削除系: ディレクトリを消すコマンド", f"system(\"{w_rm}dir x\")", True, ["deletion"])
    add("削除系: リンクを消すコマンド", f"{w_unlink} file", False, ["deletion"])
    add("削除系: git の削除系", f"git {w_clean} -fd", False, ["deletion"])
    add("削除系: 削除のオプション", f"tool --{w_delete} x", False, ["deletion"])
    add("削除系: 言語の削除の呼び出し", f"File.{w_delete}(path)", True, ["deletion"])
    add("削除系: 再帰の削除の呼び出し", f"FileUtils.{w_rm}_rf(path)", True, ["deletion"])
    add("削除系: docker の削除系", f"docker compose {w_down}", False, ["deletion"])
    add("削除系: Rails の削除タスク", f"bin/rails log:{w_clean[:2]}ear", False, ["deletion"])
    add("削除系ではない: 別の語の一部", "permission = format(value)", True, [])
    add("削除系ではない: 語に続く名前の一部", f"{w_rm}dir_like = 1", True, [])
    add("削除系ではない: ファイルを作る呼び出し", "File.write(path, text)", True, [])

    # 絵文字・不可視の書式文字
    add("絵文字: 顔", f"x = \"{emoji}\"", True, ["emoji"])
    add("絵文字: チェックマーク", f"x = \"{check_mark}\"", True, ["emoji"])
    add("絵文字ではない: 矢印・波ダッシュ・米印", f"x = \"{arrow}{wave_dash}{reference_mark}\"", True, [])
    add("不可視: ゼロ幅スペース", f"x = \"a{zero_width}b\"", True, ["invisible"])
    add("不可視: 行区切り", f"x = \"a{line_separator}b\"", True, ["invisible"])
    add("不可視ではない: 全角スペース（Zs）・半角スペース", f"x = \"a{ideographic_space}b c\"", True, [])

    # 標準ライブラリの自動削除（implicit）: ブロック形式の一時ディレクトリの作成
    block_forms = [
        ("do ブロック", "Dir.mktmpdir do |dir|\n  x\nend"),
        ("波括弧のブロック", "Dir.mktmpdir { |dir| x }"),
        ("単引用符の接頭辞つきの do", "Dir.mktmpdir('x') do |dir|\n  x\nend"),
        ("二重引用符の接頭辞つきの do", "Dir.mktmpdir(\"x\") do |dir|\n  x\nend"),
        ("接頭辞と置き場の 2 引数と波括弧", "Dir.mktmpdir(\"x\", \"/tmp\") { |dir| x }"),
        ("配列の引数", "Dir.mktmpdir([\"a\", \"b\"]) do |dir|\n  x\nend"),
        ("入れ子の呼び出しの引数", "Dir.mktmpdir(prefix_for(name)) do |dir|\n  x\nend"),
        ("入れ子 2 段の呼び出しの引数", "Dir.mktmpdir(a(b(c))) do |dir|\n  x\nend"),
        ("複数行の引数", "Dir.mktmpdir(\n  \"x\"\n) do |dir|\n  x\nend"),
        ("括弧なしの引数と do", "Dir.mktmpdir \"x\" do |dir|\n  x\nend"),
        ("ドットの前後の空白", "Dir . mktmpdir do |dir|\n  x\nend"),
        ("トップレベルの指定（::Dir）", "::Dir.mktmpdir do |dir|\n  x\nend"),
        ("代入の右辺", "result = Dir.mktmpdir do |dir|\n  x\nend"),
        ("ブロックの引き渡し（&block）", "Dir.mktmpdir(&block)"),
        ("接頭辞とブロックの引き渡し", "Dir.mktmpdir(\"x\", &block)"),
        ("インデントされた do", "    it \"x\" do\n      Dir.mktmpdir do |dir|\n        x\n      end\n    end"),
    ]
    for label, source in block_forms:
        add(f"自動削除: ブロック形式の Dir.mktmpdir（{label}）", source, True, ["implicit"])
    add("自動削除: Tempfile.create のブロック", "Tempfile.create(\"x\") do |file|\n  x\nend", True, ["implicit"])
    add("自動削除: Tempfile.create の波括弧のブロック", "Tempfile.create { |file| x }", True, ["implicit"])
    add("自動削除: Tempfile.open（GC のときに削除される）", "file = Tempfile.open(\"x\")", True, ["implicit"])
    add("自動削除: Tempfile.new（GC のときに削除される）", "file = Tempfile.new(\"x\")", True, ["implicit"])
    add("自動削除: 2 か所とも検出する", "Dir.mktmpdir do |a|\nend\nDir.mktmpdir { |b| }", True, ["implicit"])

    # 自動削除ではない
    non_forms = [
        ("ブロックなしの作成", "dir = Dir.mktmpdir"),
        ("接頭辞つきのブロックなしの作成", "dir = Dir.mktmpdir(\"x\")"),
        ("2 引数のブロックなしの作成", "dir = Dir.mktmpdir(\"x\", \"/tmp\")"),
        ("ブロックなしの作成のあとに、別の呼び出しの do が続く行", "dir = Dir.mktmpdir(\"x\")\nitems.each do |item|\n  x\nend"),
        ("ブロックなしの作成のあとの行が波括弧で始まる", "dir = Dir.mktmpdir(\"x\")\n{ a: 1 }.each { |k, v| x }"),
        ("ブロックなしの作成のあとの行が do で始まる名前", "dir = Dir.mktmpdir(\"x\")\ndo_something(dir)"),
        ("ブロックなしの作成に、メソッドをつなぐ", "dir = Dir.mktmpdir(\"x\").then { |path| path }"),
        ("条件つきのブロックなしの作成", "dir = Dir.mktmpdir(\"x\") if enabled"),
        ("行の末尾のコメントが do を含む", "dir = Dir.mktmpdir(\"x\") # do not clean up"),
        ("行の末尾のコメントが波括弧を含む", "dir = Dir.mktmpdir(\"x\") # { note }"),
        ("コメントの行", "# Dir.mktmpdir do |dir|"),
        ("インデントされたコメントの行", "    # Dir.mktmpdir { |dir| x }"),
        ("別のメソッド名（mktmpdir_like）", "Dir.mktmpdir_like do |dir|\nend"),
        ("別のクラス名（MyDir）", "MyDir.mktmpdir do |dir|\nend"),
        ("Tempfile.create のブロックなし（ファイルは自動では削除されない）", "file = Tempfile.create(\"x\")"),
        ("別のクラス名（MyTempfile）", "MyTempfile.new(\"x\")"),
        ("Tempfile のコメントの行", "# Tempfile.new(\"x\")"),
    ]
    for label, source in non_forms:
        add(f"自動削除ではない: {label}", source, True, [])
    add("Ruby 以外（.md など）の文章は、自動削除の検査の対象外", "Dir.mktmpdir do |dir|", False, [])
    return cases


def self_test():
    """走査器の自己検査。違反を見逃さず（赤を出す）、違反でないものを誤検知しない（緑を保つ）ことを、合成したソースで確かめる。"""
    cases = self_test_cases()
    failures = 0
    for label, source, ruby, expected in cases:
        actual = {key for _, key, _ in scan_text(source, ruby)}
        if actual == expected:
            print(f"ok   {label}")
        else:
            failures += 1
            print(f"FAIL {label}: 期待 {sorted(expected)}・実際 {sorted(actual)}")
    # 行番号: コメント・複数行の引数を挟んでも、呼び出しの行を返す
    located = scan_text("# 1\nx = 1\n\nDir.mktmpdir(\n  \"x\"\n) do |dir|\nend\n", True)
    if [(line, key) for line, key, _ in located] == [(4, "implicit")]:
        print("ok   自動削除: 違反の行番号は、呼び出しの始まりの行")
    else:
        failures += 1
        print(f"FAIL 自動削除: 違反の行番号が想定と違います: {located}")
    print()
    print(f"自己検査 {len(cases) + 1} 件、失敗 {failures} 件")
    if failures:
        print("FAIL 走査器の自己検査に失敗しました")
        return 1
    print("PASS 走査器は、違反を検出し、違反でないものを誤検知しません")
    return 0


def target_files(root, targets):
    found = []
    for target in targets:
        base = os.path.join(root, target)
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


def scan_repository(root):
    here = os.path.dirname(os.path.abspath(__file__))
    targets = TARGETS + [os.path.relpath(here, root)]
    problems = []
    checked = 0
    for path in target_files(root, targets):
        rel = os.path.relpath(path, root)
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
        for number, key, detail in scan_text(text, ruby=path.endswith(".rb")):
            problems.append(f"{rel}:{number}: {MESSAGES[key]}（{detail}）")
    print(f"{checked} ファイルを検査しました（{len(targets)} 領域）")
    if problems:
        print("問題:")
        for item in problems:
            print("  - " + item)
        return 1
    print("問題ありません（削除系コマンド・標準ライブラリの自動削除・絵文字・不可視の書式文字・UTF-8）")
    return 0


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    if len(argv) != 1 or argv[0].startswith("-"):
        print("使い方: scan_sources.py <リポジトリのルート> | --self-test")
        return 2
    return scan_repository(os.path.abspath(argv[0]))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
