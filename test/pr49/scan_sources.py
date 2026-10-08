#!/usr/bin/env python3
"""issue #20（中継の取り込みセッション・セッション台帳・内部通信クライアント）の成果物を走査する（読み取りのみ）。

使い方:
  python3 -I scan_sources.py <リポジトリのルート>   走査する（違反があれば終了コード 1）
  python3 -I scan_sources.py --self-test           走査器そのものの検査（違反を見逃さず、違反でないものを誤検知しない）

検査:
  1. 対象のファイルが、そろっている（空振りの防止）
  2. 絵文字が無い（アイコンは FontAwesome。CLAUDE.md）。対象: src/relay/internal/session・src/relay/internal/backend・このディレクトリ
  3. 削除系のコマンド・関数呼び出しが無い（CLAUDE.md）。対象: 同上（Go のソースは、コメントの行を除く）
  4. 変更の範囲：git の変更のうち、src/relay の下は、internal/session・internal/backend・go.mod・go.sum だけ
     （internal/flv・internal/rtmps・core は参照のみ。変更が無いことを確かめる）

Go の構文木による規則（実時計・入出力・グローバル変数・日本語の直書き・ログの秘密値）の検査は、
src/relay/internal/session/rules_test.go が行う。ここは、別の実装（正規表現）による検査。

削除系の語は、このファイルにそのまま書かない（断片を連結して組み立てる。CI の hygiene が、このファイルも検査する）。
"""
import os
import re
import subprocess
import sys

SESSION_DIR = "src/relay/internal/session"
BACKEND_DIR = "src/relay/internal/backend"
EXPECTED_FILES = {
    SESSION_DIR: [
        "doc.go", "interfaces.go", "options.go", "errors.go", "clock.go", "wire.go", "protocol.go", "session.go", "session_input.go",
        "session_output.go", "session_publish.go", "session_heartbeat.go", "session_close.go", "connection.go", "registry.go",
        "factory.go", "rules_test.go", "fakes_test.go", "harness_test.go", "connection_test.go", "registry_test.go",
        "session_flow_test.go", "session_heartbeat_test.go", "session_interrupt_test.go", "session_close_test.go",
        "integration_test.go", "logging_test.go", "protocol_test.go", "wire_test.go", "options_test.go", "factory_test.go",
    ],
    BACKEND_DIR: [
        "doc.go", "redact.go", "errors.go", "types.go", "client.go", "events.go", "waiter.go",
        "client_test.go", "events_test.go", "redact_test.go", "helpers_test.go",
    ],
}
# 変更してよい、src/relay の下のパス（前方一致）
ALLOWED_RELAY_PATHS = ("src/relay/internal/session/", "src/relay/internal/backend/", "src/relay/go.mod", "src/relay/go.sum")
SKIP_DIRS = {"node_modules", ".cache", ".next", "vendor", "testdata", "__pycache__"}


def join(*parts):
    return "".join(parts)


# 絵文字（このファイル自体に絵文字を書かないよう、コードポイントで持つ）
EMOJI_RANGES = [
    (0x1F300, 0x1FAFF), (0x1F000, 0x1F2FF), (0x2600, 0x26FF), (0x2700, 0x27BF),
    (0x2B50, 0x2B50), (0x2B55, 0x2B55), (0x231A, 0x231B), (0x23E9, 0x23F3), (0x23F8, 0x23FA),
    (0xFE0F, 0xFE0F), (0x20E3, 0x20E3), (0xE0020, 0xE007F),
]
EMOJI = re.compile("[" + "".join(chr(low) + "-" + chr(high) for low, high in EMOJI_RANGES) + "]")

# 削除系（語は、断片を連結して組み立てる）
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


def scan_text(path, text):
    """(行番号, 分類, 内容) の一覧を返す。コメントだけの行（// と #）は、削除系の検査から除く。"""
    findings = []
    for number, line in enumerate(text.split("\n"), start=1):
        for match in EMOJI.finditer(line):
            findings.append((number, "絵文字", f"U+{ord(match.group()):04X}"))
        stripped = line.lstrip()
        if stripped.startswith("//") or stripped.startswith("#"):
            continue
        for label, pattern in DELETION_RULES:
            if pattern.search(line):
                findings.append((number, label, line.strip()[:120]))
    return findings


def relay_changes(root):
    """git の変更（未追跡を含む）のうち、src/relay の下のパス。"""
    output = subprocess.run(["git", "status", "--porcelain", "-uall", "--", "src/relay"], cwd=root, check=True,
                            capture_output=True, text=True).stdout
    paths = []
    for line in output.split("\n"):
        if line.strip():
            paths.append(line[3:].strip().strip('"'))
    return paths


def target_files(root):
    files = []
    for relative in (SESSION_DIR, BACKEND_DIR, "test/" + os.path.basename(os.path.dirname(os.path.abspath(__file__)))):
        base = os.path.join(root, relative)
        for current, dirs, names in os.walk(base):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for name in names:
                if name.endswith((".go", ".py", ".sh", ".md")):
                    files.append(os.path.join(current, name))
    return sorted(files)


def scan(root):
    problems = []
    for directory, names in EXPECTED_FILES.items():
        for name in names:
            if not os.path.isfile(os.path.join(root, directory, name)):
                problems.append(f"ファイルがありません: {directory}/{name}")
    files = target_files(root)
    for path in files:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        for number, label, detail in scan_text(path, text):
            problems.append(f"{os.path.relpath(path, root)}:{number}: {label}: {detail}")
    outside = [p for p in relay_changes(root) if not p.startswith(ALLOWED_RELAY_PATHS)]
    for path in outside:
        problems.append(f"変更の範囲の外: {path}")
    print(f"走査したファイル: {len(files)} 件。src/relay の変更のうち、範囲の外: {len(outside)} 件")
    return problems


def self_test():
    """走査器が、違反を見逃さず、違反でないものを誤検知しないこと。"""
    cases = [
        ("絵文字", chr(0x1F600), 1),
        ("絵文字（記号）", chr(0x2705), 1),
        ("矢印は絵文字ではない", chr(0x2192), 0),
        ("乗算記号は絵文字ではない", chr(0x00D7), 0),
        ("ファイルを消すコマンド", join("r", "m") + " -f x", 1),
        ("ファイルを消すコマンド（絶対パス）", "/bin/" + join("r", "m") + " x", 1),
        ("別の語の一部は可", "format the form", 0),
        ("Go のファイル削除", "os." + join("Re", "move") + "(path)", 1),
        ("台帳のメソッドの Remove は可", "r.remove(s, false)\nr.Remove(s)", 0),
        ("コメントの行は除く", "// " + join("r", "m") + " x", 0),
        ("docker の削除系", "docker compose " + join("do", "wn"), 1),
        ("削除のオプション", "x --" + join("d", "elete"), 1),
    ]
    failures = 0
    for name, text, want in cases:
        got = len(scan_text("x", text))
        if got != want:
            failures += 1
            print(f"自己検査の失敗: {name}: 検出 {got} 件、期待 {want} 件")
    print(f"自己検査: {len(cases)} 件、失敗 {failures} 件")
    return failures == 0


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        sys.exit(0 if self_test() else 1)
    if len(sys.argv) != 2:
        print("使い方: scan_sources.py <リポジトリのルート> | --self-test")
        sys.exit(2)
    found = scan(sys.argv[1])
    if found:
        print("問題:")
        for item in found:
            print("  - " + item)
        sys.exit(1)
    print("問題ありません")
