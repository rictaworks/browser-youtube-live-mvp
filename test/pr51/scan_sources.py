#!/usr/bin/env python3
"""issue #21（中継: WebSocket の受け口・結線・設定・正常停止・結合テスト）の成果物を走査する（読み取りのみ）。

使い方:
  python3 -I scan_sources.py <リポジトリのルート> [<比較の基準>]   走査する（違反があれば終了コード 1、前提の不足は 2）
  python3 -I scan_sources.py --self-test                           走査器そのものの検査（違反を見逃さず、違反でないものを誤検知しない）

検査:
  1. 対象のファイルが、そろっている（空振りの防止）
  2. 絵文字が無い（アイコンは FontAwesome。CLAUDE.md）。対象: 下の対象のディレクトリとファイル
  3. 削除系のコマンド・関数呼び出しが無い（CLAUDE.md）。対象: 同上（Go のソースは、コメントの行を除く）
  4. go.mod・go.sum：HEAD（コミット済み）の go.mod が、gorilla/websocket v1.5.3（固定の版）を直接の要求として持つ。
     go.mod の変更は、比較の基準との共通の祖先から HEAD までの差で判定する：足された行は、gorilla/websocket の要求と、logrus の直接の要求
     （indirect -> 直接への移動。コードが logrus を直接参照するため）だけ。消された行は、logrus の indirect の行だけ。
     go.sum は、gorilla/websocket の行を足すだけ（ほかの行の追加・どの行の削除も不可）
  5. 変更の範囲：PR のブランチ（HEAD）が、比較の基準（既定 origin/main）との共通の祖先から変えたパスのうち、src/relay の下は、
     main.go・main_test.go・main_signal_unix_test.go・internal/wsapi・internal/config・internal/server・go.mod・go.sum だけ
     （core・internal/session・internal/backend・internal/rtmps・internal/flv・internal/appenv は参照のみ）。

4 と 5 は、コミット済みの内容だけを見る。作業ツリーの未コミットの変更・未追跡のファイルは、別の issue の作業のことがあるので、見ない。
基準を解決できなければ、エラーにする（終了コード 2。別の基準へ切り替えない。origin/main が古いときは、git fetch origin main で取得する）。
比較の基準は、第 2 引数か、環境変数 PR_BASE_REF で変えられる（run_all.sh は、PR_BASE_REF を引き継ぐ）。
1〜3 は、作業ツリーのファイルを走査する（この PR の対象のディレクトリは、この PR だけが変える）。

Go の構文木による規則（実時計・入出力・グローバル変数・日本語の直書き・ログの秘密値・CheckOrigin の説明など）の検査は、
src/relay/internal/wsapi/rules_test.go が行う。ここは、別の実装（正規表現）による検査。

削除系の語は、このファイルにそのまま書かない（断片を連結して組み立てる。CI の hygiene が、このファイルも検査する）。
"""
import os
import re
import subprocess
import sys
import tempfile

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
# 変更してよい、src/relay の下のパス（ディレクトリは前方一致、ファイルは完全一致）
ALLOWED_RELAY_DIRS = ("src/relay/internal/wsapi/", "src/relay/internal/config/", "src/relay/internal/server/")
ALLOWED_RELAY_FILES = (
    "src/relay/main.go", "src/relay/main_test.go", "src/relay/main_signal_unix_test.go", "src/relay/go.mod", "src/relay/go.sum",
)
GO_MOD = "src/relay/go.mod"
GO_SUM = "src/relay/go.sum"
GORILLA_REQUIRE = "github.com/gorilla/websocket v1.5.3"
LOGRUS_DIRECT = "github.com/sirupsen/logrus v1.7.0"
LOGRUS_INDIRECT = "github.com/sirupsen/logrus v1.7.0 // indirect"
GO_MOD_ADDED_ALLOWED = {GORILLA_REQUIRE, LOGRUS_DIRECT}
GO_MOD_REMOVED_ALLOWED = {LOGRUS_INDIRECT}
# 比較の基準（PR の土台）。環境変数 PR_BASE_REF か、第 2 引数で変えられる
DEFAULT_BASE_REF = "origin/main"
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


class BaseRefError(Exception):
    """比較の基準（PR の土台）のコミットを解決できない、または、基準との差を取れない。"""


def verify_base(root, base):
    """基準 base がコミットとして解決できることを確かめる。できなければ BaseRefError（別の基準へ切り替えない）。"""
    check = subprocess.run(["git", "rev-parse", "--verify", "--quiet", base + "^{commit}"], cwd=root, capture_output=True, text=True)
    if check.returncode != 0:
        raise BaseRefError(f"比較の基準 {base} を解決できません。git fetch origin main で取得するか、基準を引数（PR_BASE_REF）で指定してください")


def committed_diff(root, base, options, path):
    """基準 base との共通の祖先から HEAD までの、path の差（コミット済みの内容だけ。作業ツリーと未追跡のファイルは見ない）。"""
    verify_base(root, base)
    diff = subprocess.run(["git", "diff", "--no-renames", *options, base + "...HEAD", "--", path], cwd=root, capture_output=True, text=True)
    if diff.returncode != 0:
        raise BaseRefError(f"{base} と HEAD の差を取れません: {diff.stderr.strip()[:200]}")
    return diff.stdout


def relay_changes(root, base=DEFAULT_BASE_REF):
    """PR のブランチ（HEAD）が、基準 base との共通の祖先から変えたパスのうち、src/relay の下のもの（コミット済みの内容だけ）。

    作業ツリーの未コミットの変更・未追跡のファイルは見ない（他の issue の作業のことがあり、PR の内容ではない）。
    名前の変更は、元の名前と新しい名前の両方を数える。基準を解決できなければ BaseRefError（別の基準へ切り替えない）。
    """
    output = committed_diff(root, base, ["--name-only", "-z"], "src/relay")
    return sorted(path for path in output.split("\0") if path)


def outside_scope(paths):
    """変更してよい範囲の外のパス。"""
    return [p for p in paths if not (p.startswith(ALLOWED_RELAY_DIRS) or p in ALLOWED_RELAY_FILES)]


def changed_lines(root, base, relative):
    """基準との共通の祖先から HEAD までに、ファイル relative で足された行・消された行（前後の空白を除く）。コミット済みの内容だけ。"""
    output = committed_diff(root, base, ["-U0"], relative)
    added, removed = [], []
    for line in output.split("\n"):
        if line.startswith("+++ ") or line.startswith("--- "):
            continue  # ファイルの見出し
        if line.startswith("+"):
            added.append(line[1:].strip())
        elif line.startswith("-"):
            removed.append(line[1:].strip())
    return added, removed


def committed_text(root, relative):
    """HEAD（コミット済み）のファイルの内容。HEAD に無ければ None。"""
    shown = subprocess.run(["git", "show", "HEAD:" + relative], cwd=root, capture_output=True, text=True)
    return shown.stdout if shown.returncode == 0 else None


def go_mod_problems(text, added, removed):
    """go.mod の、検査 4。text は HEAD の内容、added・removed は基準との差。"""
    problems = []
    if text is None:
        return [f"{GO_MOD} が HEAD にありません"]
    if not re.search(r"^\s*" + re.escape(GORILLA_REQUIRE) + r"\s*$", text, re.MULTILINE):
        problems.append(f"go.mod が {GORILLA_REQUIRE} を要求していません（固定の版。直接の要求）")
    if re.search(re.escape(GORILLA_REQUIRE) + r"\s*//\s*indirect", text):
        problems.append("go.mod で gorilla/websocket が indirect のままです（コードが直接参照しています）")
    for line in added:
        if line not in GO_MOD_ADDED_ALLOWED:
            problems.append(f"go.mod に、許可していない行が足されています: {line}")
    for line in removed:
        if line not in GO_MOD_REMOVED_ALLOWED:
            problems.append(f"go.mod から、許可していない行が消されています: {line}")
    return problems


def go_sum_problems(added, removed):
    """go.sum の、検査 4。gorilla/websocket の行を足すだけ。"""
    problems = []
    for line in added:
        if "github.com/gorilla/websocket" not in line:
            problems.append(f"go.sum に、gorilla/websocket 以外の行が足されています: {line[:80]}")
    for line in removed:
        problems.append(f"go.sum から、行が消されています: {line[:80]}")
    return problems


def module_file_problems(root, base):
    """go.mod・go.sum の、検査 4（コミット済みの内容と、基準との差だけ）。"""
    mod_added, mod_removed = changed_lines(root, base, GO_MOD)
    sum_added, sum_removed = changed_lines(root, base, GO_SUM)
    return go_mod_problems(committed_text(root, GO_MOD), mod_added, mod_removed) + go_sum_problems(sum_added, sum_removed)


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


def scan(root, base=DEFAULT_BASE_REF):
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
    problems.extend(module_file_problems(root, base))
    changed = relay_changes(root, base)
    outside = outside_scope(changed)
    for path in outside:
        problems.append(f"変更の範囲の外: {path}（{base} が古いときは、git fetch origin main で取得してください）")
    print(f"走査したファイル: {len(files)} 件。{base} との差（コミット済み）のうち src/relay の変更: {len(changed)} 件、範囲の外: {len(outside)} 件")
    return problems


def text_cases():
    """文面の走査（絵文字・削除系）の自己検査。"""
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
    failures = []
    for name, text, want in cases:
        got = len(scan_text("x", text))
        if got != want:
            failures.append(f"{name}: 検出 {got} 件、期待 {want} 件")
    return len(cases), failures


def scope_cases():
    """変更の範囲の判定（outside_scope）の自己検査。"""
    cases = [
        ("WebSocket の受け口の下", "src/relay/internal/wsapi/handler.go", False),
        ("WebSocket の受け口の試験", "src/relay/internal/wsapi/integration_test.go", False),
        ("組み立ての下", "src/relay/internal/server/app.go", False),
        ("設定の下", "src/relay/internal/config/config.go", False),
        ("main.go", "src/relay/main.go", False),
        ("main_test.go", "src/relay/main_test.go", False),
        ("main_signal_unix_test.go", "src/relay/main_signal_unix_test.go", False),
        ("go.mod", "src/relay/go.mod", False),
        ("go.sum", "src/relay/go.sum", False),
        ("go.mod に似た別のファイル", "src/relay/go.modx", True),
        ("main.go に似た別のファイル", "src/relay/main.go.orig", True),
        ("参照のみの session", "src/relay/internal/session/session.go", True),
        ("参照のみの backend", "src/relay/internal/backend/client.go", True),
        ("参照のみの rtmps", "src/relay/internal/rtmps/publisher.go", True),
        ("参照のみの flv", "src/relay/internal/flv/muxer.go", True),
        ("参照のみの appenv", "src/relay/internal/appenv/appenv.go", True),
        ("参照のみの core", "src/relay/core/frame/frame.go", True),
        ("名前の似たディレクトリ", "src/relay/internal/wsapix/a.go", True),
        ("Dockerfile", "src/relay/Dockerfile", True),
    ]
    failures = []
    for name, path, want in cases:
        got = bool(outside_scope([path]))
        if got != want:
            failures.append(f"{name}: 範囲の外 = {got}、期待 {want}")
    return len(cases), failures


def module_cases():
    """go.mod・go.sum の判定（go_mod_problems・go_sum_problems）の自己検査。"""
    good_text = "module x\n\nrequire (\n\t" + GORILLA_REQUIRE + "\n\t" + LOGRUS_DIRECT + "\n)\n"
    cases = [
        ("許可された go.mod の変更", good_text, [GORILLA_REQUIRE, LOGRUS_DIRECT], [LOGRUS_INDIRECT], 0),
        ("gorilla を要求していない", "module x\n", [], [], 1),
        ("gorilla が indirect のまま", "module x\n\t" + GORILLA_REQUIRE + " // indirect\n", [], [], 2),
        ("許可していない行を足した", good_text, [GORILLA_REQUIRE, "github.com/evil/pkg v9.9.9"], [], 1),
        ("許可していない行を消した", good_text, [GORILLA_REQUIRE], ["github.com/other/lib v1.0.0"], 1),
        ("HEAD に go.mod が無い", None, [], [], 1),
    ]
    failures = []
    for name, text, added, removed, want in cases:
        got = len(go_mod_problems(text, added, removed))
        if got != want:
            failures.append(f"go.mod の判定: {name}: 問題 {got} 件、期待 {want} 件")
    sum_cases = [
        ("gorilla の行だけを足した", ["github.com/gorilla/websocket v1.5.3 h1:x=", "github.com/gorilla/websocket v1.5.3/go.mod h1:y="], [], 0),
        ("別の行を足した", ["github.com/evil/pkg v1.0.0 h1:x="], [], 1),
        ("行を消した", [], ["github.com/gorilla/websocket v1.5.0 h1:x="], 1),
        ("変更なし", [], [], 0),
    ]
    for name, added, removed, want in sum_cases:
        got = len(go_sum_problems(added, removed))
        if got != want:
            failures.append(f"go.sum の判定: {name}: 問題 {got} 件、期待 {want} 件")
    return len(cases) + len(sum_cases), failures


def fixture_cases():
    """git の差の取り方の自己検査（TH4：実リポジトリではなく、一時ディレクトリの最小の確認用リポジトリに対して行う）。

    確かめること：(1) PR のブランチのコミット済みの変更だけが数えられる（2) 作業ツリーの未コミットの変更・未追跡のファイルは
    数えられない（他の issue の作業があっても失敗しない。go.mod・go.sum も同じ）(3) コミットしたあとの状態で、結果が同じ
    (4) 基準を解決できなければ BaseRefError（範囲の検査も、go.mod・go.sum の検査も）(5) 基準が進んでいても、PR の変更だけが数えられる
    (6) 許可していない go.mod・go.sum の変更は、コミット済みなら見つかる。
    一時ディレクトリは、作るだけで、片づけない（削除系の操作をしない方針）。
    """
    failures = []
    checks = 0
    work = os.path.realpath(tempfile.mkdtemp(prefix="issue21-scan-"))
    # 実リポジトリを指す環境変数を引き継がない（確認用リポジトリへの操作が、実リポジトリに及ばないように）
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update({"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull, "GIT_CEILING_DIRECTORIES": os.path.dirname(work)})

    def git(*args):
        return subprocess.run(["git", "-c", "core.hooksPath=" + os.devnull, "-c", "commit.gpgsign=false",
                               "-c", "user.name=rictaworks", "-c", "user.email=info@rictaworks.jp", *args],
                              cwd=work, env=env, capture_output=True, text=True, check=True).stdout

    def write(relative, text):
        path = os.path.join(work, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)

    base_mod = "module x\n\nrequire (\n\t" + LOGRUS_INDIRECT + "\n\tgithub.com/other/lib v1.0.0\n)\n"
    good_mod = "module x\n\nrequire (\n\t" + GORILLA_REQUIRE + "\n\t" + LOGRUS_DIRECT + "\n\tgithub.com/other/lib v1.0.0\n)\n"
    base_sum = "github.com/other/lib v1.0.0 h1:a=\n"
    good_sum = base_sum + "github.com/gorilla/websocket v1.5.3 h1:b=\ngithub.com/gorilla/websocket v1.5.3/go.mod h1:c=\n"

    def expect(condition, message):
        nonlocal checks
        checks += 1
        if not condition:
            failures.append(message)

    try:
        git("init", "-q", "-b", "main")
        if os.path.realpath(git("rev-parse", "--show-toplevel").strip()) != work:
            return 1, ["確認用リポジトリの場所が想定と違います。安全のため、中止しました"]
        write("src/relay/go.mod", base_mod)
        write("src/relay/go.sum", base_sum)
        write("src/relay/internal/session/base.go", "package session\n")
        git("add", "-A")
        git("commit", "-q", "-m", "base")
        git("update-ref", "refs/remotes/origin/main", "HEAD")  # 基準（origin/main）を、確認用に用意する

        # 許可された変更だけの PR
        git("checkout", "-q", "-b", "pr")
        write("src/relay/go.mod", good_mod)
        write("src/relay/go.sum", good_sum)
        write("src/relay/internal/wsapi/added.go", "package wsapi\n")
        write("src/relay/internal/rtmps/outside.go", "package rtmps\n")
        write("src/backend/other.rb", "x = 1\n")  # src/relay の外は、数えない
        git("add", "-A")
        git("commit", "-q", "-m", "pr")

        # 基準（origin/main）が進んでも、PR の変更だけが数えられる（共通の祖先からの差）
        git("checkout", "-q", "main")
        write("src/relay/internal/backend/later.go", "package backend\n")
        git("add", "-A")
        git("commit", "-q", "-m", "later change on main")
        git("update-ref", "refs/remotes/origin/main", "HEAD")

        # 許可していない変更をコミットした PR は、見つかる
        git("checkout", "-q", "-b", "bad")
        write("src/relay/go.mod", good_mod + "\tgithub.com/evil/pkg v9.9.9\n")
        write("src/relay/go.sum", good_sum + "github.com/evil/pkg v9.9.9 h1:z=\n")
        write("src/relay/internal/session/session.go", "package session\n")
        git("add", "-A")
        git("commit", "-q", "-m", "bad pr")
        bad_problems = module_file_problems(work, DEFAULT_BASE_REF)
        expect(any("evil/pkg" in p and "go.mod" in p for p in bad_problems), f"許可していない go.mod の行が見つからない: {bad_problems}")
        expect(any("evil/pkg" in p and "go.sum" in p for p in bad_problems), f"許可していない go.sum の行が見つからない: {bad_problems}")
        expect(relay_changes(work, DEFAULT_BASE_REF) == sorted(["src/relay/go.mod", "src/relay/go.sum", "src/relay/internal/session/session.go"]),
               f"bad の変更の一覧: {relay_changes(work, DEFAULT_BASE_REF)}")
        expect(outside_scope(relay_changes(work, DEFAULT_BASE_REF)) == ["src/relay/internal/session/session.go"], "範囲の外の変更が見つからない")

        # 許可された PR に戻り（コミットしたあとの状態）、他の issue の作業（未コミットの変更と、未追跡のファイル。go.mod・go.sum の
        # 未コミットの変更を含む）を置く。数えてはならない
        git("checkout", "-q", "pr")
        write("src/relay/internal/session/base.go", "package session\n// 未コミットの変更\n")
        write("src/relay/internal/server/untracked.go", "package server\n")
        write("src/relay/go.mod", "module dirty\n\trequire github.com/evil/pkg v9.9.9\n")  # gorilla の要求も無い。HEAD の内容を見ていれば、影響しない
        write("src/relay/go.sum", good_sum + "github.com/evil/pkg v9.9.9 h1:z=\n")

        changed = relay_changes(work, DEFAULT_BASE_REF)
        want = sorted(["src/relay/go.mod", "src/relay/go.sum", "src/relay/internal/rtmps/outside.go", "src/relay/internal/wsapi/added.go"])
        expect(changed == want, f"コミット済みの変更だけが数えられる: {changed}、期待 {want}（未コミットの変更・基準の進みを数えていないか）")
        expect(outside_scope(changed) == ["src/relay/internal/rtmps/outside.go"], f"範囲の外の判定: {outside_scope(changed)}")
        problems = module_file_problems(work, DEFAULT_BASE_REF)
        expect(problems == [], f"許可された go.mod・go.sum の変更が、問題にされた（未コミットの変更を見ていないか）: {problems}")

        # 基準を解決できなければ、エラー（範囲の検査も、go.mod・go.sum の検査も）
        for label, run in (("範囲", relay_changes), ("go.mod・go.sum", module_file_problems)):
            try:
                run(work, "origin/no-such-branch")
                failures.append(f"基準を解決できないのに、{label}の検査がエラーにならなかった")
            except BaseRefError:
                pass
            checks += 1

        # 基準が HEAD と同じコミットなら、差が空（コミット済みの内容の差だけを見るので、作業ツリーの未コミットの変更は影響しない）
        expect(relay_changes(work, "HEAD") == [], "基準が HEAD と同じなのに、差が空にならなかった")
    except (subprocess.CalledProcessError, OSError) as error:
        stderr = getattr(error, "stderr", "") or ""
        failures.append(f"確認用リポジトリの操作に失敗しました: {error.__class__.__name__}: {stderr.strip()[:200]}")
    return checks, failures


def self_test():
    """走査器が、違反を見逃さず、違反でないものを誤検知しないこと。"""
    total = 0
    failures = []
    for run in (text_cases, scope_cases, module_cases, fixture_cases):
        count, found = run()
        total += count
        failures.extend(found)
    for message in failures:
        print(f"自己検査の失敗: {message}")
    print(f"自己検査: {total} 件、失敗 {len(failures)} 件")
    return not failures


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        sys.exit(0 if self_test() else 1)
    if len(sys.argv) not in (2, 3):
        print("使い方: scan_sources.py <リポジトリのルート> [<比較の基準>] | --self-test")
        sys.exit(2)
    base_ref = sys.argv[2] if len(sys.argv) == 3 else os.environ.get("PR_BASE_REF") or DEFAULT_BASE_REF
    try:
        found = scan(sys.argv[1], base_ref)
    except BaseRefError as error:
        print(f"前提の不足: {error}")
        sys.exit(2)
    if found:
        print("問題:")
        for item in found:
            print("  - " + item)
        sys.exit(1)
    print("問題ありません")
