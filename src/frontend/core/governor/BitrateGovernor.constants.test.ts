/**
 * @jest-environment node
 */
// 適応制御の数値を、直書きしないことの検知（CLAUDE.md「文字列リテラル・設定値の分離」、issue #25「12 章の数値は limits.json と一致させる」）。
//   - BitrateGovernor.ts の数値リテラルは、単位の換算（0・1・100・1,000・1,000,000）だけ
//   - 12 章の表の数値（契約 LIMITS.adaptive.conditions の、7 条件 x 項目）は、すべて、契約の定数から読んでいる
// ソースの構文木を調べる（コメントの数字・文字列の数字は、数えない）。
import fs from "node:fs";
import path from "node:path";
import ts from "typescript";
import { LIMITS } from "../contract";

const SOURCE_PATH = path.join(__dirname, "BitrateGovernor.ts");
const source = fs.readFileSync(SOURCE_PATH, "utf8");

/** ソースの数値リテラル（数値区切りの _ を除いた値）を、行番号つきで返す。 */
function numericLiterals(text: string): Array<{ readonly value: number; readonly line: number; readonly text: string }> {
  const sourceFile = ts.createSourceFile("BitrateGovernor.ts", text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const found: Array<{ value: number; line: number; text: string }> = [];
  const visit = (node: ts.Node): void => {
    if (ts.isNumericLiteral(node)) {
      found.push({ value: Number(node.text.replace(/_/g, "")), line: sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile)).line + 1, text: node.text });
    }
    ts.forEachChild(node, visit);
  };
  visit(sourceFile);
  return found;
}

describe("数値リテラルの検知（走査の道具の自己検査）", () => {
  test("コメント・文字列の数字は数えず、コードの数値リテラルだけを数える。区切りの _ を除く", () => {
    const found = numericLiterals("// 1500 ms\nconst a = '4000'; const b = 1_000_000; const c = 8000.5; /* 300 */");
    expect(found.map((item) => item.value)).toEqual([1_000_000, 8000.5]);
  });
});

describe("BitrateGovernor.ts は、12 章の数値を直書きしない", () => {
  const ALLOWED = new Set([0, 1, 100, 1000, 1_000_000]);

  test("数値リテラルは、単位の換算（0・1・100（パーセント）・1,000（ミリ秒とマイクロ秒）・1,000,000（秒とマイクロ秒））だけ", () => {
    const literals = numericLiterals(source);
    expect(literals.length).toBeGreaterThan(0);
    const unexpected = literals.filter((item) => !ALLOWED.has(item.value)).map((item) => `${path.basename(SOURCE_PATH)}:${item.line} ${item.text}`);
    expect(unexpected).toEqual([]);
  });

  test("12 章の閾値・継続時間・割合（契約の値）が、数値として、ソースに現れない（直書きされていない）", () => {
    const contractValues = new Set<number>();
    for (const condition of Object.values(LIMITS.adaptive.conditions)) {
      for (const value of Object.values(condition)) {
        contractValues.add(value);
      }
    }
    contractValues.add(LIMITS.adaptive.evaluation_interval_ms);
    contractValues.add(LIMITS.adaptive.target_change_min_interval_ms);
    // 1 と 100 と 1,000 は単位の換算なので、契約の値と重なっても許す（契約の値と同じ数値を、閾値として使っていないことは、上の検査と、下の参照の検査で確かめる）
    const unitValues = new Set([0, 1, 100, 1000, 1_000_000]);
    const hardcoded = numericLiterals(source).filter((item) => contractValues.has(item.value) && !unitValues.has(item.value));
    expect(hardcoded).toEqual([]);
  });

  test("7 条件の、すべての項目を、契約の定数（LIMITS.adaptive.conditions）から読んでいる", () => {
    const missing: string[] = [];
    for (const [condition, items] of Object.entries(LIMITS.adaptive.conditions)) {
      for (const key of Object.keys(items)) {
        if (!source.includes(`CONDITIONS.${condition}.${key}`)) {
          missing.push(`${condition}.${key}`);
        }
      }
    }
    expect(missing).toEqual([]);
    expect(source).toContain("LIMITS.adaptive.target_change_min_interval_ms");
  });

  test("契約の条件の項目は、12 章の表の 7 条件 x 14 項目（読み漏れを検知する範囲が、空振りでない）", () => {
    const keys = Object.entries(LIMITS.adaptive.conditions).flatMap(([condition, items]) => Object.keys(items).map((key) => `${condition}.${key}`));
    expect(keys).toHaveLength(14);
    expect(Object.keys(LIMITS.adaptive.conditions)).toHaveLength(7);
  });
});
