#!/usr/bin/env python3
"""issue #2 の ci.yml の検査（TDD の「赤」を先に作るためのテスト）。

実行: python3 -I check_ci.py <リポジトリのルート> <作業ディレクトリ（一時ファイルの置き場。削除はしない）>

  1. 構造の検査: 受け入れ条件（トリガー・permissions・アクションの版・timeout・concurrency・各 job の手順の順序 ほか）
  2. hygiene の動作の検査: ci.yml の hygiene の各ステップの run を取り出し、一時の git リポジトリ（作業ディレクトリの下）で実行して、
     違反なら失敗・問題なければ成功になること（陽性・陰性の両方）。実際のリポジトリ（git archive HEAD + ci.yml）でも成功すること

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

RESULTS = {"ok": 0, "fail": 0}
COUNTER = itertools.count(1)


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


def expect(workflow, step_id, label, files, should_pass, must_contain=()):
    repo = make_repo(files)
    result = run_step(workflow, step_id, repo)
    output = result.stdout + result.stderr
    passed = (result.returncode == 0) == should_pass
    detail = f"終了コード {result.returncode}。出力: {output[-600:]}"
    for needle in must_contain:
        if needle not in output:
            passed = False
            detail += f" / 出力に「{needle}」が無い"
    report(passed, f"{step_id}: {label}", detail)


def hygiene_checks(workflow):
    # ---- secrets ----
    ok = {"README.md": "x\n"}
    expect(workflow, "secrets", "機密が無ければ成功（.env.example は許可）", {**ok, ".env.example": "KEY=\n", "src/a/.env.example": "K=\n", "docs/env.md": "x\n", ".envrc": "x\n", "config/credentials.yml.enc": "x\n"}, True)
    for path in [".env", "src/backend/.env", ".env.local", ".env.production", "src/frontend/.env.development.local", "config/master.key", "src/backend/config/master.key", "src/backend/config/credentials/production.key", "certs/server.pem", "a/b/server.PEM", "keys/deploy.key", "鍵/秘密 の 鍵.pem", "src/backend/master.key"]:
        expect(workflow, "secrets", f"追跡されていたら失敗: {path}", {**ok, path: "x\n"}, False, must_contain=[path])

    # ---- deletion ----
    clean_scripts = {"scripts/ok.sh": "#!/usr/bin/env bash\necho hello\nmkdir -p tmp/x\nmv a b\ncp a b\n"}
    expect(workflow, "deletion", "削除系が無ければ成功（form・norm・firm・perform・rm.md・pr-une など語の一部は許す）", {**clean_scripts, "scripts/words.sh": "#!/usr/bin/env bash\necho form norm firm perform firmware confirm\nls rm.md rm_foo rm-foo\nnpm run format\n"}, True)
    violations = {
        "rm -rf（スクリプト）": ("scripts/x.sh", "#!/usr/bin/env bash\nrm -rf build\n"),
        "rm（行頭に空白）": ("scripts/x.sh", "#!/usr/bin/env bash\n  rm file\n"),
        "rm（&& の後ろ）": ("scripts/x.sh", "cd x && rm file\n"),
        "rm（絶対パス）": ("scripts/x.sh", "/bin/rm file\n"),
        "rm（引用符の中・配列）": ("scripts/x.sh", "args=(\"rm\" \"-f\")\n"),
        "rm（ワークフローの run）": (".github/workflows/x.yml", "jobs:\n  a:\n    steps:\n      - run: rm -rf build\n"),
        "rm（Dockerfile）": ("src/relay/Dockerfile", "FROM scratch\nRUN rm -rf /var/lib/apt/lists/*\n"),
        "rm（Dockerfile.dev）": ("docker/Dockerfile.dev", "FROM scratch\nRUN rm -f x\n"),
        "rm（compose）": ("docker-compose.yml", "services:\n  a:\n    command: sh -c 'rm -f x'\n"),
        "rmdir": ("scripts/x.sh", "rmdir x\n"),
        "unlink": ("scripts/x.sh", "unlink x\n"),
        "shred": ("scripts/x.sh", "shred x\n"),
        "find -delete": ("scripts/x.sh", "find . -name '*.tmp' -delete\n"),
        "git clean": ("scripts/x.sh", "git clean -fdx\n"),
        "git branch -D": ("scripts/x.sh", "git branch -D foo\n"),
        "git worktree remove": ("scripts/x.sh", "git worktree remove ../x\n"),
        "git rm": ("scripts/x.sh", "git rm file\n"),
        "docker rm": ("scripts/x.sh", "docker rm foo\n"),
        "docker rmi": ("scripts/x.sh", "docker rmi foo\n"),
        "docker volume rm": ("scripts/x.sh", "docker volume rm foo\n"),
        "docker compose down": ("scripts/x.sh", "docker compose down\n"),
        "docker compose -f x.yml down -v": ("scripts/x.sh", "docker compose -f x.yml down -v\n"),
        "docker-compose down": ("scripts/x.sh", "docker-compose down\n"),
        "docker system prune": ("scripts/x.sh", "docker system prune -af\n"),
        "prune（npm）": ("scripts/x.sh", "npm prune\n"),
        "docker run --rm": ("scripts/x.sh", "docker run --rm img\n"),
        "rsync --delete": ("scripts/x.sh", "rsync -a --delete a b\n"),
        "--delete-after": ("scripts/x.sh", "rsync -a --delete-after a b\n"),
        "FileUtils.rm_rf": ("scripts/x.rb", "FileUtils.rm_rf('x')\n"),
        "File.delete": ("scripts/x.rb", "File.delete('x')\n"),
        "Dir.rmdir": ("scripts/x.rb", "Dir.rmdir('x')\n"),
        "fs.rmSync": ("scripts/x.js", "fs.rmSync('x')\n"),
        "fs.unlinkSync": ("scripts/x.js", "fs.unlinkSync('x')\n"),
        "os.RemoveAll": ("scripts/x.go", "os.RemoveAll(\"x\")\n"),
        "shutil.rmtree": ("scripts/x.py", "shutil.rmtree('x')\n"),
        "os.remove": ("scripts/x.py", "os.remove('x')\n"),
        "log:clear": ("scripts/x.sh", "bin/rails log:clear\n"),
        "tmp:clear": ("scripts/x.sh", "bin/rails tmp:clear\n"),
        "rimraf": ("scripts/x.sh", "npx rimraf dist\n"),
        "実行権限つきのファイル（拡張子なし）": ("src/backend/bin/setup", ("#!/usr/bin/env ruby\nsystem('rm -rf tmp')\n", True)),
        "拡張子 .sh（scripts の外）": ("tools/x.sh", "rm -rf x\n"),
        "行末のコメントは除外しない": ("scripts/x.sh", "rm -rf x # comment\n"),
    }
    for label, (path, content) in violations.items():
        expect(workflow, "deletion", f"違反なら失敗: {label}", {**clean_scripts, path: content}, False, must_contain=[path])
    # 検査の対象外（根拠: 実行されない・対象のファイルではない）
    exempt = {
        "コメントの行": ("scripts/c.sh", "#!/usr/bin/env bash\n# rm -rf x は使わない。find -delete も git clean も docker compose down も prune も使わない\necho ok\n"),
        "文書（.md）に書いた説明": ("docs/guide.md", "rm -rf は使わない\n```\nrm -rf x\n```\n"),
        "実行権限のない src のコード": ("src/backend/app/x.rb", "FileUtils.rm_rf('x')\n"),
        "test/ のシェル（テストは拒否の確認のために語を入力に使う）": ("test/pr1/checks/a.sh", ("#!/usr/bin/env bash\nrm -rf x\n", True)),
        "YAML のコメント": (".github/workflows/c.yml", "# docker compose down\non: push\n"),
    }
    for label, (path, content) in exempt.items():
        expect(workflow, "deletion", f"検査の対象外: {label}", {**clean_scripts, path: content}, True)

    # scripts/dc.sh の拒否の一覧だけを除外する（ほかのファイル・ほかの行は除外しない）
    denylist = (
        "#!/usr/bin/env bash\n"
        "readonly DENIED_TOKENS=(\n"
        "  down rm kill prune\n"
        "  --rm --remove-orphans\n"
        ")\n"
        "readonly DENIED_PATTERNS=(\n"
        "  # comment\n"
        "  '(^|[^[:alnum:]_.-])(rm|rmdir|unlink|shred)([^[:alnum:]_./-]|$)'\n"
        "  '(^|[[:space:]])-delete([[:space:]]|$)'\n"
        "  'git[[:space:]]+clean'\n"
        ")\n"
        "check() {\n"
        "  case \"$1\" in\n"
        "    --rm=* | --volumes=*)\n"
        "      echo deny\n"
        "      ;;\n"
        "  esac\n"
        "}\n"
    )
    expect(workflow, "deletion", "scripts/dc.sh の拒否の一覧（DENIED_* の配列と case の見出し）は除外する", {"scripts/dc.sh": denylist}, True)
    expect(workflow, "deletion", "scripts/dc.sh でも、拒否の一覧の外の削除系コマンドは失敗", {"scripts/dc.sh": denylist + "rm -rf tmp\n"}, False, must_contain=["scripts/dc.sh"])
    expect(workflow, "deletion", "scripts/dc.sh でも、配列の外の拒否の語（配列を閉じた後）は失敗", {"scripts/dc.sh": denylist.replace("readonly DENIED_TOKENS=(\n", "x=(\n")}, False, must_contain=["scripts/dc.sh"])
    expect(workflow, "deletion", "ほかのファイルの同じ配列は除外しない", {"scripts/other.sh": denylist}, False, must_contain=["scripts/other.sh"])

    # ---- emoji ----
    expect(workflow, "emoji", "絵文字が無ければ成功（日本語・記号・矢印・著作権表示など）", {"src/ja.ts": "// 日本語のコメント。※ 〜 ～ → ← ↔ ↑ ↓ ★ ☆ ♪ ♭ ♯ © ® ™ ▲ ▼ ◆ ● ○ ◎ ■ □ — … ・ 「」 （） ✓ ✗ ‼ ⁉ ℹ ▶ ◀ ① ② ㈱ 〒 № ℃ ㎏ 1 2 3 # *\nconst a = 1;\n"}, True)
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


def function_checks(workflow):
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
    check(f"F02 emoji: 通常の文章に使う記号（{len(typographic)} 文字: © ® ™ ‼ ⁉ ℹ 矢印 ▶ ◀ ㊗ ㊙ など）は、単独では検出しない", not flagged_typographic, ", ".join(f"{cp:04X}" for cp in flagged_typographic))
    with_selector = [cp for cp in typographic if not find(chr(cp) + "\uFE0F")]
    check("F03 emoji: 上の記号も、異体字選択子（U+FE0F）が付くと検出する", not with_selector, ", ".join(f"{cp:04X}" for cp in with_selector))

    plain_blocks = [
        ("ASCII（キーキャップの基の 0-9・#・* を含む）", 0x0000, 0x007F), ("Latin-1・拡張", 0x0080, 0x024F), ("ギリシャ・キリル", 0x0370, 0x04FF),
        ("一般句読点（‼ ⁉ を含む）", 0x2000, 0x206F), ("矢印", 0x2190, 0x21FF), ("数学記号", 0x2200, 0x22FF), ("囲み英数字", 0x2460, 0x24FF),
        ("罫線・ブロック", 0x2500, 0x259F), ("日本語の約物・CJK 記号", 0x3000, 0x303F), ("ひらがな・カタカナ", 0x3040, 0x30FF),
        ("囲み CJK 文字・月・㌔ など", 0x3200, 0x33FF), ("CJK 統合漢字", 0x4E00, 0x9FFF), ("全角・半角", 0xFF00, 0xFFEF),
    ]
    for label, low, high in plain_blocks:
        found = [cp for cp in range(low, high + 1) if find(chr(cp)) and cp not in should_flag and cp not in (0xFE0F, 0x20E3)]
        check(f"F04 emoji: 通常の文字は検出しない: {label}", not found, ", ".join(f"{cp:04X}" for cp in found[:20]))
    geometric = [cp for cp in range(0x25A0, 0x25FF + 1) if find(chr(cp)) and cp not in (0x25FD, 0x25FE)]
    check("F04 emoji: 幾何学図形（■ □ ▲ ▼ ◆ ● ○ ◎ ▶ ◀）は検出しない（◽ ◾ を除く）", not geometric, ", ".join(f"{cp:04X}" for cp in geometric))
    music = [cp for cp in (0x2605, 0x2606, 0x266A, 0x266D, 0x266F, 0x2713, 0x2717, 0x2610, 0x2612) if find(chr(cp))]
    check("F04 emoji: ★ ☆ ♪ ♭ ♯ ✓ ✗ ☐ ☒ は検出しない", not music, ", ".join(f"{cp:04X}" for cp in music))
    check("F05 emoji: 行番号・桁・文字を返す", find("ab\nc\U0001F680d") == [(2, 2, "\U0001F680")], str(find("ab\nc\U0001F680d")))
    check("F05 emoji: 国旗（地域指示記号 2 つ）・肌の色・キーキャップを検出する", len(find("\U0001F1EF\U0001F1F5")) == 2 and len(find("\U0001F44D\U0001F3FD")) == 2 and len(find("1\uFE0F\u20E3")) == 2)

    deletion = load_step_module(workflow, "deletion")
    if deletion is None:
        return
    compiled = [(label, [re.compile(p) for p in patterns]) for label, patterns in deletion["rules"]()]

    def labels(line):
        return [label for label, patterns in compiled if any(p.search(line) for p in patterns)]

    flagged_lines = [
        "rm -rf x", "  rm x", "cd a && rm b", "a; rm b", "a | xargs rm", "(rm x)", "$(rm x)", "`rm x`", "/bin/rm x", "/usr/bin/rm x", "\\rm x", "sudo rm x", "RUN rm -rf /tmp/x", "CMD [\"rm\", \"-rf\"]",
        "- rm x", "run: rm x", "rmdir x", "unlink x", "shred -u x", "find . -delete", "find . -name a -delete", "rsync --delete a b", "rsync --delete-after a b", "git clean -fd", "git clean", "git rm x", "git branch -d x", "git branch -D x",
        "git branch -df x", "git worktree remove x", "docker rm x", "docker rmi x", "docker compose down", "docker-compose down", "docker compose -f a.yml down -v", "docker compose --profile x down", "docker system prune", "docker image prune -a",
        "docker volume rm x", "docker run --rm img", "docker compose run --rm x", "npm prune", "git remote prune origin", "FileUtils.rm_rf(x)", "FileUtils.rm(x)", "FileUtils.remove_entry(x)", "File.delete(x)", "File.unlink(x)", "Dir.rmdir(x)", "Dir.delete(x)",
        "fs.rmSync(x)", "fs.rm(x)", "fs.unlinkSync(x)", "fs.rmdirSync(x)", "os.RemoveAll(x)", "os.Remove(x)", "os.remove(x)", "os.unlink(x)", "shutil.rmtree(x)", "bin/rails log:clear", "bin/rails tmp:clear", "assets:clobber", "npx rimraf dist",
    ]
    wrongly_passed = [line for line in flagged_lines if not labels(line)]
    check(f"F10 deletion: 削除系の {len(flagged_lines)} 行を検出する", not wrongly_passed, str(wrongly_passed))
    clean_lines = [
        "echo form norm firm perform confirm", "ls rm.md rm_foo rm-foo", "npm run format", "git status", "git branch -a", "git branch -vv", "git branch --list", "git cleanup", "git clean-up", "docker compose up -d --wait",
        "docker logs x", "docker compose logs --tail 100 backend", "echo countdown", "docker compose exec -T backend bundle exec rspec", "bundle exec rspec", "bin/rails db:prepare", "npm ci", "npm audit --omit=dev", "go test -race ./...",
        "timeout --kill-after=30s 5m gofmt -l .", "mkdir -p tmp/x", "mv a DELETE/20261007_a", "cp a b", "find . -name '*.go'", "echo 削除系コマンドは使わない", "--no-delete", "delete-branch: true", "pruned", "deleted", "removed", "File.read(x)", "File.rename(a, b)",
        "Dir.glob(x)", "fs.readFileSync(x)", "os.Getenv(x)", "os.Stat(x)", "process.env.X", "pos.remove", "shutil.copy(a, b)", "log:level", "tmp:dir", "FileUtils.mkdir_p(x)", "FileUtils.cp(a, b)", "arm", "perform",
    ]
    wrongly_flagged = [(line, labels(line)) for line in clean_lines if labels(line)]
    check(f"F11 deletion: 削除系でない {len(clean_lines)} 行は検出しない", not wrongly_flagged, str(wrongly_flagged))


def realistic_checks(workflow):
    """実際のリポジトリ（git archive HEAD）に、まだコミットされていない ci.yml を加えた状態で、3 つの検査が成功すること"""
    base = os.path.join(WORK, "cases", "realistic")
    if os.path.exists(base):
        base = base + f"_{next(COUNTER):04d}"
    os.makedirs(base)
    archive = subprocess.run(["git", "-C", REPO, "archive", "HEAD"], check=True, capture_output=True).stdout
    subprocess.run(["tar", "-x", "-C", base], input=archive, check=True)
    target = os.path.join(base, ".github", "workflows", "ci.yml")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    shutil.copyfile(WORKFLOW_PATH, target)
    subprocess.run(["git", "init", "-q", base], check=True)
    git(base, "add", "-A", "-f")
    tracked = git(base, "ls-files").stdout.decode().count("\n")
    print(f"note: 実際のリポジトリ（HEAD）+ ci.yml の追跡ファイル数 {tracked}")
    for step_id in ("secrets", "deletion", "emoji"):
        result = run_step(workflow, step_id, base)
        report(result.returncode == 0, f"実際のリポジトリ + ci.yml: {step_id} が成功する", f"終了コード {result.returncode}。出力: {(result.stdout + result.stderr)[-1500:]}")
        if result.returncode == 0:
            print("     出力の末尾:", (result.stdout + result.stderr).strip().splitlines()[-1] if (result.stdout + result.stderr).strip() else "（なし）")


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
