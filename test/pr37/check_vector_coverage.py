#!/usr/bin/env python3
"""共有ベクタ（src/contracts/ws-frame-vectors.json）の全件が、Go のテストで、1 件ずつ実行され、成功したことを確かめる（読み取りのみ）。

使い方: python3 -I check_vector_coverage.py <ws-frame-vectors.json> <go test -v の出力ファイル>

go test -v の出力から、サブテストの成功の行（--- PASS: <テスト名>/<ベクタの名前>）を集め、JSON の全ベクタについて、
  - 有効なフレーム：復号（TestSharedVectorsValid）と符号化（TestEncodeMatchesSharedVectors）の 2 つ
  - 無効なフレーム：拒否（TestSharedVectorsInvalid）
が、成功の行として存在することを確かめる。失敗・スキップの行があれば、失敗にする。
黙って一部のベクタをスキップした実装・ベクタを見つけられずに空振りしたテストを、見逃さないための検査。
"""
import json
import re
import sys

VALID_DECODE = "TestSharedVectorsValid"
VALID_ENCODE = "TestEncodeMatchesSharedVectors"
INVALID_DECODE = "TestSharedVectorsInvalid"

if len(sys.argv) != 3:
    print("使い方: check_vector_coverage.py <ws-frame-vectors.json> <go test -v の出力>")
    sys.exit(2)

with open(sys.argv[1], encoding="utf-8") as handle:
    vectors = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    output = handle.read().split("\n")

problems = []
valid_names = [item["name"] for item in vectors["valid"]]
invalid_names = [item["name"] for item in vectors["invalid"]]
for label, names in (("valid", valid_names), ("invalid", invalid_names)):
    if len(names) != len(set(names)):
        problems.append(f"{label} のベクタの名前が重複しています（サブテストの名前が一意でなくなります）")

passed = set()
failed = []
skipped = []
for line in output:
    match = re.match(r"^\s*--- (PASS|FAIL|SKIP): (\S+)", line)
    if not match:
        continue
    status, name = match.groups()
    if status == "PASS":
        passed.add(name)
    elif status == "FAIL":
        failed.append(name)
    else:
        skipped.append(name)

for name in failed:
    problems.append(f"失敗したテスト: {name}")
for name in skipped:
    problems.append(f"スキップされたテスト: {name}（黙ってスキップしてはいけません）")

expected = 0
for name in valid_names:
    for test in (VALID_DECODE, VALID_ENCODE):
        expected += 1
        if f"{test}/{name}" not in passed:
            problems.append(f"成功の行がありません: {test}/{name}")
for name in invalid_names:
    expected += 1
    if f"{INVALID_DECODE}/{name}" not in passed:
        problems.append(f"成功の行がありません: {INVALID_DECODE}/{name}")

print(f"ベクタ: 有効 {len(valid_names)} 件・無効 {len(invalid_names)} 件。確かめた成功の行: {expected} 件")
if problems:
    print("問題:")
    for item in problems:
        print("  - " + item)
    sys.exit(1)
print("問題ありません（共有ベクタの全件が、1 件ずつ成功しています）")
