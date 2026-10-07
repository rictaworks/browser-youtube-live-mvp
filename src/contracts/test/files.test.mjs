// 契約のファイルの存在・JSON の構文・契約のディレクトリの探し方。
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { describe, test } from "node:test";

import {
  ContractsNotFoundError,
  MARKER_FILE,
  candidateDirs,
  locateContractsDir,
  parseStrictJson,
  readContractFile,
} from "./helpers.mjs";

const JSON_FILES = ["enums.json", "limits.json", "http-rejections.json", "ws-frame-vectors.json"];
const DOCUMENT_FILES = ["README.md", "http-api.md", "internal-api.md", "ws-protocol.md"];

describe("契約のディレクトリの探し方", () => {
  test("候補は /contracts・../contracts・../../contracts・テストの隣の順（同じ場所は 1 つにまとめる）", () => {
    assert.deepEqual(candidateDirs({ cwd: "/work/src/backend", testDir: "/work/src/contracts/test" }), [
      "/contracts",
      "/work/src/contracts",
      "/work/contracts",
    ]);
    // コンテナの中（作業ディレクトリが /app）では、すべて /contracts になる
    assert.deepEqual(candidateDirs({ cwd: "/app", testDir: "/contracts/test" }), ["/contracts"]);
  });

  test("相対の候補は、作業ディレクトリが src/<層> のとき、CI のチェックアウトの src/contracts を指す", () => {
    const candidates = candidateDirs({ cwd: "/repo/src/frontend", testDir: "/elsewhere/test" });
    assert.ok(candidates.includes("/repo/src/contracts"));
  });

  test("最初に見つかった候補を返す", () => {
    const found = locateContractsDir({
      candidates: ["/a", "/b", "/c"],
      hasMarkerFile: (dir) => dir === "/b" || dir === "/c",
    });
    assert.equal(found, "/b");
  });

  test("1 つも無ければ、探した場所をすべて並べて失敗する（黙ってスキップしない）", () => {
    const candidates = ["/contracts", "/x/contracts", "/contracts-missing"];
    assert.throws(
      () => locateContractsDir({ candidates, hasMarkerFile: () => false }),
      (error) => {
        assert.ok(error instanceof ContractsNotFoundError);
        for (const dir of candidates) {
          assert.ok(error.message.includes(dir), `メッセージに ${dir} が無い: ${error.message}`);
        }
        assert.ok(error.message.includes(MARKER_FILE));
        assert.ok(error.message.includes("スキップせず"));
        return true;
      },
    );
  });

  test("実際の環境で、契約のディレクトリが見つかる", () => {
    const dir = locateContractsDir();
    assert.ok(fs.statSync(dir).isDirectory());
    assert.ok(fs.existsSync(path.join(dir, MARKER_FILE)));
  });
});

describe("厳密な JSON の読み込み", () => {
  const valid = [
    ['{"a":1,"b":[true,false,null,"x"],"c":{"d":-1.5e2}}', { a: 1, b: [true, false, null, "x"], c: { d: -150 } }],
    ["  [ ]  ", []],
    ['"日本語\\u3042"', "日本語あ"],
  ];
  for (const [text, expected] of valid) {
    test(`読める: ${text}`, () => {
      assert.deepEqual(parseStrictJson(text), expected);
    });
  }

  const invalid = [
    ["キーの重複", '{"a":1,"a":2}'],
    ["入れ子のキーの重複", '{"x":{"a":1,"b":2,"a":3}}'],
    ["末尾のカンマ（オブジェクト）", '{"a":1,}'],
    ["末尾のカンマ（配列）", "[1,]"],
    ["先頭の 0 の数値", "[01]"],
    ["シングルクォート", "{'a':1}"],
    ["コメント", '{"a":1} // x'],
    ["値の後の余分な文字", "{} x"],
    ["閉じていない", '{"a":[1,2}'],
    ["制御文字を含む文字列", '"a\nb"'],
    ["BOM", '﻿{"a":1}'],
    ["空", ""],
  ];
  for (const [label, text] of invalid) {
    test(`拒否する: ${label}`, () => {
      assert.throws(() => parseStrictJson(text, "テスト"), SyntaxError);
    });
  }

  test("__proto__ のキーでも、プロトタイプを書き換えない", () => {
    const parsed = parseStrictJson('{"__proto__":{"polluted":true}}');
    assert.equal(Object.getPrototypeOf(parsed), Object.prototype);
    assert.equal(parsed.polluted, undefined);
    assert.deepEqual(Object.keys(parsed), ["__proto__"]);
  });
});

describe("契約のファイル", () => {
  const dir = locateContractsDir();

  for (const name of [...DOCUMENT_FILES, ...JSON_FILES]) {
    test(`${name} がある`, () => {
      const stat = fs.statSync(path.join(dir, name));
      assert.ok(stat.isFile(), `${name} がファイルではありません`);
      assert.ok(stat.size > 0, `${name} が空です`);
    });
  }

  for (const name of JSON_FILES) {
    test(`${name} は、キーの重複の無い JSON のオブジェクト`, () => {
      const parsed = parseStrictJson(readContractFile(dir, name), name);
      assert.ok(parsed !== null && typeof parsed === "object" && !Array.isArray(parsed));
    });
  }

  for (const name of [...DOCUMENT_FILES, ...JSON_FILES]) {
    test(`${name} は UTF-8（BOM なし）・改行で終わる・絵文字を含まない`, () => {
      const bytes = fs.readFileSync(path.join(dir, name));
      assert.notDeepEqual([...bytes.subarray(0, 3)], [0xef, 0xbb, 0xbf], "BOM があります");
      const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
      assert.ok(text.endsWith("\n"), "末尾が改行ではありません");
      assert.equal(/\p{Extended_Pictographic}/u.test(text), false, "絵文字があります（CLAUDE.md：絵文字は使用禁止）");
      assert.equal(text.includes("\r"), false, "CR があります（改行は LF）");
    });
  }

  test("契約のディレクトリに、予期しない JSON・文書が増えていない", () => {
    // .gitkeep は、開発環境の整備（#1）が置いた目印（ディレクトリが無いと、docker が root 所有で作ってしまうため）
    const expected = new Set([...DOCUMENT_FILES, ...JSON_FILES, "test", ".gitkeep"]);
    const actual = fs.readdirSync(dir);
    const unexpected = actual.filter((name) => !expected.has(name));
    assert.deepEqual(unexpected, [], "予期しないファイルがあります。意図したものなら、このテストの一覧へ加えてください");
  });
});
