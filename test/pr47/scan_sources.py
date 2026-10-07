#!/usr/bin/env python3
"""issue #19（中継: FLV 多重化と RTMPS 送出）の成果物を、読み取りだけで走査する。

  使い方: python3 -I scan_sources.py <リポジトリのルート> <このテストのディレクトリ>
          python3 -I scan_sources.py --self-test

走査の内容:
  1. 対象のファイルが UTF-8 として読めること（読めなければ、判定できないので失敗にする）
  2. 絵文字・不可視の書式文字（ゼロ幅スペースなど）が無いこと。日本語（ひらがな・カタカナ・漢字・全角の記号）以外の非 ASCII の文字が無いこと
  3. 削除系コマンド・削除の呼び出しの語が無いこと（CI の hygiene と同じ規則を、コメントも含めて、Go のソース・テストへ適用する）
  4. src/relay/go.mod が、go-rtmp v0.0.7・go-flv v0.3.1 を固定していること（直接の依存）。go.sum に、その版の記録があること
  5. src/relay/core が、internal を参照しないこと（core から internal を参照しない）
  6. internal/flv・internal/rtmps が、Go のソース以外のファイル（試作の残り・バックアップ）を持たず、実行権限のある Go のソースが無いこと

削除系の語は、このファイルのソースにそのまま書かない（連結して組み立てる。CI の hygiene が、実行権限のあるファイルを検査するため）。
終了コード: 0 = 問題なし / 1 = 問題あり
"""
import os
import re
import stat
import sys

# ---- 検査の定義 ----

# 絵文字・絵記号の主な範囲（コードポイントで持つ。このファイルへ絵文字を書かない）
EMOJI_RANGES = [
    (0x1F300, 0x1FAFF), (0x1F000, 0x1F2FF), (0x2600, 0x26FF), (0x2700, 0x27BF),
    (0x2B50, 0x2B50), (0x2B55, 0x2B55), (0x231A, 0x231B), (0x23E9, 0x23F3), (0x23F8, 0x23FA), (0xFE0F, 0xFE0F),
]
# 不可視の書式文字
INVISIBLE_RANGES = [
    (0x00AD, 0x00AD), (0x180E, 0x180E), (0x200B, 0x200F), (0x2028, 0x202E), (0x2060, 0x206F), (0xFE00, 0xFE0F), (0xFEFF, 0xFEFF),
    (0xE0000, 0xE007F),
]
# 日本語として許す範囲
JAPANESE_RANGES = [
    (0x3000, 0x303F), (0x3040, 0x309F), (0x30A0, 0x30FF), (0x4E00, 0x9FFF), (0xFF00, 0xFFEF),
]

TEXT_SUFFIXES = {".go", ".md", ".json", ".py", ".sh", ".mod", ".sum", ".txt"}


def in_ranges(code, ranges):
    return any(low <= code <= high for low, high in ranges)


def join(*parts):
    return "".join(parts)


def deletion_rules():
    """CI の hygiene（削除系コマンドの検査）と同じ規則。語は、連結して組み立てる。"""
    before = r"(?<![A-Za-z0-9_.-])"
    after = r"(?![A-Za-z0-9_./-])"
    option_before = r"(?<![A-Za-z0-9_-])"
    option_after = r"(?![A-Za-z0-9_-])"
    w_rm, w_unlink, w_shred = join("r", "m"), join("un", "link"), join("sh", "red")
    w_delete = join("d", "elete")
    return [
        ("ファイル・ディレクトリを消すコマンド", [before + "(?:" + w_rm + "(?:dir|i)?|" + w_unlink + "|" + w_shred + ")" + after]),
        ("削除のオプション", [option_before + "--?" + w_delete + "(?:-[a-z]+)?" + option_after]),
        ("git の削除系", [option_before + r"git\s+(?:" + join("cl", "ean") + r"|worktree\s+" + join("re", "move") + r"|branch\s+-[A-Za-z]*[dD][A-Za-z]*)" + option_after]),
        ("docker の削除系", [option_before + r"docker[^#\n]*\s" + join("do", "wn") + option_after, option_before + "--" + w_rm + option_after]),
        ("不要な資源の一括削除", [option_before + join("pr", "une") + option_after]),
        (
            "言語・道具のファイル削除の呼び出し",
            [
                r"(?<![A-Za-z0-9_])(?:FileUtils|File|Dir|Pathname|fs|os|shutil)\.(?:" + w_rm + r"\w*|[Rr]" + join("em", "ove") + r"\w*|" + w_delete + r"\w*|" + w_unlink + r"\w*)",
                option_before + join("rim", "raf") + option_after,
            ],
        ),
        ("Rails のファイル削除タスク", [option_before + r"(?:log|tmp):" + join("cl", "ear") + option_after, option_before + "assets:" + join("cl", "obber") + option_after]),
    ]


def scan_text(label, text):
    """1 つのファイルの本文を検査し、問題の一覧を返す。"""
    problems = []
    rules = [(name, [re.compile(pattern) for pattern in patterns]) for name, patterns in deletion_rules()]
    for number, line in enumerate(text.split("\n"), start=1):
        for column, char in enumerate(line, start=1):
            code = ord(char)
            if code < 0x80:
                continue
            if in_ranges(code, EMOJI_RANGES):
                problems.append(f"{label}:{number}:{column}: 絵文字があります（U+{code:04X}）")
            elif in_ranges(code, INVISIBLE_RANGES):
                problems.append(f"{label}:{number}:{column}: 不可視の書式文字があります（U+{code:04X}）")
            elif not in_ranges(code, JAPANESE_RANGES):
                problems.append(f"{label}:{number}:{column}: 日本語以外の非 ASCII の文字があります（U+{code:04X}）")
        for name, patterns in rules:
            if any(pattern.search(line) for pattern in patterns):
                problems.append(f"{label}:{number}: 削除系の語があります（{name}）: {line.strip()[:120]}")
    return problems


def check_go_mod(go_mod_text, go_sum_text):
    """go.mod が、go-rtmp・go-flv を、指定の版で、直接の依存として固定していること。go.sum に、その版の記録があること。"""
    problems = []
    pins = [("github.com/yutopp/go-rtmp", "v0.0.7"), ("github.com/yutopp/go-flv", "v0.3.1")]
    for module, version in pins:
        pattern = re.compile(r"^\s*(?:require\s+)?" + re.escape(module) + r"\s+" + re.escape(version) + r"\s*(//.*)?$", re.MULTILINE)
        found = pattern.search(go_mod_text)
        if not found:
            problems.append(f"go.mod: {module} {version} がありません")
        elif "indirect" in (found.group(1) or ""):
            problems.append(f"go.mod: {module} が indirect です（直接の依存として固定します）")
        others = re.findall(r"^\s*(?:require\s+)?" + re.escape(module) + r"\s+(v\S+)", go_mod_text, re.MULTILINE)
        if len(others) != 1:
            problems.append(f"go.mod: {module} の版の記述が {len(others)} 件あります（1 件であること）")
        if (module + " " + version + " h1:") not in go_sum_text or (module + " " + version + "/go.mod h1:") not in go_sum_text:
            problems.append(f"go.sum: {module} {version} の記録（ソースと go.mod の h1）が不足しています")
    return problems


IMPORT_INTERNAL = re.compile(r'"github\.com/rictaworks/browser-youtube-live-mvp/relay/internal(?:/[^"]*)?"')


def check_core_independence(label, text):
    """core の Go のソースが、internal を参照しないこと。"""
    problems = []
    for number, line in enumerate(text.split("\n"), start=1):
        if IMPORT_INTERNAL.search(line):
            problems.append(f"{label}:{number}: core が internal を参照しています: {line.strip()}")
    return problems


def read_text(path, problems):
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError as error:
        problems.append(f"{path}: 読めません: {error}")
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as error:
        problems.append(f"{path}: UTF-8 として読めません（判定できないため、失敗にします）: {error}")
        return None


def walk_files(base):
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if d not in {".cache", "node_modules", "__pycache__", "testdata"})
        for name in sorted(filenames):
            yield os.path.join(dirpath, name)


def scan_repository(root, test_dir):
    problems = []
    checked_files = 0
    checked_lines = 0

    targets = [
        os.path.join(root, "src", "relay", "internal", "flv"),
        os.path.join(root, "src", "relay", "internal", "rtmps"),
        test_dir,
    ]
    for base in targets:
        if not os.path.isdir(base):
            problems.append(f"対象のディレクトリがありません: {base}")
            continue
        for path in walk_files(base):
            relative = os.path.relpath(path, root)
            if os.path.splitext(path)[1] not in TEXT_SUFFIXES:
                problems.append(f"{relative}: 想定していない種類のファイルです（試作の残り・バックアップではないこと）")
                continue
            text = read_text(path, problems)
            if text is None:
                continue
            checked_files += 1
            checked_lines += text.count("\n") + 1
            problems.extend(scan_text(relative, text))

    # 6. Go のソースの置き場：実行権限が無いこと（実行権限のあるファイルは、CI が、スクリプトとして検査する）
    for package in ("flv", "rtmps"):
        base = os.path.join(root, "src", "relay", "internal", package)
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base)):
            path = os.path.join(base, name)
            if os.path.isfile(path) and os.stat(path).st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH):
                problems.append(f"{os.path.relpath(path, root)}: Go のソースに実行権限があります")

    # 4. go.mod の固定
    relay = os.path.join(root, "src", "relay")
    go_mod = read_text(os.path.join(relay, "go.mod"), problems)
    go_sum = read_text(os.path.join(relay, "go.sum"), problems)
    if go_mod is not None and go_sum is not None:
        problems.extend(check_go_mod(go_mod, go_sum))

    # 5. core が internal を参照しない
    core = os.path.join(relay, "core")
    core_files = 0
    if os.path.isdir(core):
        for path in walk_files(core):
            if path.endswith(".go"):
                text = read_text(path, problems)
                if text is not None:
                    core_files += 1
                    problems.extend(check_core_independence(os.path.relpath(path, root), text))
    else:
        problems.append(f"core のディレクトリがありません: {core}")
    return problems, checked_files, checked_lines, core_files


# ---- 自己検査（合成したソースで、違反を見逃さず、違反でないものを誤検知しないこと） ----

def self_test():
    failures = []

    def expect(name, condition):
        if not condition:
            failures.append(name)

    emoji = chr(0x1F600)
    zero_width = chr(0x200B)
    arrow = chr(0x2192)
    japanese = "".join(chr(code) for code in (0x65E5, 0x672C, 0x8A9E))  # 日本語

    expect("絵文字を検出", any("絵文字" in p for p in scan_text("a.go", "// " + emoji)))
    expect("ゼロ幅スペースを検出", any("不可視" in p for p in scan_text("a.go", "x" + zero_width + "y")))
    expect("異体字選択子を検出", any(("不可視" in p or "絵文字" in p) for p in scan_text("a.go", "x" + chr(0xFE0F))))
    expect("矢印（日本語以外の非 ASCII）を検出", any("日本語以外" in p for p in scan_text("a.go", "// a " + arrow + " b")))
    expect("日本語は可", scan_text("a.go", "// " + japanese + "\n") == [])
    expect("全角の記号は可", scan_text("a.go", "// " + chr(0xFF08) + chr(0xFF09) + chr(0x3001)) == [])

    w_rm, w_rmdir, w_unlink, w_shred = join("r", "m"), join("r", "mdir"), join("un", "link"), join("sh", "red")
    for sample in [
        w_rm + " -rf /tmp/x",
        "  " + w_rm + " file",
        w_rmdir + " d",
        w_unlink + " f",
        w_shred + " f",
        "git " + join("cl", "ean") + " -fd",
        "docker " + join("com", "pose") + " " + join("do", "wn"),
        "docker run --" + w_rm + " img",
        "docker system " + join("pr", "une"),
        "os." + join("Re", "move") + "(p)",
        "os." + join("Re", "moveAll") + "(p)",
        "FileUtils." + w_rm + "_rf(p)",
        "rsync --" + join("del", "ete") + " a b",
    ]:
        expect("削除系を検出: " + sample, any("削除系" in p for p in scan_text("a.sh", sample)))
    for sample in [
        "// pruneUnconnected closes the sockets",
        "func TestKillSwitchPrunesTheSockets() {}",
        "x := confirm(1)",
        "firmware := 1",
        "rmsg := 1",
        "// the file is removed from the list",
        "syscall.Close(fd)",
        "conn.Shutdown()",
        "docker build --target production src/relay",
        "go test -race ./...",
    ]:
        expect("誤検知しない: " + sample, scan_text("a.go", sample) == [])

    good_mod = "require (\n\tgithub.com/yutopp/go-flv v0.3.1\n\tgithub.com/yutopp/go-rtmp v0.0.7\n)\n"
    good_sum = (
        "github.com/yutopp/go-flv v0.3.1 h1:x\ngithub.com/yutopp/go-flv v0.3.1/go.mod h1:x\n"
        "github.com/yutopp/go-rtmp v0.0.7 h1:x\ngithub.com/yutopp/go-rtmp v0.0.7/go.mod h1:x\n"
    )
    expect("go.mod の固定を受理", check_go_mod(good_mod, good_sum) == [])
    expect("go-rtmp の版違いを検出", any("go-rtmp" in p for p in check_go_mod(good_mod.replace("v0.0.7", "v0.0.6"), good_sum)))
    expect("go-flv の版違いを検出", any("go-flv" in p for p in check_go_mod(good_mod.replace("v0.3.1", "v0.3.0"), good_sum)))
    expect("go-rtmp の欠落を検出", any("go-rtmp" in p for p in check_go_mod("require github.com/yutopp/go-flv v0.3.1\n", good_sum)))
    expect("indirect を検出", any("indirect" in p for p in check_go_mod(good_mod.replace("v0.0.7", "v0.0.7 // indirect"), good_sum)))
    expect("版の二重記述を検出", any("2 件" in p for p in check_go_mod(good_mod + "\tgithub.com/yutopp/go-rtmp v0.0.7\n", good_sum)))
    expect("go.sum の不足を検出", any("go.sum" in p for p in check_go_mod(good_mod, "github.com/yutopp/go-flv v0.3.1 h1:x\n")))

    expect(
        "core から internal の参照を検出",
        len(check_core_independence("core/x.go", 'import "github.com/rictaworks/browser-youtube-live-mvp/relay/internal/rtmps"\n')) == 1,
    )
    expect(
        "core から core の参照は可",
        check_core_independence("core/x.go", 'import "github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"\n') == [],
    )

    if failures:
        print("自己検査に失敗しました:")
        for name in failures:
            print("  - " + name)
        return 1
    print("自己検査: すべて成功しました")
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) != 3:
        print("使い方: scan_sources.py <リポジトリのルート> <このテストのディレクトリ> | --self-test", file=sys.stderr)
        return 2
    root, test_dir = os.path.abspath(argv[1]), os.path.abspath(argv[2])
    problems, files, lines, core_files = scan_repository(root, test_dir)
    print(f"{files} ファイル（{lines} 行）と、core の Go のソース {core_files} ファイルを検査しました")
    if problems:
        print("問題:")
        for problem in problems:
            print("  - " + problem)
        return 1
    print("問題ありません")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
