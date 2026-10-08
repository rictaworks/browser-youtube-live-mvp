#!/usr/bin/env python3
"""issue #20（中継の取り込みセッション・セッション台帳・内部通信クライアント）の成果物を走査する（読み取りのみ）。

使い方:
  python3 -I scan_sources.py <リポジトリのルート> [<比較の基準>]   走査する（違反があれば終了コード 1、前提の不足は 2）
  python3 -I scan_sources.py --self-test                           走査器そのものの検査（違反を見逃さず、違反でないものを誤検知しない）

検査:
  1. 対象のファイルが、そろっている（空振りの防止）
  2. 絵文字が無い（アイコンは FontAwesome。CLAUDE.md）。対象: src/relay/internal/session・src/relay/internal/backend・このディレクトリ
  3. 削除系のコマンド・関数呼び出しが無い（CLAUDE.md）。対象: 同上（Go のソースは、コメントの行を除く）
  4. 変更の範囲：PR のブランチ（HEAD）が、比較の基準（既定 origin/main）との共通の祖先から変えたパスのうち、src/relay の下は、
     internal/session・internal/backend・go.mod・go.sum だけ（internal/flv・internal/rtmps・core は参照のみ）。
     コミット済みの内容だけを見る。作業ツリーの未コミットの変更・未追跡のファイルは、別の issue の作業のことがあるので、見ない。
     基準を解決できなければ、エラーにする（別の基準へ切り替えない。origin/main が古いときは、git fetch origin main で取得する）

Go の構文木による規則（実時計・入出力・グローバル変数・日本語の直書き・ログの秘密値・機密を持つ構造体の整形）の検査は、
src/relay/internal/session/rules_test.go が行う。ここは、別の実装（正規表現）による検査。

削除系の語は、このファイルにそのまま書かない（断片を連結して組み立てる。CI の hygiene が、このファイルも検査する）。
"""
import os
import re
import subprocess
import sys
import tempfile

SESSION_DIR = "src/relay/internal/session"
BACKEND_DIR = "src/relay/internal/backend"
EXPECTED_FILES = {
    SESSION_DIR: [
        "doc.go", "interfaces.go", "options.go", "errors.go", "clock.go", "wire.go", "protocol.go", "session.go", "session_input.go",
        "session_output.go", "session_publish.go", "session_heartbeat.go", "session_close.go", "connection.go", "registry.go",
        "factory.go", "rules_test.go", "fakes_test.go", "harness_test.go", "export_test.go", "connection_test.go", "registry_test.go",
        "session_flow_test.go", "session_heartbeat_test.go", "session_interrupt_test.go", "session_close_test.go",
        "session_extra_test.go", "integration_test.go", "logging_test.go", "protocol_test.go", "wire_test.go", "options_test.go",
        "factory_test.go",
    ],
    BACKEND_DIR: [
        "doc.go", "redact.go", "errors.go", "types.go", "client.go", "events.go", "waiter.go",
        "client_test.go", "events_test.go", "redact_test.go", "helpers_test.go",
    ],
}
# 変更してよい、src/relay の下のパス（ディレクトリは前方一致、ファイルは完全一致）
ALLOWED_RELAY_DIRS = ("src/relay/internal/session/", "src/relay/internal/backend/")
ALLOWED_RELAY_FILES = ("src/relay/go.mod", "src/relay/go.sum")
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
    """比較の基準（PR の土台）のコミットを解決できない。"""


def relay_changes(root, base=DEFAULT_BASE_REF):
    """PR のブランチ（HEAD）が、基準 base との共通の祖先から変えたパスのうち、src/relay の下のもの（コミット済みの内容だけ）。

    作業ツリーの未コミットの変更・未追跡のファイルは見ない（他の issue の作業のことがあり、PR の内容ではない）。
    名前の変更は、元の名前と新しい名前の両方を数える。基準を解決できなければ BaseRefError（別の基準へ切り替えない）。
    """
    check = subprocess.run(["git", "rev-parse", "--verify", "--quiet", base + "^{commit}"], cwd=root, capture_output=True, text=True)
    if check.returncode != 0:
        raise BaseRefError(f"比較の基準 {base} を解決できません。git fetch origin main で取得するか、基準を引数（PR_BASE_REF）で指定してください")
    diff = subprocess.run(["git", "diff", "--no-renames", "--name-only", "-z", base + "...HEAD", "--", "src/relay"],
                          cwd=root, capture_output=True, text=True)
    if diff.returncode != 0:
        raise BaseRefError(f"{base} と HEAD の差を取れません: {diff.stderr.strip()[:200]}")
    return sorted(path for path in diff.stdout.split("\0") if path)


def outside_scope(paths):
    """変更してよい範囲の外のパス。"""
    return [p for p in paths if not (p.startswith(ALLOWED_RELAY_DIRS) or p in ALLOWED_RELAY_FILES)]


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
        ("台帳のメソッドの Remove は可", "r.remove(s, false)\nr.Remove(s)", 0),
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
        ("取り込みセッションの下", "src/relay/internal/session/session.go", False),
        ("内部通信クライアントの下", "src/relay/internal/backend/client_test.go", False),
        ("go.mod", "src/relay/go.mod", False),
        ("go.sum", "src/relay/go.sum", False),
        ("go.mod に似た別のファイル", "src/relay/go.modx", True),
        ("参照のみの rtmps", "src/relay/internal/rtmps/publisher.go", True),
        ("参照のみの flv", "src/relay/internal/flv/muxer.go", True),
        ("参照のみの core", "src/relay/core/frame/frame.go", True),
        ("名前の似たディレクトリ", "src/relay/internal/sessionx/a.go", True),
        ("別の issue の wsapi", "src/relay/internal/wsapi/handler.go", True),
        ("設定", "src/relay/internal/config/config.go", True),
    ]
    failures = []
    for name, path, want in cases:
        got = bool(outside_scope([path]))
        if got != want:
            failures.append(f"{name}: 範囲の外 = {got}、期待 {want}")
    return len(cases), failures


def fixture_cases():
    """git の差の取り方の自己検査（TH4：実リポジトリではなく、一時ディレクトリの最小の確認用リポジトリに対して行う）。

    確かめること：(1) PR のブランチのコミット済みの変更だけが数えられる（2) 作業ツリーの未コミットの変更・未追跡のファイルは
    数えられない（他の issue の作業があっても失敗しない）(3) 基準を解決できなければ BaseRefError。
    一時ディレクトリは、作るだけで、片づけない（削除系の操作をしない方針）。
    """
    failures = []
    work = os.path.realpath(tempfile.mkdtemp(prefix="issue20-scan-"))
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

    try:
        git("init", "-q", "-b", "main")
        if os.path.realpath(git("rev-parse", "--show-toplevel").strip()) != work:
            return 1, ["確認用リポジトリの場所が想定と違います。安全のため、中止しました"]
        write("src/relay/internal/session/base.go", "package session\n")
        git("add", "-A")
        git("commit", "-q", "-m", "base")
        git("update-ref", "refs/remotes/origin/main", "HEAD")  # 基準（origin/main）を、確認用に用意する
        git("checkout", "-q", "-b", "pr")
        write("src/relay/internal/session/added.go", "package session\n")
        write("src/relay/internal/rtmps/outside.go", "package rtmps\n")
        write("src/backend/other.rb", "x = 1\n")  # src/relay の外は、数えない
        git("add", "-A")
        git("commit", "-q", "-m", "pr")
        # 他の issue の作業（未コミットの変更と、未追跡のファイル）。数えてはならない
        write("src/relay/internal/session/base.go", "package session\n// 未コミットの変更\n")
        write("src/relay/internal/wsapi/untracked.go", "package wsapi\n")
        write("src/relay/go.mod", "module x\n")

        changed = relay_changes(work, DEFAULT_BASE_REF)
        want = ["src/relay/internal/rtmps/outside.go", "src/relay/internal/session/added.go"]
        if changed != want:
            failures.append(f"コミット済みの変更だけが数えられる: {changed}、期待 {want}（未コミットの変更を数えていないか）")
        if outside_scope(changed) != ["src/relay/internal/rtmps/outside.go"]:
            failures.append(f"範囲の外の判定: {outside_scope(changed)}")
        try:
            relay_changes(work, "origin/no-such-branch")
            failures.append("基準を解決できないのに、エラーにならなかった")
        except BaseRefError:
            pass
        git("checkout", "-q", "main")
        if relay_changes(work, DEFAULT_BASE_REF) != []:
            failures.append("基準と同じコミットで、差が空にならなかった")
    except (subprocess.CalledProcessError, OSError) as error:
        stderr = getattr(error, "stderr", "") or ""
        failures.append(f"確認用リポジトリの操作に失敗しました: {error.__class__.__name__}: {stderr.strip()[:200]}")
    return 4, failures


def self_test():
    """走査器が、違反を見逃さず、違反でないものを誤検知しないこと。"""
    total = 0
    failures = []
    for run in (text_cases, scope_cases, fixture_cases):
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
