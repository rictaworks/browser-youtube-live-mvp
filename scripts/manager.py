#!/usr/bin/env python3
"""Manager.md 4 章の動作ループの補助。issue の下書きの検証と発行、readyな issue の計算。

使い方:
  manager.py validate <issues_dir>          下書きを検証する（番号・依存・循環・必須見出し・レーン分け）
  manager.py create <issues_dir> <footer>   検証したうえで gh issue create を番号順に実行する
  manager.py ready                          gh から取得した open な issue のうち、依存がすべて closed のものを出す

状態（ready/blocked）はラベルで持たず、依存関係から都度計算する（Manager.md 3 章）。
"""
import json
import pathlib
import re
import subprocess
import sys

REQUIRED_HEADINGS = ["## 目的", "## Depends on", "## Edit scope", "## 受け入れ条件"]
DEP_LINE = re.compile(r"^- \[[ xX]\] #(\d+)\s*$")
EDIT_LINE = re.compile(r"^- (\S.*?) \((create|edit|reference only)[^)]*\)\s*$")


def parse_draft(path):
    text = path.read_text(encoding="utf-8")
    head, sep, body = text.partition("\n---\n")
    if not sep:
        raise SystemExit(f"{path.name}: front matter の区切り（---）がありません")
    meta = {}
    for line in head.splitlines():
        key, _, value = line.partition(":")
        meta[key.strip()] = value.strip()
    if "TITLE" not in meta or "LABELS" not in meta:
        raise SystemExit(f"{path.name}: TITLE と LABELS が必要です")
    return meta["TITLE"], [l for l in meta["LABELS"].split(",") if l], body.strip() + "\n"


def section(body, heading):
    lines = body.splitlines()
    out, on = [], False
    for line in lines:
        if line.startswith("## "):
            on = line.strip() == heading
            continue
        if on:
            out.append(line)
    return out


def load(issues_dir):
    drafts = {}
    for path in sorted(pathlib.Path(issues_dir).glob("[0-9][0-9].md")):
        number = int(path.stem)
        title, labels, body = parse_draft(path)
        drafts[number] = {"title": title, "labels": labels, "body": body, "file": path.name}
    return drafts


def deps_of(body):
    lines = section(body, "## Depends on")
    nonblank = [l for l in lines if l.strip()]
    if nonblank == ["なし"]:
        return []
    deps = []
    for line in nonblank:
        m = DEP_LINE.match(line.strip())
        if not m:
            raise SystemExit(f"Depends on の形式が不正です: {line!r}")
        deps.append(int(m.group(1)))
    return deps


def validate(drafts):
    problems = []
    numbers = sorted(drafts)
    if numbers != list(range(1, len(numbers) + 1)):
        problems.append(f"番号が 1 から連続していません: {numbers}")
    graph = {}
    for n, d in drafts.items():
        body = d["body"]
        for h in REQUIRED_HEADINGS:
            if h not in body:
                problems.append(f"#{n}: 見出し {h} がありません")
        try:
            deps = deps_of(body)
        except SystemExit as e:
            problems.append(f"#{n}: {e}")
            deps = []
        graph[n] = deps
        for dep in deps:
            if dep not in drafts:
                problems.append(f"#{n}: 存在しない issue #{dep} への依存")
            elif dep >= n:
                problems.append(f"#{n}: 後ろの番号 #{dep} への依存（前方参照）")
        if len(deps) != len(set(deps)):
            problems.append(f"#{n}: 依存が重複しています")
        scope = [l for l in section(body, "## Edit scope") if l.strip()]
        if not scope:
            problems.append(f"#{n}: Edit scope が空です")
        for line in scope:
            if not EDIT_LINE.match(line.strip()):
                problems.append(f"#{n}: Edit scope の形式が不正です: {line.strip()!r}")
        if not any(l.strip().startswith("- [ ]") for l in section(body, "## 受け入れ条件")):
            problems.append(f"#{n}: 受け入れ条件にチェックリストがありません")
    # 循環の検出（番号の前方参照が無ければ循環は無いが、念のため位相ソート）
    indeg = {n: len(graph[n]) for n in graph}
    ready = [n for n, k in indeg.items() if k == 0]
    order = []
    while ready:
        n = ready.pop()
        order.append(n)
        for m, ds in graph.items():
            if n in ds:
                indeg[m] -= 1
                if indeg[m] == 0:
                    ready.append(m)
    if len(order) != len(graph):
        problems.append("循環依存があります")
    return problems, graph


def critical_path(graph):
    depth = {}

    def d(n):
        if n not in depth:
            depth[n] = 1 + max((d(x) for x in graph[n]), default=0)
        return depth[n]

    for n in graph:
        d(n)
    longest = max(depth.values())
    layers = {}
    for n, v in depth.items():
        layers.setdefault(v, []).append(n)
    return longest, {k: sorted(v) for k, v in sorted(layers.items())}


def cmd_validate(args):
    drafts = load(args[0])
    problems, graph = validate(drafts)
    print(f"issue 数: {len(drafts)}")
    longest, layers = critical_path(graph)
    print(f"クリティカルパスの長さ: {longest}")
    for k, v in layers.items():
        print(f"  深さ {k}: {v}")
    if problems:
        print("問題:")
        for p in problems:
            print("  -", p)
        return 1
    print("検証 OK")
    return 0


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, text=True, capture_output=True, **kw)


def cmd_create(args):
    issues_dir, footer_path = args
    drafts = load(issues_dir)
    problems, _ = validate(drafts)
    if problems:
        print("\n".join(problems))
        return 1
    footer = pathlib.Path(footer_path).read_text(encoding="utf-8")
    existing = json.loads(run(["gh", "issue", "list", "--state", "all", "--limit", "200", "--json", "number"]).stdout)
    if existing:
        print("すでに issue があります。重複発行を避けるため中止します")
        return 1
    for n in sorted(drafts):
        d = drafts[n]
        body = d["body"].rstrip("\n") + "\n\n" + footer
        cmd = ["gh", "issue", "create", "--title", d["title"], "--body", body]
        for label in d["labels"]:
            cmd += ["--label", label]
        out = run(cmd).stdout.strip()
        m = re.search(r"/issues/(\d+)$", out)
        got = int(m.group(1)) if m else None
        print(f"#{n} -> {out}")
        if got != n:
            print(f"番号が一致しません（期待 #{n}、実際 #{got}）。中止します")
            return 1
    return 0


def cmd_ready(_args):
    issues = json.loads(run(["gh", "issue", "list", "--state", "all", "--limit", "500", "--json", "number,state,title,body"]).stdout)
    state = {i["number"]: i["state"] for i in issues}
    ready, blocked = [], []
    for i in sorted(issues, key=lambda x: x["number"]):
        if i["state"] != "OPEN":
            continue
        deps = deps_of(i["body"])
        open_deps = [d for d in deps if state.get(d) != "CLOSED"]
        (blocked if open_deps else ready).append((i["number"], i["title"], open_deps))
    print("ready:")
    for n, t, _ in ready:
        print(f"  #{n} {t}")
    print("blocked:")
    for n, t, o in blocked:
        print(f"  #{n} {t}  <- 待ち: {', '.join('#' + str(x) for x in o)}")
    return 0


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cmd, args = sys.argv[1], sys.argv[2:]
    return {"validate": cmd_validate, "create": cmd_create, "ready": cmd_ready}[cmd](args)


if __name__ == "__main__":
    sys.exit(main())
