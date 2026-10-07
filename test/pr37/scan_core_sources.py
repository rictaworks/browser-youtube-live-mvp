#!/usr/bin/env python3
"""issue #18（中継 Domain Core）のソースを走査する（読み取りのみ。対象のファイルは変更しない）。

使い方:
  python3 -I scan_core_sources.py <リポジトリのルート>   走査する（違反があれば終了コード 1）
  python3 -I scan_core_sources.py --self-test           走査器そのものの検査（違反を見逃さず、違反でないものを誤検知しない）

検査:
  1. 対象のファイルが、そろっている（空振りの防止。ファイル名の一覧は、下の EXPECTED_FILES）
  2. 絵文字が無い（アイコンは FontAwesome。CLAUDE.md）。対象: src/relay/core と、このディレクトリ
  3. 削除系のコマンド・関数呼び出しが無い（CLAUDE.md）。対象: 同上
  4. Domain Core の規則（requirements.md 2.5・15 章・27 章）。対象: src/relay/core の、テスト以外の Go のソース
       - 実時計・入出力・乱数・通信に依存しない（time.Now 等・net・net/http・gorilla・gin・RTMP クライアント・os・log）
       - 標準出力へ書かない（fmt.Print 等）
       - グローバル変数を持たない（パッケージレベルの var・init）
       - コメントの外に、非 ASCII を含まない（日本語の文言の直書きが無い）
     Go のテスト（src/relay/core/rules_test.go）が、構文木で同じ規則を検査している。ここは、別の実装（正規表現）による二重の検査。
  5. 変更の範囲：src/relay の変更が、src/relay/core の下だけ（core/contract は参照のみ。go.mod・go.sum は変更しない）

削除系の語は、このファイルにそのまま書かない（断片を連結して組み立てる。CI の hygiene が、このファイルも検査する）。
"""
import os
import re
import subprocess
import sys
import tempfile

EXPECTED_FILES = [
    "doc.go",
    "rules_test.go",
    "frame/errors.go",
    "frame/frame.go",
    "frame/timeguard.go",
    "frame/frame_test.go",
    "frame/fuzz_test.go",
    "frame/timeguard_test.go",
    "frame/vectors_test.go",
    "rebase/rebase.go",
    "rebase/rebase_test.go",
    "policer/policer.go",
    "policer/policer_test.go",
    "probe/probe.go",
    "probe/probe_test.go",
    "watchdog/watchdog.go",
    "watchdog/watchdog_test.go",
    "buffer/buffer.go",
    "buffer/buffer_test.go",
    "liveness/liveness.go",
    "liveness/liveness_test.go",
]
# 契約のパッケージは参照のみ（この issue では変更しない）。変更の範囲の検査で、変更が無いことを確かめる
CONTRACT_DIR = "src/relay/core/contract/"
MIN_DOMAIN_CORE_FILES = 10
SKIP_DIRS = {"node_modules", ".cache", ".next", "vendor", "testdata", "__pycache__"}


def join(*parts):
    return "".join(parts)


# ---------------------------------------------------------------------------
# 絵文字（このファイル自体に絵文字を書かないよう、コードポイントで持つ）
# ---------------------------------------------------------------------------
EMOJI_RANGES = [
    (0x1F300, 0x1FAFF), (0x1F000, 0x1F2FF), (0x2600, 0x26FF), (0x2700, 0x27BF),
    (0x2B50, 0x2B50), (0x2B55, 0x2B55), (0x231A, 0x231B), (0x23E9, 0x23F3), (0x23F8, 0x23FA),
    (0xFE0F, 0xFE0F), (0x20E3, 0x20E3), (0xE0020, 0xE007F),
]
EMOJI = re.compile("[" + "".join(chr(low) + "-" + chr(high) for low, high in EMOJI_RANGES) + "]")

# ---------------------------------------------------------------------------
# 削除系（語は、断片を連結して組み立てる）
# ---------------------------------------------------------------------------
_BEFORE = r"(?<![A-Za-z0-9_.-])"
_AFTER = r"(?![A-Za-z0-9_./-])"
_OPT_BEFORE = r"(?<![A-Za-z0-9_-])"
_OPT_AFTER = r"(?![A-Za-z0-9_-])"
DELETION_RULES = [
    ("ファイル・ディレクトリを消すコマンド",
     re.compile(_BEFORE + "(?:" + join("r", "m") + "(?:dir|i)?|" + join("un", "link") + "|" + join("sh", "red") + ")" + _AFTER)),
    ("削除のオプション", re.compile(_OPT_BEFORE + "--?" + join("d", "elete") + "(?:-[a-z]+)?" + _OPT_AFTER)),
    ("git の削除系",
     re.compile(_OPT_BEFORE + r"git\s+(?:" + join("cl", "ean") + r"|worktree\s+" + join("re", "move") + r")" + _OPT_AFTER)),
    ("docker の削除系", re.compile(_OPT_BEFORE + r"docker[^#\n]*\s" + join("do", "wn") + _OPT_AFTER)),
    ("不要な資源の一括削除", re.compile(_OPT_BEFORE + join("pr", "une") + _OPT_AFTER)),
    ("言語・道具のファイル削除の呼び出し",
     re.compile(r"(?<![A-Za-z0-9_])(?:FileUtils|File|Dir|Pathname|fs|os|shutil)\.(?:" + join("r", "m") + r"\w*|"
                + join("[Rr]e", r"move\w*") + "|" + join("d", r"elete\w*") + "|" + join("un", r"link\w*") + ")")),
]

# ---------------------------------------------------------------------------
# Domain Core の規則（Go のソース。コメントを除いた本文に当てる）
# ---------------------------------------------------------------------------
FORBIDDEN_IMPORT = re.compile(
    r'^\s*(?:import\s+)?(?:[A-Za-z_.]+\s+)?"('
    r"net|os|log|log/slog|math/rand|math/rand/v2|crypto/rand|syscall|plugin"
    r"|net/[^\"]*|os/[^\"]*|log/[^\"]*"
    r"|github\.com/gorilla/[^\"]*|github\.com/gin-gonic/[^\"]*|github\.com/yutopp/go-rtmp[^\"]*|golang\.org/x/net[^\"]*"
    r')"'
)
FORBIDDEN_CALL = re.compile(
    r"(?<![A-Za-z0-9_.])time\.(?:Now|Since|Until|Sleep|After|AfterFunc|Tick|NewTimer|NewTicker)\b"
    r"|(?<![A-Za-z0-9_.])fmt\.(?:Print|Printf|Println|Fprint|Fprintf|Fprintln|Scan|Scanf|Scanln)\b"
)
GLOBAL_VAR = re.compile(r"^var\s*(?:\(|(?!_\s)[A-Za-z])")
GLOBAL_INIT = re.compile(r"^func\s+init\s*\(")


def strip_go_comments(source):
    """Go のソースから、コメントを空白に置き換える（文字列・ルーン・生文字列の中の // は、コメントとして扱わない）。行数は変えない。"""
    out = []
    state = "code"
    i = 0
    n = len(source)
    while i < n:
        c = source[i]
        nxt = source[i + 1] if i + 1 < n else ""
        if state == "code":
            if c == "/" and nxt == "/":
                state = "line"
                out.append("  ")
                i += 2
            elif c == "/" and nxt == "*":
                state = "block"
                out.append("  ")
                i += 2
            else:
                if c == '"':
                    state = "str"
                elif c == "`":
                    state = "raw"
                elif c == "'":
                    state = "rune"
                out.append(c)
                i += 1
        elif state == "line":
            if c == "\n":
                state = "code"
                out.append(c)
            else:
                out.append(" ")
            i += 1
        elif state == "block":
            if c == "*" and nxt == "/":
                state = "code"
                out.append("  ")
                i += 2
            else:
                out.append("\n" if c == "\n" else " ")
                i += 1
        elif state in ("str", "rune"):
            closer = '"' if state == "str" else "'"
            if c == "\\":
                out.append(c + nxt)
                i += 2
                continue
            if c == closer:
                state = "code"
            out.append(c)
            i += 1
        else:  # raw
            if c == "`":
                state = "code"
            out.append(c)
            i += 1
    return "".join(out)


def read_text(path, problems, rel):
    with open(path, "rb") as handle:
        data = handle.read()
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as error:
        problems.append(f"{rel}: UTF-8 として読めません（{error}）")
        return None


def walk_files(base):
    if not os.path.isdir(base):
        return
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for name in sorted(filenames):
            yield os.path.join(dirpath, name)


def scan_text_rules(text, rel, problems):
    """絵文字・削除系（すべてのテキストのファイル）"""
    for number, line in enumerate(text.split("\n"), start=1):
        if EMOJI.search(line):
            problems.append(f"{rel}:{number}: 絵文字があります")
        for label, pattern in DELETION_RULES:
            if pattern.search(line):
                problems.append(f"{rel}:{number}: 削除系の記述があります（{label}）")


def scan_domain_core_rules(text, rel, problems):
    """Domain Core の規則（テスト以外の Go のソース）"""
    code = strip_go_comments(text)
    for number, line in enumerate(code.split("\n"), start=1):
        if FORBIDDEN_IMPORT.search(line):
            problems.append(f"{rel}:{number}: 入出力・実時計・乱数・通信のパッケージを参照しています: {line.strip()}")
        if FORBIDDEN_CALL.search(line):
            problems.append(f"{rel}:{number}: 実時計の読み取り・待機・標準出力への書き込みを呼んでいます: {line.strip()}")
        if GLOBAL_VAR.search(line):
            problems.append(f"{rel}:{number}: パッケージレベルの var（グローバル変数）があります: {line.strip()}")
        if GLOBAL_INIT.search(line):
            problems.append(f"{rel}:{number}: init 関数があります: {line.strip()}")
        if any(ord(ch) > 0x7F for ch in line):
            problems.append(f"{rel}:{number}: コメントの外に非 ASCII の文字があります（文言の直書きの疑い）: {line.strip()}")


def git_lines(root, args):
    result = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True)
    if result.returncode != 0:
        return None
    return [line for line in result.stdout.split("\n") if line]


def scan_change_scope(root, problems, notes):
    """src/relay の変更が、src/relay/core の下（contract を除く）だけであること"""
    changed = set()
    status = git_lines(root, ["status", "--porcelain=v1", "--untracked-files=all", "--", "src/relay"])
    if status is None:
        notes.append("git の状態を読めないため、変更の範囲は検査していません")
        return
    for line in status:
        path = line[3:].split(" -> ")[-1].strip().strip('"')
        changed.add(path)
    base = git_lines(root, ["merge-base", "HEAD", "main"])
    if base:
        diff = git_lines(root, ["diff", "--name-only", base[0], "HEAD", "--", "src/relay"])
        if diff:
            changed.update(diff)
    if not changed:
        notes.append("src/relay に変更がありません（コミット済みで、main と同じ）。変更の範囲の検査は、空振りです")
        return
    violations = []
    for path in sorted(changed):
        if path.startswith(CONTRACT_DIR):
            violations.append(f"{path}: 契約のパッケージは参照のみです（この issue では変更しません）")
        elif not path.startswith("src/relay/core/"):
            violations.append(f"{path}: src/relay/core の外が変更されています（go.mod・go.sum を含みます）")
    problems.extend(violations)
    if not violations:
        notes.append(f"src/relay の変更 {len(changed)} 件は、すべて src/relay/core の下（contract を除く）です")


def scan(root, here, check_scope=True):
    """走査して、(違反の一覧, 注記の一覧, 検査したファイル数, Domain Core の規則を当てたファイル数) を返す"""
    problems = []
    notes = []
    core = os.path.join(root, "src", "relay", "core")
    if not os.path.isdir(core):
        return [f"対象のディレクトリがありません: {core}"], notes, 0, 0

    for name in EXPECTED_FILES:
        if not os.path.isfile(os.path.join(core, name)):
            problems.append(f"src/relay/core/{name}: ファイルがありません")

    checked = 0
    domain_core_files = 0
    for path in walk_files(core):
        if not path.endswith(".go"):
            continue
        rel = os.path.relpath(path, root)
        if os.stat(path).st_mode & 0o111:
            problems.append(f"{rel}: 実行権限が付いています")
        text = read_text(path, problems, rel)
        if text is None:
            continue
        checked += 1
        scan_text_rules(text, rel, problems)
        if not path.endswith("_test.go"):
            domain_core_files += 1
            scan_domain_core_rules(text, rel, problems)

    for path in walk_files(here):
        if os.path.splitext(path)[1] not in {".sh", ".py", ".md"}:
            continue
        rel = os.path.relpath(path, root)
        text = read_text(path, problems, rel)
        if text is None:
            continue
        checked += 1
        scan_text_rules(text, rel, problems)

    if domain_core_files < MIN_DOMAIN_CORE_FILES:
        problems.append(f"Domain Core のソースが {domain_core_files} 件しか見つかりません（空振りの疑い）")
    if check_scope:
        scan_change_scope(root, problems, notes)
    return problems, notes, checked, domain_core_files


# ---------------------------------------------------------------------------
# 走査器の自己検査
# ---------------------------------------------------------------------------
def build_fixture(root, overrides=None, executable=None, omit=None):
    """EXPECTED_FILES がそろった、違反の無い、仮のリポジトリを root の下に作る。

    overrides: {core からの相対パス: Go のソース} で、一部のファイルの中身を置き換える。executable: 実行権限を付けるパス。omit: 作らないパス。
    """
    core = os.path.join(root, "src", "relay", "core")
    for name in EXPECTED_FILES:
        if omit and name == omit:
            continue
        path = os.path.join(core, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        package = os.path.basename(os.path.dirname(path)) or "core"
        source = (overrides or {}).get(name, f"package {package}\n")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(source)
        if executable and name == executable:
            os.chmod(path, 0o755)


def self_test():
    emoji_text = "// " + chr(0x1F600) + "\n"
    delete_call = join("os.", "Re", "move") + '("x")'
    cases = [
        ("違反の無いソースは、問題なし", {}, {}, [], None),
        ("コメントの中の time.Now・日本語・// は、違反ではない",
         {"rebase/rebase.go": "package rebase\n// time.Now は呼ばない。日本語のコメントは可\nconst url = \"https://example.invalid/a//b\"\n"}, {}, [], None),
        ("time.Now の呼び出し", {"frame/frame.go": "package frame\nimport \"time\"\nfunc f() time.Time { return time.Now() }\n"}, {}, ["frame/frame.go:3", "実時計"], None),
        ("time.Since の呼び出し", {"frame/frame.go": "package frame\nfunc f() { _ = time.Since(t) }\n"}, {}, ["実時計"], None),
        ("net/http の参照", {"probe/probe.go": "package probe\nimport (\n\t\"net/http\"\n)\n"}, {}, ["probe/probe.go:3", "参照"], None),
        ("gorilla の参照", {"probe/probe.go": "package probe\nimport _ \"github.com/gorilla/websocket\"\n"}, {}, ["参照"], None),
        ("gin の参照", {"probe/probe.go": "package probe\nimport _ \"github.com/gin-gonic/gin\"\n"}, {}, ["参照"], None),
        ("os の参照", {"probe/probe.go": "package probe\nimport \"os\"\n"}, {}, ["参照"], None),
        ("log の参照", {"probe/probe.go": "package probe\nimport \"log\"\n"}, {}, ["参照"], None),
        ("標準出力への書き込み", {"buffer/buffer.go": "package buffer\nfunc f() { fmt.Println(1) }\n"}, {}, ["標準出力"], None),
        ("グローバル変数", {"buffer/buffer.go": "package buffer\nvar counter = 0\n"}, {}, ["グローバル変数"], None),
        ("var のまとまり", {"buffer/buffer.go": "package buffer\nvar (\n\ta = 1\n)\n"}, {}, ["グローバル変数"], None),
        ("init 関数", {"buffer/buffer.go": "package buffer\nfunc init() {}\n"}, {}, ["init 関数"], None),
        ("_ への代入の宣言は、グローバル変数ではない", {"buffer/buffer.go": "package buffer\nvar _ I = (*T)(nil)\n"}, {}, [], None),
        ("日本語の文字列リテラル", {"liveness/liveness.go": "package liveness\nconst message = \"配信を開始します\"\n"}, {}, ["非 ASCII"], None),
        ("テストの中の日本語・time.Now は、Domain Core の規則の対象外", {}, {"liveness/liveness_test.go": "package liveness\nconst message = \"日本語\"\nvar x = time.Now()\n"}, [], None),
        ("テストの中の絵文字", {}, {"liveness/liveness_test.go": "package liveness\n" + emoji_text}, ["絵文字"], None),
        ("テストの中のファイル削除の呼び出し", {}, {"liveness/liveness_test.go": "package liveness\nfunc f() { " + delete_call + " }\n"}, ["削除系"], None),
        ("Go のソースの実行権限", {}, {}, ["実行権限"], "frame/frame.go"),
        ("期待するファイルが無い", {}, {}, ["rebase/rebase.go: ファイルがありません"], ("omit", "rebase/rebase.go")),
    ]
    base = tempfile.mkdtemp(prefix="issue18_scan_selftest_")  # OS の一時領域。自動では片付けない（1 回の実行で 1 つだけ作る）
    here = os.path.join(base, "here")
    os.makedirs(here)
    failures = 0
    for index, (name, overrides, test_overrides, expected_fragments, extra) in enumerate(cases):
        all_overrides = dict(overrides)
        all_overrides.update(test_overrides)
        executable = extra if isinstance(extra, str) else None
        omit = extra[1] if isinstance(extra, tuple) else None
        root = os.path.join(base, f"case{index}")
        build_fixture(root, all_overrides, executable, omit)
        problems, _notes, _checked, _domain = scan(root, here, check_scope=False)
        text = "\n".join(problems)
        # Domain Core の規則の対象でないファイルを除いて、期待する断片がすべて含まれ、期待しない違反が無いことを確かめる
        ok = all(fragment in text for fragment in expected_fragments) and (bool(problems) == bool(expected_fragments))
        print(("ok   " if ok else "FAIL ") + name)
        if not ok:
            failures += 1
            print("     期待する断片: " + repr(expected_fragments))
            print("     実際の問題: " + repr(problems))
    if failures:
        print(f"自己検査に失敗しました（{failures} 件）")
        return 1
    print(f"自己検査: {len(cases)} 件すべて成功")
    return 0


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        return self_test()
    root = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.getcwd()
    here = os.path.dirname(os.path.abspath(__file__))
    problems, notes, checked, domain_core_files = scan(root, here)
    print(f"{checked} ファイルを検査しました（うち Domain Core の規則を当てたもの {domain_core_files} ファイル）")
    for note in notes:
        print(note)
    if problems:
        print("問題:")
        for item in problems:
            print("  - " + item)
        return 1
    print("問題ありません")
    return 0


if __name__ == "__main__":
    sys.exit(main())
