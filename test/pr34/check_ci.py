#!/usr/bin/env python3
"""issue #2 の ci.yml の検査（TDD の「赤」を先に作るためのテスト）。

実行: python3 -I check_ci.py <リポジトリのルート> <作業ディレクトリ（一時ファイルの置き場。削除はしない）>

  1. 構造の検査: 受け入れ条件（トリガー・permissions・アクションの版・timeout・concurrency・各 job の手順の順序 ほか）
  2. hygiene の動作の検査: ci.yml の hygiene の各ステップの run を取り出し、一時の git リポジトリ（作業ディレクトリの下）で実行して、
     違反なら失敗・問題なければ成功になること（陽性・陰性の両方）。許可リスト（ファイル単位）の動作を含む。
     実際のリポジトリ（git archive HEAD に、ci.yml と、このディレクトリの作業ツリーの版を重ねたもの）でも成功すること

このソースには、削除系コマンドの語を、そのまま書かない（CLAUDE.md。test/pr33/lib/common.sh の W_* と同じ方式）。
テストデータは、クラス W の部品から組み立てる。CI の hygiene が、このファイル自身を検査するため（許可リストに頼らない）。
同じ理由で、絵文字の範囲の確認に使う文字は、\\uXXXX の形か、コードポイントの表記で書く。

git の読み取り（git archive）と、作業ディレクトリ内の一時リポジトリでの git init・git add だけを使う。
実際のリポジトリの git の状態は変えない。ファイルは削除しない（一時リポジトリは、ケースごとに新しい名前で作る）。
"""

import itertools
import os
import re
import shutil
import subprocess
import sys
import time

import yaml

REPO = os.path.abspath(sys.argv[1])
# 同じ作業ディレクトリで何度実行しても衝突しないよう、実行ごとに新しい名前の下位ディレクトリを使う（ファイルは削除しない）
WORK = os.path.join(os.path.abspath(sys.argv[2]), time.strftime("run_%Y%m%d_%H%M%S") + f"_{os.getpid()}")
WORKFLOW_PATH = os.environ.get("CI_YML") or os.path.join(REPO, ".github", "workflows", "ci.yml")  # CI_YML: 変異テスト用に、別のファイルを検査する
HERE = os.path.dirname(os.path.abspath(__file__))

RESULTS = {"ok": 0, "fail": 0}
COUNTER = itertools.count(1)


class W:
    """削除系コマンドの語の部品。語は、隣り合う文字列を連結して作る（ソースの上では、語が連続しない）。

    使い方: f"{W.RM} -rf build"。test/pr33/lib/common.sh の W_*（W_RM="r""m" など）と同じ方式。
    ここの定数名は、大文字（小文字の語として検査に掛からないようにするため）。
    """

    RM = "r" "m"
    RMDIR = "r" "mdir"
    RMI = "r" "mi"
    UNLINK = "un" "link"
    SHRED = "sh" "red"
    DELETE = "de" "lete"
    CLEAN = "cl" "ean"
    DOWN = "do" "wn"
    PRUNE = "pr" "une"
    CLEAR = "cl" "ear"
    REMOVE = "re" "move"
    REMOVE_CAMEL = "Re" "move"
    RIMRAF = "rim" "raf"
    CLOBBER = "clo" "bber"
    RMTREE = "r" "mtree"


def report(ok, label, detail=""):
    RESULTS["ok" if ok else "fail"] += 1
    print(("ok   " if ok else "FAIL ") + label + ((" -- " + detail) if (detail and not ok) else ""))


def check(label, condition, detail=""):
    report(bool(condition), label, detail)


# ---------------------------------------------------------------------------
# 構造の検査
# ---------------------------------------------------------------------------


def load_workflow():
    if not os.path.isfile(WORKFLOW_PATH):
        report(False, "S01 .github/workflows/ci.yml がある", WORKFLOW_PATH)
        return None
    report(True, "S01 .github/workflows/ci.yml がある")
    with open(WORKFLOW_PATH, encoding="utf-8") as handle:
        text = handle.read()
    try:
        workflow = yaml.safe_load(text)
    except yaml.YAMLError as error:
        report(False, "S02 YAML として読める", str(error))
        return None
    report(True, "S02 YAML として読める")
    return workflow, text


def triggers(workflow):
    # YAML 1.1 では、キー on が真偽値 True になる
    return workflow.get("on", workflow.get(True))


def all_steps(workflow):
    for job_id, job in workflow["jobs"].items():
        for index, step in enumerate(job.get("steps", [])):
            yield job_id, index, step


def step_by_id(job, step_id):
    for step in job["steps"]:
        if step.get("id") == step_id:
            return step
    return None


def index_of(job, needle, key="run"):
    """job の steps のうち、key の値に needle（正規表現）を含む最初のステップの位置。無ければ -1"""
    for index, step in enumerate(job["steps"]):
        value = step.get(key)
        if isinstance(value, str) and re.search(needle, value):
            return index
    return -1


def structure_checks(workflow, text):
    on = triggers(workflow)
    check("S03 トリガーは pull_request", isinstance(on, dict) and "pull_request" in on)
    push = (on or {}).get("push")
    check("S03 トリガーは push（main だけ）", isinstance(push, dict) and push.get("branches") == ["main"], str(push))
    check("S03 トリガーはこの 2 つだけ", set((on or {}).keys()) == {"pull_request", "push"}, str(set((on or {}).keys())))

    check("S04 permissions は contents: read だけ（workflow）", workflow.get("permissions") == {"contents": "read"}, str(workflow.get("permissions")))
    check("S04 job に permissions を持たない（広げない）", all("permissions" not in job for job in workflow["jobs"].values()))

    jobs = workflow["jobs"]
    check("S05 job は backend・frontend・relay・hygiene の 4 つだけ", set(jobs.keys()) == {"backend", "frontend", "relay", "hygiene"}, str(set(jobs.keys())))
    check("S05 job の name を付けない（チェック名が job の識別子のままになる）", all("name" not in job for job in jobs.values()))
    check("S06 すべての job に timeout-minutes", all(isinstance(job.get("timeout-minutes"), int) for job in jobs.values()))
    check("S20 runs-on は ubuntu-24.04（ubuntu-latest は 2026-11 に 26.04 へ移る）", all(job.get("runs-on") == "ubuntu-24.04" for job in jobs.values()))

    bad_uses = []
    for job_id, _, step in all_steps(workflow):
        uses = step.get("uses")
        if uses and not re.fullmatch(r"[\w.-]+/[\w.-]+@v\d+", uses):
            bad_uses.append(f"{job_id}:{uses}")
    check("S07 すべての uses はメジャーバージョンを固定（owner/repo@v<数字>）", not bad_uses, str(bad_uses))
    allowed = {"actions/checkout", "actions/setup-node", "actions/setup-go", "ruby/setup-ruby"}
    used = {step["uses"].split("@")[0] for _, _, step in all_steps(workflow) if step.get("uses")}
    check("S07 使う action は checkout・setup-node・setup-go・setup-ruby だけ", used <= allowed, str(used - allowed))

    check("S08 すべての step に name", all(isinstance(step.get("name"), str) and step["name"] for _, _, step in all_steps(workflow)))
    names = [(job_id, step.get("name")) for job_id, _, step in all_steps(workflow)]
    check("S08 step の name は job 内で重複しない", len(names) == len(set(names)))

    concurrency = workflow.get("concurrency")
    check("S09 concurrency（古い実行の取り消し）", isinstance(concurrency, dict) and "cancel-in-progress" in concurrency and "group" in concurrency, str(concurrency))

    # TH5: 長い実行コマンドにも timeout を付ける
    missing = []
    for job_id, _, step in all_steps(workflow):
        run = step.get("run")
        if run is None or step["name"] == "使用する版の表示":
            continue  # 版を表示するだけの step（ruby -v など）は、長い実行コマンドではない
        if not re.search(r"(^|[\s;&|(])timeout\s", run, re.M):
            missing.append(f"{job_id}:{step['name']}")
    check("S10 すべての run のステップに timeout（TH5。版の表示だけの step を除く）", not missing, str(missing))
    check("S10 timeout は --kill-after（-k）つき", all(re.search(r"timeout\s+(-k|--kill-after)", s["run"]) for _, _, s in all_steps(workflow) if s.get("run") and s["name"] != "使用する版の表示"))
    check("S10 bundle install を行う uses の step（ruby/setup-ruby）にも timeout-minutes", step_by_id(jobs["backend"], "ruby") is not None and isinstance(step_by_id(jobs["backend"], "ruby").get("timeout-minutes"), int))

    # デプロイ・リリース・公開の step を含めない
    forbidden_uses = re.compile(r"(deploy|release|publish|pages|upload-artifact|docker/login|aws-actions|azure/|google-github-actions)", re.I)
    check("S11 デプロイ・リリース・公開の action を使わない", not [s["uses"] for _, _, s in all_steps(workflow) if s.get("uses") and forbidden_uses.search(s["uses"])])
    forbidden_run = re.compile(r"(gh\s+release|vercel|railway|docker\s+push|npm\s+publish|gem\s+push|git\s+push|git\s+tag|gh\s+pr\s+merge|curl\s+[^|\n]*-X\s*(POST|PUT))", re.I)
    check("S11 run にデプロイ・リリース・公開のコマンドが無い", not [s["name"] for _, _, s in all_steps(workflow) if s.get("run") and forbidden_run.search(s["run"])])
    check("S11 secrets を参照しない（資格情報をリポジトリ・CI に持ち込まない）", "secrets." not in text)
    check("S11 ${{ }} を run の中で使わない（run をそのまま bash で実行して確かめられる）", not [s["name"] for _, _, s in all_steps(workflow) if s.get("run") and "${{" in s["run"]])

    defaults = workflow.get("defaults", {}).get("run", {})
    check("S12 defaults.run.shell は bash（-eo pipefail）", defaults.get("shell") == "bash", str(defaults))

    # checkout
    checkouts = [(job_id, step) for job_id, _, step in all_steps(workflow) if str(step.get("uses", "")).startswith("actions/checkout@")]
    check("S13 すべての job が checkout する", {job_id for job_id, _ in checkouts} == set(jobs.keys()))
    check("S13 checkout はリポジトリ全体（sparse-checkout なし）", all("sparse-checkout" not in (step.get("with") or {}) for _, step in checkouts))
    check("S13 checkout は認証情報を残さない（persist-credentials: false）", all((step.get("with") or {}).get("persist-credentials") is False for _, step in checkouts))
    check("S13 checkout は job の最初の step", all(job["steps"][0].get("uses", "").startswith("actions/checkout@") for job in jobs.values()))

    # backend
    backend = jobs["backend"]
    service = (backend.get("services") or {}).get("postgres") or {}
    check("S14 backend: PostgreSQL 17 のサービスコンテナ", service.get("image") == "postgres:17", str(service.get("image")))
    benv = backend.get("env") or {}
    check("S14 backend: RAILS_ENV=test", benv.get("RAILS_ENV") == "test", str(benv))
    database_url = str(benv.get("DATABASE_URL", ""))
    check("S14 backend: DATABASE_URL を明示し、DB 名は bl_test（開発 DB の名前を使わない）", database_url.endswith("/bl_test") and "bl_development" not in database_url, database_url)
    check("S14 backend: DATABASE_URL は localhost のサービスコンテナを指す", "@localhost:5432/" in database_url, database_url)
    check("S14 backend: ダミーのパスワード（dummy-）", "dummy-" in database_url and "dummy-" in str((service.get("env") or {}).get("POSTGRES_PASSWORD", "")))
    check("S14 backend: POSTGRES_DB は DATABASE_URL の DB と同じ", (service.get("env") or {}).get("POSTGRES_DB") == "bl_test")
    check("S14 backend: ports に 5432", any("5432" in str(p) for p in service.get("ports", [])))
    check("S14 backend: ヘルスチェックの options", "--health-cmd" in str(service.get("options", "")))
    ruby = step_by_id(backend, "ruby") or {}
    check("S14 backend: ruby/setup-ruby（3.4・bundler-cache・working-directory）", str(ruby.get("uses", "")).startswith("ruby/setup-ruby@v") and str((ruby.get("with") or {}).get("ruby-version")) == "3.4" and (ruby.get("with") or {}).get("bundler-cache") is True and (ruby.get("with") or {}).get("working-directory") == "src/backend", str(ruby))
    order = [index_of(backend, r"bin/rubocop"), index_of(backend, r"bin/brakeman"), index_of(backend, r"bin/bundler-audit"), index_of(backend, r"bundle exec rspec")]
    check("S15 backend: RuboCop → brakeman → bundler-audit → RSpec の順（すべてある）", all(i >= 0 for i in order) and order == sorted(order), str(order))
    check("S15 backend: bundle install（setup-ruby）が RuboCop より前", ruby in backend["steps"] and backend["steps"].index(ruby) < order[0])
    brakeman = backend["steps"][order[1]]["run"] if order[1] >= 0 else ""
    check("S15 backend: brakeman は scripts/container/test_backend.sh と同じ引数", "--quiet --no-pager --exit-on-warn --exit-on-error" in brakeman, brakeman)
    audit = backend["steps"][order[2]]["run"] if order[2] >= 0 else ""
    check("S15 backend: bundler-audit は check --update", "bin/bundler-audit check --update" in audit, audit)
    check("S15 backend: db:prepare が RSpec より前", 0 <= index_of(backend, r"db:prepare") < order[3])
    check("S15 backend: working-directory は src/backend", (workflow.get("defaults", {}).get("run", {}).get("working-directory") == "src/backend") or (backend.get("defaults", {}).get("run", {}).get("working-directory") == "src/backend"))

    # frontend
    frontend = jobs["frontend"]
    node = next((s for s in frontend["steps"] if str(s.get("uses", "")).startswith("actions/setup-node@")), {})
    check("S16 frontend: actions/setup-node（Node 22・npm のキャッシュ）", str((node.get("with") or {}).get("node-version")) == "22" and (node.get("with") or {}).get("cache") == "npm" and (node.get("with") or {}).get("cache-dependency-path") == "src/frontend/package-lock.json", str(node))
    forder = [index_of(frontend, r"npm ci"), index_of(frontend, r"npm run lint"), index_of(frontend, r"npm run typecheck"), index_of(frontend, r"npm test"), index_of(frontend, r"npm run build"), index_of(frontend, r"npm audit --omit=dev")]
    check("S16 frontend: npm ci → ESLint → 型検査 → Jest → next build → npm audit の順（すべてある）", all(i >= 0 for i in forder) and forder == sorted(forder), str(forder))
    check("S16 frontend: Jest は --ci", "--ci" in (frontend["steps"][forder[3]]["run"] if forder[3] >= 0 else ""))
    check("S16 frontend: working-directory は src/frontend", frontend.get("defaults", {}).get("run", {}).get("working-directory") == "src/frontend")
    check("S16 frontend: NEXT_TELEMETRY_DISABLED", (frontend.get("env") or {}).get("NEXT_TELEMETRY_DISABLED") in ("1", 1))

    # relay
    relay = jobs["relay"]
    go = next((s for s in relay["steps"] if str(s.get("uses", "")).startswith("actions/setup-go@")), {})
    check("S17 relay: actions/setup-go（go.mod の版・go.sum のキャッシュ）", (go.get("with") or {}).get("go-version-file") == "src/relay/go.mod" and (go.get("with") or {}).get("cache-dependency-path") == "src/relay/go.sum", str(go))
    rorder = [index_of(relay, r"gofmt"), index_of(relay, r"go vet"), index_of(relay, r"go test")]
    check("S17 relay: gofmt → go vet → go test の順（すべてある）", all(i >= 0 for i in rorder) and rorder == sorted(rorder), str(rorder))
    check("S17 relay: go test は -race ./...", bool(re.search(r"go test\b[^\n]*-race[^\n]*\./\.\.\.", relay["steps"][rorder[2]]["run"])) if rorder[2] >= 0 else False)
    check("S17 relay: go vet ./...", "go vet ./..." in (relay["steps"][rorder[1]]["run"] if rorder[1] >= 0 else ""))
    check("S17 relay: GIN_MODE=test", (relay.get("env") or {}).get("GIN_MODE") == "test")
    check("S17 relay: working-directory は src/relay", relay.get("defaults", {}).get("run", {}).get("working-directory") == "src/relay")

    # hygiene
    hygiene = jobs["hygiene"]
    ids = [s.get("id") for s in hygiene["steps"] if s.get("run")]
    check("S18 hygiene: 検査の step は secrets・deletion・emoji の 3 つ", ids == ["secrets", "deletion", "emoji"], str(ids))
    check("S18 hygiene: 検査はどれかが失敗しても、残りを実行する（if: !cancelled()）", all("!cancelled()" in str(step_by_id(hygiene, i).get("if", "")) for i in ["secrets", "deletion", "emoji"]))

    # 失敗しても、ほかの検査を続ける（backend・frontend・relay）。準備の step（id）の成否だけを見る
    ungated = []
    for job_id in ("backend", "frontend", "relay"):
        steps = jobs[job_id]["steps"]
        referenced = {ref for step in steps for ref in re.findall(r"steps\.([\w-]+)\.outcome", str(step.get("if", "")))}
        for step in steps:
            is_prep = step.get("id") in referenced and "if" not in step  # 準備の step（前の step がすべて成功したときだけ実行する、既定の if）
            if step.get("run") and step["name"] != "使用する版の表示" and not is_prep and "!cancelled()" not in str(step.get("if", "")):
                ungated.append(f"{job_id}:{step['name']}")
    check("S19 準備の後の run の step は、前の失敗に関わらず実行する（if: !cancelled() ...）", not ungated, str(ungated))
    refs = []
    for job_id, _, step in all_steps(workflow):
        for ref in re.findall(r"steps\.([\w-]+)\.outcome", str(step.get("if", ""))):
            refs.append((job_id, ref))
    ids = {(job_id, step.get("id")) for job_id, _, step in all_steps(workflow) if step.get("id")}
    check("S19 if が参照する steps.<id> は、同じ job に実在する", all(ref in ids for ref in refs), str([r for r in refs if r not in ids]))


# ---------------------------------------------------------------------------
# hygiene の動作の検査
# ---------------------------------------------------------------------------


def git(repo, *args, check_ok=True):
    return subprocess.run(["git", "-C", repo, *args], check=check_ok, capture_output=True)


def make_repo(files):
    """作業ディレクトリの下に、新しい一時リポジトリを作る。files は {パス: 内容（str・bytes）または (内容, 実行ビット)}"""
    root = os.path.join(WORK, "cases", f"case_{next(COUNTER):04d}")
    os.makedirs(root)
    subprocess.run(["git", "init", "-q", root], check=True)
    for path, value in files.items():
        executable = False
        if isinstance(value, tuple):
            value, executable = value
        full = os.path.join(root, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as handle:
            handle.write(value if isinstance(value, bytes) else value.encode("utf-8"))
        if executable:
            os.chmod(full, 0o755)
    git(root, "add", "-A", "-f")
    return root


def run_step(workflow, step_id, cwd):
    step = step_by_id(workflow["jobs"]["hygiene"], step_id)
    script_path = os.path.join(WORK, "scripts", f"{step_id}.sh")
    os.makedirs(os.path.dirname(script_path), exist_ok=True)
    with open(script_path, "w", encoding="utf-8") as handle:
        handle.write(step["run"])
    env = {"PATH": os.environ["PATH"], "HOME": WORK, "LANG": "C.UTF-8", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}
    env.update({k: str(v) for k, v in (workflow.get("env") or {}).items()})
    env.update({k: str(v) for k, v in (workflow["jobs"]["hygiene"].get("env") or {}).items()})
    env.update({k: str(v) for k, v in (step.get("env") or {}).items()})
    # GitHub Actions と同じシェル（defaults.run.shell: bash → bash --noprofile --norc -eo pipefail {0}）
    return subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", script_path], cwd=cwd, env=env, capture_output=True, text=True, timeout=300)


def expect(workflow, step_id, label, files, should_pass, must_contain=(), must_not_contain=()):
    repo = make_repo(files)
    result = run_step(workflow, step_id, repo)
    output = result.stdout + result.stderr
    passed = (result.returncode == 0) == should_pass
    detail = f"終了コード {result.returncode}。出力: {output[-600:]}"
    for needle in must_contain:
        if needle not in output:
            passed = False
            detail += f" / 出力に「{needle}」が無い"
    for needle in must_not_contain:
        if needle in output:
            passed = False
            detail += f" / 出力に「{needle}」がある"
    report(passed, f"{step_id}: {label}", detail)


def secrets_checks(workflow):
    ok = {"README.md": "x\n"}
    expect(workflow, "secrets", "機密が無ければ成功（.env.example は許可）", {**ok, ".env.example": "KEY=\n", "src/a/.env.example": "K=\n", "docs/env.md": "x\n", ".envrc": "x\n", "config/credentials.yml.enc": "x\n"}, True)
    for path in [".env", "src/backend/.env", ".env.local", ".env.production", "src/frontend/.env.development.local", "config/master.key", "src/backend/config/master.key", "src/backend/config/credentials/production.key", "certs/server.pem", "a/b/server.PEM", "keys/deploy.key", "鍵/秘密 の 鍵.pem", "src/backend/master.key"]:
        expect(workflow, "secrets", f"追跡されていたら失敗: {path}", {**ok, path: "x\n"}, False, must_contain=[path])
    # ::error:: の行に出すパスは、% を %25 へ書き換える（ワークフローコマンドの値として安全にするため）
    expect(workflow, "secrets", "::error:: に出すパスは % を書き換える（keys/a%b.pem）", {**ok, "keys/a%b.pem": "x\n"}, False, must_contain=["::error::", "keys/a%25b.pem"])


def deletion_checks(workflow):
    clean_scripts = {"scripts/ok.sh": "#!/usr/bin/env bash\necho hello\nmkdir -p tmp/x\nmv a b\ncp a b\n"}
    expect(
        workflow, "deletion", "削除系が無ければ成功（別の語の一部・ファイル名の一部は許す）",
        {**clean_scripts, "scripts/words.sh": f"#!/usr/bin/env bash\necho form norm firm perform firmware confirm\nls {W.RM}.md {W.RM}_foo {W.RM}-foo\nnpm run format\n"}, True,
    )
    # 違反の例。語は、W の部品から組み立てる（このソースに、語をそのまま書かない）。ブランチの削除のオプションは、文字列を分けて書く
    violations = {
        f"{W.RM} -rf（スクリプト）": ("scripts/x.sh", f"#!/usr/bin/env bash\n{W.RM} -rf build\n"),
        f"{W.RM}（行頭に空白）": ("scripts/x.sh", f"#!/usr/bin/env bash\n  {W.RM} file\n"),
        f"{W.RM}（&& の後ろ）": ("scripts/x.sh", f"cd x && {W.RM} file\n"),
        f"{W.RM}（絶対パス）": ("scripts/x.sh", f"/bin/{W.RM} file\n"),
        f"{W.RM}（引用符の中・配列）": ("scripts/x.sh", f'args=("{W.RM}" "-f")\n'),
        f"{W.RM}（ワークフローの run）": (".github/workflows/x.yml", f"jobs:\n  a:\n    steps:\n      - run: {W.RM} -rf build\n"),
        f"{W.RM}（Dockerfile）": ("src/relay/Dockerfile", f"FROM scratch\nRUN {W.RM} -rf /var/lib/apt/lists/*\n"),
        f"{W.RM}（Dockerfile.dev）": ("docker/Dockerfile.dev", f"FROM scratch\nRUN {W.RM} -f x\n"),
        f"{W.RM}（compose）": ("docker-compose.yml", f"services:\n  a:\n    command: sh -c '{W.RM} -f x'\n"),
        W.RMDIR: ("scripts/x.sh", f"{W.RMDIR} x\n"),
        W.UNLINK: ("scripts/x.sh", f"{W.UNLINK} x\n"),
        W.SHRED: ("scripts/x.sh", f"{W.SHRED} x\n"),
        f"find -{W.DELETE}": ("scripts/x.sh", f"find . -name '*.tmp' -{W.DELETE}\n"),
        f"git {W.CLEAN}": ("scripts/x.sh", f"git {W.CLEAN} -fdx\n"),
        "git branch の削除（大文字）": ("scripts/x.sh", "git branch -" "D foo\n"),
        f"git worktree {W.REMOVE}": ("scripts/x.sh", f"git worktree {W.REMOVE} ../x\n"),
        f"git {W.RM}": ("scripts/x.sh", f"git {W.RM} file\n"),
        f"docker {W.RM}": ("scripts/x.sh", f"docker {W.RM} foo\n"),
        f"docker {W.RMI}": ("scripts/x.sh", f"docker {W.RMI} foo\n"),
        f"docker volume {W.RM}": ("scripts/x.sh", f"docker volume {W.RM} foo\n"),
        f"docker compose {W.DOWN}": ("scripts/x.sh", f"docker compose {W.DOWN}\n"),
        f"docker compose -f x.yml {W.DOWN} -v": ("scripts/x.sh", f"docker compose -f x.yml {W.DOWN} -v\n"),
        f"docker-compose {W.DOWN}": ("scripts/x.sh", f"docker-compose {W.DOWN}\n"),
        f"docker system {W.PRUNE}": ("scripts/x.sh", f"docker system {W.PRUNE} -af\n"),
        f"{W.PRUNE}（npm）": ("scripts/x.sh", f"npm {W.PRUNE}\n"),
        f"docker run --{W.RM}": ("scripts/x.sh", f"docker run --{W.RM} img\n"),
        f"rsync --{W.DELETE}": ("scripts/x.sh", f"rsync -a --{W.DELETE} a b\n"),
        f"--{W.DELETE}-after": ("scripts/x.sh", f"rsync -a --{W.DELETE}-after a b\n"),
        f"FileUtils.{W.RM}_rf": ("scripts/x.rb", f"FileUtils.{W.RM}_rf('x')\n"),
        f"File.{W.DELETE}": ("scripts/x.rb", f"File.{W.DELETE}('x')\n"),
        f"Dir.{W.RMDIR}": ("scripts/x.rb", f"Dir.{W.RMDIR}('x')\n"),
        f"fs.{W.RM}Sync": ("scripts/x.js", f"fs.{W.RM}Sync('x')\n"),
        f"fs.{W.UNLINK}Sync": ("scripts/x.js", f"fs.{W.UNLINK}Sync('x')\n"),
        f"os.{W.REMOVE_CAMEL}All": ("scripts/x.go", f'os.{W.REMOVE_CAMEL}All("x")\n'),
        f"shutil.{W.RMTREE}": ("scripts/x.py", f"shutil.{W.RMTREE}('x')\n"),
        f"os.{W.REMOVE}": ("scripts/x.py", f"os.{W.REMOVE}('x')\n"),
        f"log:{W.CLEAR}": ("scripts/x.sh", f"bin/rails log:{W.CLEAR}\n"),
        f"tmp:{W.CLEAR}": ("scripts/x.sh", f"bin/rails tmp:{W.CLEAR}\n"),
        W.RIMRAF: ("scripts/x.sh", f"npx {W.RIMRAF} dist\n"),
        "実行権限つきのファイル（拡張子なし）": ("src/backend/bin/setup", (f"#!/usr/bin/env ruby\nsystem('{W.RM} -rf tmp')\n", True)),
        "拡張子 .sh（scripts の外）": ("tools/x.sh", f"{W.RM} -rf x\n"),
        "行末のコメントは除外しない": ("scripts/x.sh", f"{W.RM} -rf x # comment\n"),
    }
    for label, (path, content) in violations.items():
        expect(workflow, "deletion", f"違反なら失敗: {label}", {**clean_scripts, path: content}, False, must_contain=[path])
    # ::error:: の行に出すパスは、% を %25 へ書き換える
    expect(workflow, "deletion", "::error:: に出すパスは % を書き換える（scripts/a%b.sh）", {"scripts/a%b.sh": f"{W.RM} -rf x\n"}, False, must_contain=["::error::", "scripts/a%25b.sh:1"])

    # 検査の対象外（根拠: 実行されない・対象のファイルではない）
    exempt = {
        "コメントの行": ("scripts/c.sh", f"#!/usr/bin/env bash\n# {W.RM} -rf x は使わない。find -{W.DELETE} も git {W.CLEAN} も docker compose {W.DOWN} も {W.PRUNE} も使わない\necho ok\n"),
        "文書（.md）に書いた説明": ("docs/guide.md", f"{W.RM} -rf は使わない\n```\n{W.RM} -rf x\n```\n"),
        "実行権限のない src のコード": ("src/backend/app/x.rb", f"FileUtils.{W.RM}_rf('x')\n"),
        "YAML のコメント": (".github/workflows/c.yml", f"# docker compose {W.DOWN}\non: push\n"),
    }
    for label, (path, content) in exempt.items():
        expect(workflow, "deletion", f"検査の対象外: {label}", {**clean_scripts, path: content}, True)

    # 許可リスト（ファイル単位。パスの完全一致）。ci.yml の allowed_files の 2 つだけを、検査しない。ほかは、test/ の中でも検査する
    flagged = f"#!/usr/bin/env bash\n{W.RM} -rf x\n"
    for path in ["test/pr33/lib/common.sh", "test/pr33/lib/deletion_scan.sh"]:
        expect(workflow, "deletion", f"許可リストのファイルは検査しない（ログに出す）: {path}", {**clean_scripts, path: (flagged, True)}, True, must_contain=["許可リスト", path])
    not_allowed = {
        "test/ の、許可リストにないファイル（実行権限つき）": "test/pr99/checks/a.sh",
        "test/ の、許可リストにないファイル（拡張子 .sh）": "test/pr99/lib/other.sh",
        "許可リストと同じディレクトリの、別のファイル": "test/pr33/lib/other.sh",
        "許可リストのファイル名と同じ、別のディレクトリのファイル": "test/pr99/lib/common.sh",
        "許可リストのファイル名と同じ、scripts の下のファイル": "scripts/lib/deletion_scan.sh",
        "test/pr34 のファイル": "test/pr34/check_x.sh",
    }
    for label, path in not_allowed.items():
        expect(workflow, "deletion", f"許可リストに無いファイルは検査する: {label}", {**clean_scripts, path: (flagged, True)}, False, must_contain=[path], must_not_contain=["検査しなかったファイル（許可リスト）"])
    expect(workflow, "deletion", "許可リストのファイルが無くても成功する（許可リストの表示も無い）", {**clean_scripts}, True, must_not_contain=["許可リスト"])

    # scripts/dc.sh の拒否の一覧だけを除外する（ほかのファイル・ほかの行は除外しない）
    denylist = (
        "#!/usr/bin/env bash\n"
        "readonly DENIED_TOKENS=(\n"
        f"  {W.DOWN} {W.RM} kill {W.PRUNE}\n"
        f"  --{W.RM} --{W.REMOVE}-orphans\n"
        ")\n"
        "readonly DENIED_PATTERNS=(\n"
        "  # comment\n"
        f"  '(^|[^[:alnum:]_.-])({W.RM}|{W.RMDIR}|{W.UNLINK}|{W.SHRED})([^[:alnum:]_./-]|$)'\n"
        f"  '(^|[[:space:]])-{W.DELETE}([[:space:]]|$)'\n"
        f"  'git[[:space:]]+{W.CLEAN}'\n"
        ")\n"
        "check() {\n"
        '  case "$1" in\n'
        f"    --{W.RM}=* | --volumes=*)\n"
        "      echo deny\n"
        "      ;;\n"
        "  esac\n"
        "}\n"
    )
    expect(workflow, "deletion", "scripts/dc.sh の拒否の一覧（DENIED_* の配列と case の見出し）は除外する", {"scripts/dc.sh": denylist}, True)
    expect(workflow, "deletion", "scripts/dc.sh でも、拒否の一覧の外の削除系コマンドは失敗", {"scripts/dc.sh": denylist + f"{W.RM} -rf tmp\n"}, False, must_contain=["scripts/dc.sh"])
    expect(workflow, "deletion", "scripts/dc.sh でも、配列の外の拒否の語（配列を閉じた後）は失敗", {"scripts/dc.sh": denylist.replace("readonly DENIED_TOKENS=(\n", "x=(\n")}, False, must_contain=["scripts/dc.sh"])
    expect(workflow, "deletion", "ほかのファイルの同じ配列は除外しない", {"scripts/other.sh": denylist}, False, must_contain=["scripts/other.sh"])


def emoji_checks(workflow):
    # 日本語の文章に使う記号。絵文字のデータを持つ文字（\u2194 \u00A9 \u00AE \u2122 \u203C \u2049 \u2139 \u25B6 \u25C0）は、\uXXXX の形で書く
    typographic = "\u2194 \u00A9 \u00AE \u2122 \u203C \u2049 \u2139 \u25B6 \u25C0"
    # 記号の区画にあるが、絵文字ではない文字（U+2605・U+2606・U+266A・U+266D・U+266F・U+2713・U+2717）は、平文で書かず、コードポイントから作る
    not_emoji_symbols = " ".join(chr(cp) for cp in (0x2605, 0x2606, 0x266A, 0x266D, 0x266F, 0x2713, 0x2717))
    expect(
        workflow, "emoji", "絵文字が無ければ成功（日本語・記号・矢印・著作権表示など）",
        {"src/ja.ts": f"// 日本語のコメント。※ 〜 ～ → ← ↑ ↓ ▲ ▼ ◆ ● ○ ◎ ■ □ — … ・ 「」 （） ① ② ㈱ 〒 № ℃ ㎏ 1 2 3 # * {typographic} {not_emoji_symbols}\nconst a = 1;\n"}, True,
    )
    emoji_cases = {
        "ロケット": "\U0001F680", "笑顔": "\U0001F600", "チェックマーク（緑）": "\u2705", "バツ": "\u274C", "警告（異体字選択子つき）": "\u26A0\uFE0F", "警告（単独）": "\u26A0",
        "太いチェック": "\u2714", "太いバツ": "\u2716", "ハート（異体字選択子つき）": "\u2764\uFE0F", "ハート": "\u2764", "星": "\u2B50", "日本の旗": "\U0001F1EF\U0001F1F5", "キーキャップ": "1\uFE0F\u20E3",
        "肌の色": "\U0001F44D\U0001F3FD", "きらきら": "\u2728", "時計": "\u231A", "再生ボタン（異体字選択子つき）": "\u25B6\uFE0F", "矢印（異体字選択子つき）": "\u2194\uFE0F", "枠つきの M": "\u24C2\uFE0F",
        "著作権（異体字選択子つき）": "\u00A9\uFE0F", "電話": "\u260E", "雲": "\u2601", "雷": "\u26A1", "ダイヤの A": "\U0001F170", "麻雀牌": "\U0001F004", "新しい絵文字（1FAE0 付近）": "\U0001FAE0", "丸秘（異体字選択子つき）": "\u3299\uFE0F",
    }
    for label, char in emoji_cases.items():
        expect(workflow, "emoji", f"絵文字なら失敗: {label}（U+{ord(char[0]):04X}）", {"src/frontend/app/page.tsx": f"export const a = 'x{char}y';\n"}, False, must_contain=["src/frontend/app/page.tsx", "U+"])
    expect(workflow, "emoji", "複数あれば全部を報告する（行番号つき）", {"src/a.ts": "a\n\U0001F680\nb \u2705\n"}, False, must_contain=["src/a.ts:2", "src/a.ts:3"])
    for directory in ["node_modules", "vendor", ".cache", ".next"]:
        expect(workflow, "emoji", f"除外: src/…/{directory}/ の絵文字は検査しない", {f"src/frontend/{directory}/pkg/readme.md": "\U0001F680 \u2705\n", "src/ok.ts": "ok\n"}, True)
    expect(workflow, "emoji", "除外: src の外（DOCS/・README.md）は対象外", {"DOCS/TM.md": "# \U0001F9EA\n", "README.md": "\u2705\n", "src/ok.ts": "ok\n"}, True)
    expect(workflow, "emoji", "バイナリ（NUL を含む）は読まない", {"src/img.bin": b"\x89PNG\x00\x00\xF0\x9F\x9A\x80\x00", "src/ok.ts": "ok\n"}, True)
    expect(workflow, "emoji", "UTF-8 として読めないテキストは失敗（判定不能は拒否側へ倒す）", {"src/sjis.txt": "日本語".encode("cp932")}, False, must_contain=["src/sjis.txt"])
    expect(workflow, "emoji", "src が無くても失敗しない（ファイルが 0 件）", {"README.md": "x\n"}, True)
    expect(workflow, "emoji", "ファイル名に空白・日本語があっても検査できる", {"src/日本語 の ファイル.ts": "\U0001F680\n"}, False, must_contain=["日本語 の ファイル.ts"])
    expect(workflow, "emoji", "CRLF・BOM つきのファイルも読める", {"src/crlf.ts": b"\xef\xbb\xbfconst a = 1;\r\nconst b = 2;\r\n"}, True)
    # ::error:: の行に出すパスは、% を %25 へ書き換える
    expect(workflow, "emoji", "::error:: に出すパスは % を書き換える（絵文字）", {"src/a%b.ts": "\U0001F680\n"}, False, must_contain=["::error::", "src/a%25b.ts:1:1"])
    expect(workflow, "emoji", "::error:: に出すパスは % を書き換える（UTF-8 として読めない）", {"src/c%d.txt": "日本語".encode("cp932")}, False, must_contain=["::error::", "src/c%25d.txt"])


def hygiene_checks(workflow):
    secrets_checks(workflow)
    deletion_checks(workflow)
    emoji_checks(workflow)


# ---------------------------------------------------------------------------
# hygiene の関数の検査（step の Python を、モジュールとして読み込んで検査する）
# ---------------------------------------------------------------------------


def load_step_module(workflow, step_id):
    """step の run にある python3 - <<'PY' ... PY の Python を、モジュールとして読み込む（main は実行しない）"""
    run = step_by_id(workflow["jobs"]["hygiene"], step_id)["run"]
    match = re.search(r"<<'PY'\n(.*?)\nPY\s*$", run, re.S)
    if not match:
        report(False, f"F00 {step_id}: run に python3 - <<'PY' の本文がある")
        return None
    namespace = {"__name__": f"hygiene_{step_id}"}
    exec(compile(match.group(1), f"<{step_id}>", "exec"), namespace)  # noqa: S102（自分のテスト用）
    return namespace


def perl_ranges(prop):
    """Perl の Unicode データ（Perl 5.38 は Unicode 15.0）から、プロパティを持つコードポイントの集合を返す"""
    code = (
        'use Unicode::UCD qw(prop_invlist); my @inv = prop_invlist("%s");'
        'for (my $i = 0; $i < @inv; $i += 2) { my $s = $inv[$i]; my $e = defined $inv[$i+1] ? $inv[$i+1] - 1 : 0x10FFFF; print "$s $e\\n"; }'
    ) % prop
    out = subprocess.run(["perl", "-e", code], check=True, capture_output=True, text=True).stdout
    values = set()
    for line in out.splitlines():
        low, high = (int(x) for x in line.split())
        values.update(range(low, min(high, 0x10FFFF) + 1))
    return values


def emoji_function_checks(workflow):
    emoji = load_step_module(workflow, "emoji")
    if emoji is None:
        return
    pattern = emoji["emoji_pattern"]()
    find = lambda text: emoji["find_emoji"](text, pattern)  # noqa: E731

    emoji_presentation = perl_ranges("Emoji_Presentation")
    emoji_property = perl_ranges("Emoji")
    blocks = [(0x2300, 0x23FF), (0x2600, 0x27BF), (0x2900, 0x297F), (0x2B00, 0x2BFF)]
    should_flag = {cp for cp in emoji_presentation if cp > 0x7F}
    should_flag |= {cp for cp in emoji_property if any(lo <= cp <= hi for lo, hi in blocks)}
    missed = sorted(cp for cp in should_flag if not find(chr(cp)))
    check(f"F01 emoji: Unicode の Emoji_Presentation=Yes（{len([c for c in emoji_presentation if c > 0x7F])} 文字）と、記号の区画の Emoji=Yes の文字を、すべて検出する（{len(should_flag)} 文字）", not missed, ", ".join(f"{cp:04X}" for cp in missed[:30]))

    typographic = sorted(cp for cp in emoji_property if cp > 0x7F and cp not in should_flag and not (0x1F000 <= cp <= 0x1FAFF))
    flagged_typographic = [cp for cp in typographic if find(chr(cp))]
    check(
        f"F02 emoji: 通常の文章に使う記号（{len(typographic)} 文字: 著作権・登録商標・商標の記号、感嘆符の組、矢印、三角、囲み漢字など。"
        "U+00A9・00AE・2122・203C・2049・2139・2194-2199・25B6・25C0・3297・3299 ほか）は、単独では検出しない",
        not flagged_typographic, ", ".join(f"{cp:04X}" for cp in flagged_typographic),
    )
    with_selector = [cp for cp in typographic if not find(chr(cp) + "\uFE0F")]
    check("F03 emoji: 上の記号も、異体字選択子（U+FE0F）が付くと検出する", not with_selector, ", ".join(f"{cp:04X}" for cp in with_selector))

    plain_blocks = [
        ("ASCII（キーキャップの基の 0-9・#・* を含む）", 0x0000, 0x007F), ("Latin-1・拡張", 0x0080, 0x024F), ("ギリシャ・キリル", 0x0370, 0x04FF),
        ("一般句読点（U+203C・U+2049 を含む）", 0x2000, 0x206F), ("矢印", 0x2190, 0x21FF), ("数学記号", 0x2200, 0x22FF), ("囲み英数字", 0x2460, 0x24FF),
        ("罫線・ブロック", 0x2500, 0x259F), ("日本語の約物・CJK 記号", 0x3000, 0x303F), ("ひらがな・カタカナ", 0x3040, 0x30FF),
        ("囲み CJK 文字・月・㌔ など", 0x3200, 0x33FF), ("CJK 統合漢字", 0x4E00, 0x9FFF), ("全角・半角", 0xFF00, 0xFFEF),
    ]
    for label, low, high in plain_blocks:
        found = [cp for cp in range(low, high + 1) if find(chr(cp)) and cp not in should_flag and cp not in (0xFE0F, 0x20E3)]
        check(f"F04 emoji: 通常の文字は検出しない: {label}", not found, ", ".join(f"{cp:04X}" for cp in found[:20]))
    geometric = [cp for cp in range(0x25A0, 0x25FF + 1) if find(chr(cp)) and cp not in (0x25FD, 0x25FE)]
    check("F04 emoji: 幾何学図形（■ □ ▲ ▼ ◆ ● ○ ◎ と、U+25B6・U+25C0）は検出しない（U+25FD・U+25FE を除く）", not geometric, ", ".join(f"{cp:04X}" for cp in geometric))
    music = [cp for cp in (0x2605, 0x2606, 0x266A, 0x266D, 0x266F, 0x2713, 0x2717, 0x2610, 0x2612) if find(chr(cp))]
    check("F04 emoji: U+2605・U+2606・U+266A・U+266D・U+266F・U+2713・U+2717・U+2610・U+2612 は検出しない", not music, ", ".join(f"{cp:04X}" for cp in music))
    check("F05 emoji: 行番号・桁・文字を返す", find("ab\nc\U0001F680d") == [(2, 2, "\U0001F680")], str(find("ab\nc\U0001F680d")))
    check("F05 emoji: 国旗（地域指示記号 2 つ）・肌の色・キーキャップを検出する", len(find("\U0001F1EF\U0001F1F5")) == 2 and len(find("\U0001F44D\U0001F3FD")) == 2 and len(find("1\uFE0F\u20E3")) == 2)


def deletion_function_checks(workflow):
    deletion = load_step_module(workflow, "deletion")
    if deletion is None:
        return
    compiled = [(label, [re.compile(p) for p in patterns]) for label, patterns in deletion["rules"]()]

    def labels(line):
        return [label for label, patterns in compiled if any(p.search(line) for p in patterns)]

    # 語は、W の部品から組み立てる。ブランチの削除のオプションは、文字列を分けて書く（語が連続しないようにする）
    flagged_lines = [
        f"{W.RM} -rf x", f"  {W.RM} x", f"cd a && {W.RM} b", f"a; {W.RM} b", f"a | xargs {W.RM}", f"({W.RM} x)", f"$({W.RM} x)", f"`{W.RM} x`",
        f"/bin/{W.RM} x", f"/usr/bin/{W.RM} x", f"\\{W.RM} x", f"sudo {W.RM} x", f"RUN {W.RM} -rf /tmp/x", f'CMD ["{W.RM}", "-rf"]',
        f"- {W.RM} x", f"run: {W.RM} x", f"{W.RMDIR} x", f"{W.UNLINK} x", f"{W.SHRED} -u x", f"find . -{W.DELETE}", f"find . -name a -{W.DELETE}",
        f"rsync --{W.DELETE} a b", f"rsync --{W.DELETE}-after a b", f"git {W.CLEAN} -fd", f"git {W.CLEAN}", f"git {W.RM} x", "git branch -" "d x", "git branch -" "D x",
        "git branch -" "df x", f"git worktree {W.REMOVE} x", f"docker {W.RM} x", f"docker {W.RMI} x", f"docker compose {W.DOWN}", f"docker-compose {W.DOWN}",
        f"docker compose -f a.yml {W.DOWN} -v", f"docker compose --profile x {W.DOWN}", f"docker system {W.PRUNE}", f"docker image {W.PRUNE} -a",
        f"docker volume {W.RM} x", f"docker run --{W.RM} img", f"docker compose run --{W.RM} x", f"npm {W.PRUNE}", f"git remote {W.PRUNE} origin",
        f"FileUtils.{W.RM}_rf(x)", f"FileUtils.{W.RM}(x)", f"FileUtils.{W.REMOVE}_entry(x)", f"File.{W.DELETE}(x)", f"File.{W.UNLINK}(x)", f"Dir.{W.RMDIR}(x)", f"Dir.{W.DELETE}(x)",
        f"fs.{W.RM}Sync(x)", f"fs.{W.RM}(x)", f"fs.{W.UNLINK}Sync(x)", f"fs.{W.RMDIR}Sync(x)", f"os.{W.REMOVE_CAMEL}All(x)", f"os.{W.REMOVE_CAMEL}(x)", f"os.{W.REMOVE}(x)", f"os.{W.UNLINK}(x)",
        f"shutil.{W.RMTREE}(x)", f"bin/rails log:{W.CLEAR}", f"bin/rails tmp:{W.CLEAR}", f"assets:{W.CLOBBER}", f"npx {W.RIMRAF} dist",
    ]
    wrongly_passed = [line for line in flagged_lines if not labels(line)]
    check(f"F10 deletion: 削除系の {len(flagged_lines)} 行を検出する", not wrongly_passed, str(wrongly_passed))
    clean_lines = [
        "echo form norm firm perform confirm", f"ls {W.RM}.md {W.RM}_foo {W.RM}-foo", "npm run format", "git status", "git branch -a", "git branch -vv", "git branch --list",
        f"git {W.CLEAN}up", f"git {W.CLEAN}-up", "docker compose up -d --wait",
        "docker logs x", "docker compose logs --tail 100 backend", f"echo count{W.DOWN}", "docker compose exec -T backend bundle exec rspec", "bundle exec rspec", "bin/rails db:prepare", "npm ci", "npm audit --omit=dev", "go test -race ./...",
        "timeout --kill-after=30s 5m gofmt -l .", "mkdir -p tmp/x", "mv a DELETE/20261007_a", "cp a b", "find . -name '*.go'", "echo 削除系コマンドは使わない",
        f"--no-{W.DELETE}", f"{W.DELETE}-branch: true", f"{W.PRUNE}d", f"{W.DELETE}d", f"{W.REMOVE}d", "File.read(x)", "File.rename(a, b)",
        "Dir.glob(x)", "fs.readFileSync(x)", "os.Getenv(x)", "os.Stat(x)", "process.env.X", f"pos.{W.REMOVE}", "shutil.copy(a, b)", "log:level", "tmp:dir", "FileUtils.mkdir_p(x)", "FileUtils.cp(a, b)", "arm", "perform",
    ]
    wrongly_flagged = [(line, labels(line)) for line in clean_lines if labels(line)]
    check(f"F11 deletion: 削除系でない {len(clean_lines)} 行は検出しない", not wrongly_flagged, str(wrongly_flagged))

    # 許可リスト（ファイル単位）の内容。増やすときは、理由を書き、このテストも直す
    allowed_files = deletion.get("allowed_files")
    expected = {"test/pr33/lib/common.sh", "test/pr33/lib/deletion_scan.sh"}
    allowed = allowed_files() if allowed_files else None
    check("F12 deletion: 許可リストは test/pr33/lib/common.sh と deletion_scan.sh の 2 つだけで、すべて理由つき", allowed is not None and set(allowed) == expected and all(isinstance(r, str) and r.strip() for r in allowed.values()), str(allowed))
    is_target = deletion["is_target"]
    check(
        "F13 deletion: test/ 全体を検査から外さない（実行権限つき・.sh は、test/ の中でも検査の対象）",
        is_target("100644", "test/pr99/a.sh") and is_target("100755", "test/pr99/check.py") and not is_target("100644", "test/pr99/README.md"),
    )


def function_checks(workflow):
    emoji_function_checks(workflow)
    deletion_function_checks(workflow)


# ---------------------------------------------------------------------------
# 実際のリポジトリでの検査
# ---------------------------------------------------------------------------


def overlay_workspace_files(base):
    """HEAD の複写へ、ci.yml（CI_YML があればそのファイル）と、このディレクトリ（test/pr34）の作業ツリーの版を重ねる（commit 前の変更の検査のため）"""
    target = os.path.join(base, ".github", "workflows", "ci.yml")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    shutil.copyfile(WORKFLOW_PATH, target)
    destination_dir = os.path.join(base, "test", "pr34")
    os.makedirs(destination_dir, exist_ok=True)
    copied = []
    for name in sorted(os.listdir(HERE)):
        source = os.path.join(HERE, name)
        if os.path.isfile(source) and not os.path.islink(source):
            shutil.copy2(source, os.path.join(destination_dir, name))  # 実行権限を保つ
            copied.append(name)
    return copied


def realistic_checks(workflow):
    """実際のリポジトリ（git archive HEAD）に、ci.yml と test/pr34 の作業ツリーの版を重ねた状態で、3 つの検査が成功すること。
    test/pr34 自身が、削除系の検査（許可リストの 2 つ以外）に掛からないことの確認を含む"""
    base = os.path.join(WORK, "cases", "realistic")
    os.makedirs(base)
    archive = subprocess.run(["git", "-C", REPO, "archive", "HEAD"], check=True, capture_output=True).stdout
    subprocess.run(["tar", "-x", "-C", base], input=archive, check=True)
    copied = overlay_workspace_files(base)
    subprocess.run(["git", "init", "-q", base], check=True)
    git(base, "add", "-A", "-f")
    tracked = git(base, "ls-files").stdout.decode().count("\n")
    print(f"note: 実際のリポジトリ（HEAD）+ ci.yml + test/pr34（{', '.join(copied)}）の追跡ファイル数 {tracked}")
    for step_id in ("secrets", "deletion", "emoji"):
        result = run_step(workflow, step_id, base)
        output = (result.stdout + result.stderr).strip()
        report(result.returncode == 0, f"実際のリポジトリ + ci.yml: {step_id} が成功する", f"終了コード {result.returncode}。出力: {output[-1500:]}")
        if result.returncode == 0:
            print("     出力:", output.replace("\n", " / ") if output else "（なし）")
        if step_id == "deletion":
            check("実際のリポジトリ + ci.yml: 検査しなかったファイル（許可リスト）は、test/pr33/lib の 2 つだけ", sorted(re.findall(r"^  (\S+): ", output.split("検査しなかったファイル（許可リスト）", 1)[-1], re.M)) == ["test/pr33/lib/common.sh", "test/pr33/lib/deletion_scan.sh"], output[-800:])

    # test/pr34 だけを取り出した一時リポジトリで、削除系の検査が、このディレクトリのファイルを実際に検査して、成功すること
    only = {}
    for name in sorted(os.listdir(HERE)):
        source = os.path.join(HERE, name)
        if os.path.isfile(source) and not os.path.islink(source):
            with open(source, "rb") as handle:
                only[name] = (handle.read(), os.access(source, os.X_OK))
    repo = make_repo({f"test/pr34/{name}": value for name, value in only.items()})
    result = run_step(workflow, "deletion", repo)
    output = result.stdout + result.stderr
    scanned = sum(1 for name, (_, executable) in only.items() if executable or name.endswith((".sh", ".bash")))
    check(f"F14 test/pr34 のファイル（{scanned} 件。実行権限つき・.sh）が、削除系の検査に掛からない（許可リストに頼らない）", result.returncode == 0 and f"検査したファイル {scanned} 件" in output and "許可リスト" not in output, f"終了コード {result.returncode}。出力: {output[-800:]}")


def main():
    os.makedirs(WORK, exist_ok=True)
    loaded = load_workflow()
    if loaded is None:
        print(f"\n結果: 成功 {RESULTS['ok']} / 失敗 {RESULTS['fail']}")
        return 1
    workflow, text = loaded
    structure_checks(workflow, text)
    function_checks(workflow)
    hygiene_checks(workflow)
    realistic_checks(workflow)
    print(f"\n結果: 成功 {RESULTS['ok']} / 失敗 {RESULTS['fail']}")
    return 0 if RESULTS["fail"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
