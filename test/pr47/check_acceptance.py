#!/usr/bin/env python3
"""受け入れ条件と、Go のテストの対応を確かめる（読み取りのみ）。

  使い方: python3 -I check_acceptance.py <go test -json の出力> <acceptance_map.json> <リポジトリのルート>
          python3 -I check_acceptance.py --self-test

確かめること:
  1. acceptance_map.json に列挙したテストが、すべて、go test -json の結果で「成功」であること（失敗・スキップ・実行されていない場合は失敗）
  2. 列挙したテストが、ソース（*_test.go）に実在すること（名前の変更・削除を検知する）
  3. すべての受け入れ条件に、1 つ以上のテストが対応していること
  4. スキップされたテストが、1 つも無いこと（スキップは成功とみなさず、件数を表示する）
  5. ソースにあるテスト関数のうち、どの受け入れ条件にも対応づけていないもの（参考として表示するだけ。失敗にしない）

終了コード: 0 = すべて成功 / 1 = 失敗がある / 2 = 使い方の誤り
"""
import json
import os
import re
import sys

TEST_FUNCTION = re.compile(r"^func ((?:Test|Fuzz)[A-Za-z0-9_]*)\(", re.MULTILINE)


def parse_events(lines):
    """go test -json の出力（JSON 以外の行は読み飛ばす）から、テストごとの最終の結果を返す。
    戻り値: {テスト名: {パッケージ: 'pass'|'fail'|'skip'}}（サブテストは、親のテスト名とは別に、'親/子' で記録する）"""
    results = {}
    for line in lines:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        action, test, package = event.get("Action"), event.get("Test"), event.get("Package", "")
        if not test or action not in ("pass", "fail", "skip"):
            continue
        results.setdefault(test, {})[package] = action
    return results


def declared_tests(root):
    """internal/flv・internal/rtmps の *_test.go にある、Test・Fuzz の関数名。"""
    names = set()
    for package in ("flv", "rtmps"):
        base = os.path.join(root, "src", "relay", "internal", package)
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base)):
            if name.endswith("_test.go"):
                with open(os.path.join(base, name), encoding="utf-8") as handle:
                    names.update(TEST_FUNCTION.findall(handle.read()))
    return names


def evaluate(results, mapping, declared):
    """問題の一覧と、表示用の要約を返す。"""
    problems = []
    skipped = sorted(test for test, per_package in results.items() if "skip" in per_package.values() and "/" not in test)
    for test in skipped:
        problems.append(f"スキップされたテストがあります（成功とみなしません）: {test}")

    mapped = set()
    for criterion in mapping["criteria"]:
        tests = criterion.get("tests", [])
        if not tests:
            problems.append(f"受け入れ条件 {criterion['id']} に、対応するテストがありません")
        for test in tests:
            mapped.add(test)
            if test not in declared:
                problems.append(f"{criterion['id']}: テスト {test} が、ソース（*_test.go）にありません")
            outcome = results.get(test)
            if outcome is None:
                problems.append(f"{criterion['id']}: テスト {test} が、実行されていません")
            elif any(action != "pass" for action in outcome.values()):
                problems.append(f"{criterion['id']}: テスト {test} が成功していません（{outcome}）")

    failed = sorted(test for test, per_package in results.items() if "fail" in per_package.values() and "/" not in test)
    for test in failed:
        problems.append(f"失敗したテストがあります: {test}")

    unmapped = sorted(declared - mapped)
    top_level = [test for test in results if "/" not in test]
    summary = {
        "criteria": len(mapping["criteria"]),
        "mapped_tests": len(mapped),
        "executed_tests": len(top_level),
        "skipped": len(skipped),
        "unmapped": unmapped,
    }
    return problems, summary


def self_test():
    failures = []

    def expect(name, condition):
        if not condition:
            failures.append(name)

    events = [
        '{"Action":"pass","Package":"p","Test":"TestA"}',
        '{"Action":"pass","Package":"p","Test":"TestA/sub"}',
        "== check_gofmt",
        '{"Action":"fail","Package":"p","Test":"TestB"}',
        '{"Action":"skip","Package":"p","Test":"TestC"}',
        '{"Action":"output","Package":"p","Test":"TestD","Output":"x"}',
        '{"Action":"pass","Package":"p"}',
        "not json {",
    ]
    results = parse_events(events)
    expect("JSON 以外の行を読み飛ばす", set(results) == {"TestA", "TestA/sub", "TestB", "TestC"})
    expect("最終の結果を記録", results["TestB"] == {"p": "fail"})

    mapping = {"criteria": [{"id": "c1", "text": "x", "tests": ["TestA"]}]}
    problems, summary = evaluate({"TestA": {"p": "pass"}}, mapping, {"TestA"})
    expect("成功は問題なし", problems == [] and summary["skipped"] == 0)

    problems, _ = evaluate({"TestA": {"p": "fail"}}, mapping, {"TestA"})
    expect("失敗を検出", any("成功していません" in p for p in problems) and any("失敗したテスト" in p for p in problems))

    problems, _ = evaluate({"TestA": {"p": "skip"}}, mapping, {"TestA"})
    expect("スキップを検出", any("スキップ" in p for p in problems))

    problems, _ = evaluate({}, mapping, {"TestA"})
    expect("実行されていないテストを検出", any("実行されていません" in p for p in problems))

    problems, _ = evaluate({"TestA": {"p": "pass"}}, mapping, set())
    expect("ソースに無いテストを検出", any("ソース" in p for p in problems))

    problems, _ = evaluate({"TestA": {"p": "pass"}}, {"criteria": [{"id": "c2", "text": "x", "tests": []}]}, {"TestA"})
    expect("対応するテストの無い受け入れ条件を検出", any("対応するテストがありません" in p for p in problems))

    problems, summary = evaluate({"TestA": {"p": "pass"}, "TestZ": {"p": "pass"}}, mapping, {"TestA", "TestZ"})
    expect("対応づけの無いテストは、失敗にせず、要約へ出す", problems == [] and summary["unmapped"] == ["TestZ"])

    problems, _ = evaluate({"TestA": {"p1": "pass", "p2": "fail"}}, mapping, {"TestA"})
    expect("複数のパッケージの 1 つでも失敗なら検出", any("成功していません" in p for p in problems))

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
    if len(argv) != 4:
        print("使い方: check_acceptance.py <go test -json の出力> <acceptance_map.json> <リポジトリのルート> | --self-test", file=sys.stderr)
        return 2
    json_path, map_path, root = argv[1], argv[2], os.path.abspath(argv[3])
    with open(json_path, encoding="utf-8") as handle:
        results = parse_events(handle)
    with open(map_path, encoding="utf-8") as handle:
        mapping = json.load(handle)
    problems, summary = evaluate(results, mapping, declared_tests(root))
    print(
        f"受け入れ条件 {summary['criteria']} 件・対応づけたテスト {summary['mapped_tests']} 件・"
        f"実行されたテスト関数 {summary['executed_tests']} 件・スキップ {summary['skipped']} 件"
    )
    if summary["unmapped"]:
        print("参考: どの受け入れ条件にも対応づけていないテスト（補助・性質の試験）: " + "、".join(summary["unmapped"]))
    if problems:
        print("問題:")
        for problem in problems:
            print("  - " + problem)
        return 1
    print("問題ありません")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
