/**
 * @jest-environment node
 */
// issue 25 の 5 つのディレクトリ（transport・queue・governor・probe・report）の、本番のコードは、ほかのディレクトリを、その公開の入口（index.ts）からだけ読み込む。
// 深い import（例：../contract/deep-freeze）は、入口が公開していない内部の実装へ依存し、入口の整理で壊れる（PR #44 のレビュー S4）。
// 同じディレクトリの中（./x）は自由。テストは対象にしない（テスト用の道具 ../testing/helpers を読むため）。
import fs from "node:fs";
import path from "node:path";

const CORE_DIRECTORY = path.resolve(__dirname, "..");
const DIRECTORIES = ["transport", "queue", "governor", "probe", "report"] as const;

/** 相対の import / export ... from の指定子（"./x"・"../x/y"）を、すべて返す。 */
function relativeSpecifiers(source: string): string[] {
  const found: string[] = [];
  const pattern = /\bfrom\s+(["'])(\.{1,2}\/[^"']*)\1/g;
  for (let match = pattern.exec(source); match !== null; match = pattern.exec(source)) {
    found.push(match[2]);
  }
  return found;
}

/** 入口（../ディレクトリ名）以外の、ほかのディレクトリへの指定子（深い import・2 階層以上の ../）を返す。 */
function deepImports(source: string): string[] {
  return relativeSpecifiers(source).filter((specifier) => specifier.startsWith("../") && !/^\.\.\/[A-Za-z0-9_-]+$/.test(specifier));
}

function productionSources(directory: string): string[] {
  return fs
    .readdirSync(path.join(CORE_DIRECTORY, directory))
    .filter((name) => name.endsWith(".ts") && !name.endsWith(".test.ts") && !name.endsWith(".d.ts"))
    .sort();
}

describe("deepImports: 検出の道具（空振りしないことの確認）", () => {
  test.each([
    ['import { deepFreeze } from "../contract/deep-freeze";', ["../contract/deep-freeze"]],
    ['import type { BrowserEvent } from "../report/types";', ["../report/types"]],
    ['export * from "../transport/messages";', ["../transport/messages"]],
    ['import { x } from "../../lib/x";', ["../../lib/x"]],
    ["import { x } from '../contract/limits';", ["../contract/limits"]],
    ['import {\n  a,\n  b,\n} from "../contract/enums";', ["../contract/enums"]],
  ])("深い import を見つける：%j", (source, expected) => {
    expect(deepImports(source)).toEqual(expected);
  });

  test.each([
    ['import { LIMITS } from "../contract";'],
    ['import type { ReportBody } from "../transport";'],
    ['import { FrameError } from "./errors";'],
    ['export * from "./frameLayout";'],
    ['import fs from "node:fs";'],
    ["const text = 'from ../contract/deep-freeze';"],
  ])("入口の import・同じディレクトリの import・パッケージは、見つけない：%j", (source) => {
    expect(deepImports(source)).toEqual([]);
  });
});

describe("5 つのディレクトリの本番のコードは、ほかのディレクトリを入口からだけ読み込む", () => {
  test("検査の対象が、空でない（ディレクトリごとに 1 つ以上）", () => {
    for (const directory of DIRECTORIES) {
      expect({ directory, files: productionSources(directory).length > 0 }).toEqual({ directory, files: true });
    }
  });

  test.each(DIRECTORIES)("%s", (directory) => {
    const violations: string[] = [];
    for (const name of productionSources(directory)) {
      const source = fs.readFileSync(path.join(CORE_DIRECTORY, directory, name), "utf8");
      for (const specifier of deepImports(source)) {
        violations.push(`${directory}/${name} -> ${specifier}`);
      }
    }
    expect(violations).toEqual([]);
  });
});
