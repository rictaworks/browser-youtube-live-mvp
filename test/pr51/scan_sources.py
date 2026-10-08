#!/usr/bin/env python3
"""issue #21（中継: WebSocket の受け口・結線・設定・正常停止・結合テスト）の成果物を走査する（読み取りのみ）。

使い方:
  python3 -I scan_sources.py <リポジトリのルート>   走査する（違反があれば終了コード 1）
  python3 -I scan_sources.py --self-test           走査器そのものの検査（違反を見逃さず、違反でないものを誤検知しない）

検査:
  1. 対象のファイルが、そろっている（空振りの防止）
  2. 絵文字が無い（アイコンは FontAwesome。CLAUDE.md）。対象: 下の対象のディレクトリとファイル
  3. 削除系のコマンド・関数呼び出しが無い（CLAUDE.md）。対象: 同上（Go のソースは、コメントの行を除く）
  4. go.mod が、gorilla/websocket v1.5.3（固定の版）を要求している。go.mod の変更（未コミットの差分）は、gorilla/websocket の追加と、
     logrus の indirect -> 直接への移動（コードが logrus を直接参照するため）だけ。go.sum の変更は、gorilla/websocket の行だけ
  5. 変更の範囲：git の未コミットの変更のうち、src/relay の下は、main.go・main_test.go・main_signal_unix_test.go・internal/wsapi・
     internal/config・internal/server・go.mod・go.sum だけ（core・internal/session・internal/backend・internal/rtmps・internal/flv・
     internal/appenv は参照のみ。変更が無いことを確かめる）。コミット済み（差分が無い）なら、この検査は行わない（PR の差分は、レビューで見る）

Go の構文木による規則（実時計・入出力・グローバル変数・日本語の直書き・ログの秘密値・CheckOrigin の説明など）の検査は、
src/relay/internal/wsapi/rules_test.go が行う。ここは、別の実装（正規表現）による検査。

削除系の語は、このファイルにそのまま書かない（断片を連結して組み立てる。CI の hygiene が、このファイルも検査する）。
"""
import os
import re
import subprocess
import sys

TARGET_DIRS = [
    "src/relay/internal/wsapi",
    "src/relay/internal/server",
    "src/relay/internal/config",
]
TARGET_FILES = ["src/relay/main.go", "src/relay/main_test.go", "src/relay/main_signal_unix_test.go"]
EXPECTED_FILES = {
    "src/relay/internal/wsapi": [
        "doc.go", "errors.go", "options.go", "socket.go", "read.go", "link.go", "handler.go", "rules_test.go", "fakes_test.go", "export_test.go",
        "options_test.go", "read_test.go", "link_test.go", "handler_test.go", "integration_apps_test.go", "integration_env_test.go",
        "integration_test.go", "integration_abnormal_test.go", "integration_shutdown_test.go", "integration_load_test.go",
    ],
    "src/relay/internal/server": [
        "server.go", "logging.go", "app.go", "errors.go", "thirdparty.go", "server_test.go", "app_test.go", "thirdparty_test.go",
    ],
    "src/relay/internal/config": ["config.go", "config_test.go"],
}
# 変更してよい、src/relay の下のパス（前方一致）
ALLOWED_RELAY_PATHS = (
    "src/relay/main.go", "src/relay/main_test.go", "src/relay/main_signal_unix_test.go", "src/relay/internal/wsapi/",
    "src/relay/internal/config/",
    "src/relay/internal/server/", "src/relay/go.mod", "src/relay/go.sum",
)
GORILLA_REQUIRE = "github.com/gorilla/websocket v1.5.3"
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


def git_lines(root, *args):
    return subprocess.run(["git", *args], cwd=root, check=True, capture_output=True, text=True).stdout.split("\n")


def relay_changes(root):
    """git の未コミットの変更（未追跡を含む）のうち、src/relay の下のパス。"""
    paths = []
    for line in git_lines(root, "status", "--porcelain", "-uall", "--", "src/relay"):
        if line.strip():
            paths.append(line[3:].strip().strip('"'))
    return paths


def module_file_problems(root):
    """go.mod・go.sum の、検査 4。"""
    problems = []
    go_mod = os.path.join(root, "src/relay/go.mod")
    with open(go_mod, encoding="utf-8") as handle:
        text = handle.read()
    if not re.search(r"^\s*" + re.escape(GORILLA_REQUIRE) + r"\s*$", text, re.MULTILINE):
        problems.append(f"go.mod が {GORILLA_REQUIRE} を要求していません（固定の版）")
    if re.search(re.escape(GORILLA_REQUIRE) + r"\s*//\s*indirect", text):
        problems.append("go.mod で gorilla/websocket が indirect のままです（コードが直接参照しています）")
    added = [line[1:].strip() for line in git_lines(root, "diff", "-U0", "--", "src/relay/go.mod")
             if line.startswith("+") and not line.startswith("+++")]
    allowed = {GORILLA_REQUIRE, "github.com/sirupsen/logrus v1.7.0"}
    for line in added:
        if line not in allowed:
            problems.append(f"go.mod に、許可していない行が足されています: {line}")
    for line in git_lines(root, "diff", "-U0", "--", "src/relay/go.sum"):
        if line.startswith("+") and not line.startswith("+++") and "github.com/gorilla/websocket" not in line:
            problems.append(f"go.sum に、gorilla/websocket 以外の行が足されています: {line[:80]}")
    return problems


def target_files(root):
    files = []
    own = "test/" + os.path.basename(os.path.dirname(os.path.abspath(__file__)))
    for relative in TARGET_DIRS + [own]:
        base = os.path.join(root, relative)
        for current, dirs, names in os.walk(base):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for name in names:
                if name.endswith((".go", ".py", ".sh", ".md")):
                    files.append(os.path.join(current, name))
    for relative in TARGET_FILES:
        files.append(os.path.join(root, relative))
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
    problems.extend(module_file_problems(root))
    changes = relay_changes(root)
    outside = [p for p in changes if not p.startswith(ALLOWED_RELAY_PATHS)]
    for path in outside:
        problems.append(f"変更の範囲の外: {path}")
    note = "未コミットの変更なし（範囲の検査は、PR の差分で行う）" if not changes else f"未コミットの変更 {len(changes)} 件のうち、範囲の外: {len(outside)} 件"
    print(f"走査したファイル: {len(files)} 件。{note}")
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
        ("接続の Remove のような名前は可", "handler.untrack(l)\nr.Remove(s)", 0),
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
