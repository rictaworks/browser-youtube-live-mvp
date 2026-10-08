#!/usr/bin/env python3
"""PR #53 の確認: TestProvisioningDoesNotBlockTheSession が、状態報告を取り込み終えてから時計を進めること。

試験のソースを読み、関数の中で「conn.report(」の後、最初の「h.clock.Advance(」の前に「h.barrierAll()」があることを確かめる。
あわせて、検査器自身の自己検査（順序を崩した合成のソースを、失敗として検出できること）を行う。
使い方: python3 check_barrier_before_advance.py [試験のソースのパス]
終了コード: 0 = 成功 / 1 = 失敗
"""
import pathlib
import re
import sys

FUNCTION = "TestProvisioningDoesNotBlockTheSession"
DEFAULT_PATH = pathlib.Path(__file__).resolve().parents[2] / "src/relay/internal/session/session_flow_test.go"


def function_body(source: str, name: str) -> str:
    match = re.search(r"^func " + re.escape(name) + r"\(.*?\n\}\n", source, flags=re.S | re.M)
    if match is None:
        raise ValueError("関数 %s が見つかりません" % name)
    return match.group(0)


def barrier_comes_first(body: str) -> bool:
    report = body.find("conn.report(")
    advance = body.find("h.clock.Advance(")
    if report < 0 or advance < 0 or advance < report:
        raise ValueError("conn.report( と h.clock.Advance( の並びを確かめられません")
    return "h.barrierAll()" in body[report:advance]


def self_check() -> list:
    good = "func " + FUNCTION + "(t *testing.T) {\n\tconn.report(x)\n\th.barrierAll()\n\th.clock.Advance(1)\n}\n"
    bad = "func " + FUNCTION + "(t *testing.T) {\n\tconn.report(x)\n\th.clock.Advance(1)\n\th.barrierAll()\n}\n"
    failures = []
    if not barrier_comes_first(function_body(good, FUNCTION)):
        failures.append("順序が正しい合成のソースを、失敗と判定した")
    if barrier_comes_first(function_body(bad, FUNCTION)):
        failures.append("順序を崩した合成のソースを、成功と判定した")
    return failures


def main() -> int:
    path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PATH
    failures = self_check()
    try:
        source = path.read_text(encoding="utf-8")
        if not barrier_comes_first(function_body(source, FUNCTION)):
            failures.append("%s: conn.report( の後、時計を進める前に h.barrierAll() がありません" % path)
    except (OSError, ValueError) as error:
        failures.append(str(error))
    for failure in failures:
        print("FAIL " + failure)
    if failures:
        return 1
    print("成功 %s は、状態報告を取り込み終えてから時計を進めています（自己検査 2 件を含む）" % FUNCTION)
    return 0


if __name__ == "__main__":
    sys.exit(main())
