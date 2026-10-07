#!/usr/bin/env python3
"""変異テスト: ci.yml を 1 か所ずつ壊し、check_ci.py が、必ず失敗（FAIL）を報告することを確かめる。

  python3 -I mutate_ci.py <リポジトリのルート> <作業ディレクトリ>

壊した ci.yml は <作業ディレクトリ>/mutants/ に置く（元の ci.yml は変更しない。ファイルは削除しない）。
check_ci.py が FAIL の行を出さずに異常終了した場合（例外など）は、検出とみなさず、見逃しとして数える（原因を確かめるため）。

このソースには、削除系コマンドの語を書かない（CLAUDE.md。CI の hygiene が、このファイル自身を検査する）。
"""

import os
import re
import subprocess
import sys

REPO = os.path.abspath(sys.argv[1])
WORK = os.path.abspath(sys.argv[2])
HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(REPO, ".github", "workflows", "ci.yml")


def replace_first(text, old, new):
    if old not in text:
        raise SystemExit(f"変異の対象が見つかりません: {old!r}")
    return text.replace(old, new, 1)


def replace_all(text, old, new):
    if old not in text:
        raise SystemExit(f"変異の対象が見つかりません: {old!r}")
    return text.replace(old, new)


def mutations():
    return {
        "permissions を広げる": lambda t: replace_first(t, "permissions:\n  contents: read\n", "permissions: write-all\n"),
        "action を main で指定": lambda t: replace_first(t, "actions/checkout@v7", "actions/checkout@main"),
        "action の版を固定しない（無指定）": lambda t: replace_first(t, "actions/setup-go@v7", "actions/setup-go"),
        "job の timeout-minutes を外す": lambda t: replace_first(t, "    timeout-minutes: 20\n", ""),
        "RuboCop の timeout を外す": lambda t: replace_first(t, 'timeout --kill-after=30s "$TIMEOUT_SHORT" bin/rubocop', "bin/rubocop"),
        "timeout を --kill-after なしにする": lambda t: replace_first(t, 'timeout --kill-after=30s "$TIMEOUT_LONG" bundle exec rspec', 'timeout "$TIMEOUT_LONG" bundle exec rspec'),
        "PostgreSQL を 16 にする": lambda t: replace_first(t, "image: postgres:17", "image: postgres:16"),
        "DATABASE_URL を開発 DB にする": lambda t: replace_first(t, "localhost:5432/bl_test\n", "localhost:5432/bl_development\n"),
        "RAILS_ENV を外す": lambda t: replace_first(t, "      RAILS_ENV: test\n", ""),
        "runs-on を ubuntu-latest にする": lambda t: replace_all(t, "runs-on: ubuntu-24.04", "runs-on: ubuntu-latest"),
        "cancel-in-progress を外す": lambda t: replace_first(t, "  cancel-in-progress: ${{ github.event_name == 'pull_request' }}\n", ""),
        "push の対象ブランチを変える": lambda t: replace_first(t, "    branches:\n      - main\n", "    branches:\n      - develop\n"),
        "リリースの action を足す": lambda t: replace_first(t, "      - name: 機密ファイルが追跡されていないこと\n", "      - name: リリース\n        uses: softprops/action-gh-release@v2\n\n      - name: 機密ファイルが追跡されていないこと\n"),
        "secrets を参照する": lambda t: replace_first(t, "          POSTGRES_DB: bl_test\n", "          POSTGRES_DB: bl_test\n          X: ${{ secrets.TOKEN }}\n"),
        "persist-credentials を外す": lambda t: replace_first(t, "          persist-credentials: false\n", ""),
        "step の name を外す": lambda t: replace_first(t, "      - name: RSpec\n        if:", "      - if:"),
        "ruby の id を外す": lambda t: replace_first(t, "        id: ruby\n", ""),
        "RSpec を RuboCop の前に移す（順序）": lambda t: replace_first(t, "bin/rubocop", "bundle exec rspec # moved"),
        "-race を外す": lambda t: replace_first(t, "go test -race -count=1 ./...", "go test -count=1 ./..."),
        "npm audit を外す": lambda t: replace_first(t, '"$TIMEOUT_SHORT" npm audit --omit=dev', '"$TIMEOUT_SHORT" npm ls --omit=dev'),
        "npm audit から --omit=dev を外す（開発依存の指摘で赤くなる）": lambda t: replace_first(t, '"$TIMEOUT_SHORT" npm audit --omit=dev', '"$TIMEOUT_SHORT" npm audit'),
        "hygiene の if を外す": lambda t: replace_first(t, "        id: emoji\n        if: ${{ !cancelled() }}\n", "        id: emoji\n"),
        "絵文字の範囲から astral を外す": lambda t: replace_first(t, "                  1F000-1FAFF\n", ""),
        "絵文字の範囲から FE0F を外す": lambda t: replace_first(t, "                  FE0F 20E3 E0020-E007F\n", "                  20E3 E0020-E007F\n"),
        "node_modules の除外を外す": lambda t: replace_first(t, '{"node_modules", "vendor", ".cache", ".next"}', '{"vendor", ".cache", ".next"}'),
        "削除系の語の規則を 1 つ外す（一括削除）": lambda t: re.sub(r'\n\s*\("不要な資源の一括削除".*\n', "\n", t, count=1),
        "削除系: 実行権限のファイルを対象から外す": lambda t: replace_first(t, '                  or mode == "100755"\n', ""),
        "削除系: test/ 全体を、検査から外す（許可リストの前の方式に戻す）": lambda t: replace_first(t, '              name = path.rsplit("/", 1)[-1]\n              return (\n', '              if path.startswith("test/"):\n                  return False\n              name = path.rsplit("/", 1)[-1]\n              return (\n'),
        "削除系: 許可リストを、test/ 全体への前方一致にする": lambda t: replace_first(t, "                  if path in allowed:\n", '                  if path.startswith("test/"):\n'),
        "削除系: 許可リストを使わない（許可したファイルも検査する）": lambda t: replace_first(t, "                  if path in allowed:\n", "                  if False:\n"),
        "削除系: 許可リストへ test/pr34 のファイルを足す": lambda t: replace_first(t, '                  "test/pr33/lib/deletion_scan.sh":', '                  "test/pr34/check_x.sh": "x",\n                  "test/pr33/lib/deletion_scan.sh":'),
        "削除系: 許可リストから common.sh を外す": lambda t: re.sub(r'\n\s*"test/pr33/lib/common.sh": .*\n', "\n", t, count=1),
        "削除系: 許可したファイルを、ログに出さない": lambda t: replace_first(t, "              if skipped_files:\n", "              if False:\n"),
        "削除系: dc.sh の除外を、すべてのファイルへ広げる": lambda t: replace_first(t, 'if path == "scripts/dc.sh":', "if True:"),
        "削除系: コメントの行を除外しない": lambda t: replace_first(t, 'if re.match(r"\\s*#", line):', "if False:"),
        "削除系: ::error:: のパスをエスケープしない": lambda t: replace_first(t, "）: {escape_data(path)}:{number}", "）: {path}:{number}"),
        "絵文字: ::error:: のパスをエスケープしない": lambda t: replace_first(t, "絵文字があります: {escape_data(path)}", "絵文字があります: {path}"),
        "絵文字: UTF-8 のエラーのパスをエスケープしない": lambda t: replace_first(t, "判定できません: {escape_data(path)}", "判定できません: {path}"),
        "機密: *.pem を許す": lambda t: replace_first(t, 'name.endswith((".pem", ".key"))', 'name.endswith((".key",))'),
        "機密: .env.example 以外の .env.* も許す": lambda t: replace_first(t, 'name.startswith(".env.") or ', ""),
        "機密: 大文字小文字を区別する": lambda t: replace_first(t, 'name = path.rsplit("/", 1)[-1].lower()', 'name = path.rsplit("/", 1)[-1]'),
        "機密: ::error:: のパスをエスケープしない": lambda t: replace_first(t, "追跡されています: {escape_data(path)}", "追跡されています: {path}"),
        "go.mod の版を使わない": lambda t: replace_first(t, "go-version-file: src/relay/go.mod", "go-version: '1.26'"),
        "bundler-cache を外す": lambda t: replace_first(t, "          bundler-cache: true\n", ""),
        "typecheck を外す（npm run typecheck）": lambda t: replace_first(t, "npm run typecheck", "echo skip"),
        "Jest の --ci を外す": lambda t: replace_first(t, "npm test -- --ci", "npm test"),
    }


def main():
    with open(SOURCE, encoding="utf-8") as handle:
        original = handle.read()
    out_dir = os.path.join(WORK, "mutants")
    os.makedirs(out_dir, exist_ok=True)
    survivors = []
    for index, (name, mutate) in enumerate(mutations().items(), 1):
        mutant = mutate(original)
        if mutant == original:
            raise SystemExit(f"変異で内容が変わりません: {name}")
        path = os.path.join(out_dir, f"m{index:02d}.yml")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(mutant)
        env = dict(os.environ, CI_YML=path)
        result = subprocess.run(
            [sys.executable, "-I", os.path.join(HERE, "check_ci.py"), REPO, os.path.join(WORK, f"run_m{index:02d}")],
            env=env, capture_output=True, text=True, timeout=300,
        )
        fails = [line for line in result.stdout.splitlines() if line.startswith("FAIL")]
        if fails:
            print(f"検出  m{index:02d} {name}  ({len(fails)} 件失敗: {fails[0][:90]})")
            continue
        status = "異常終了（FAIL の行なし。要確認）" if result.returncode != 0 else "見逃し"
        print(f"{status}  m{index:02d} {name}  (終了コード {result.returncode}。標準エラーの末尾: {result.stderr.strip()[-200:]})")
        survivors.append(name)
    print(f"\n変異 {len(mutations())} 件のうち、見逃し・異常終了 {len(survivors)} 件" + (": " + ", ".join(survivors) if survivors else ""))
    return 1 if survivors else 0


if __name__ == "__main__":
    sys.exit(main())
