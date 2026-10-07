/**
 * @jest-environment node
 */
// フレームの構造の数値を、直書きしないことの検知（CLAUDE.md「設定値の分離」、issue #25）。
//   - frameLayout.ts の数値リテラルは、小さい道具の定数（0・1・16（16 進表記の基数）・32（エラーに載せる名前の切り詰め）・64（BigInt の桁））だけ
//   - ヘッダの大きさ・識別子・版・欄の位置・属性のビット・上限・方向・種別の符号は、すべて、契約の定数（LIMITS.ws_frame）から読んでいる
// ソースの構文木を調べる（コメントの数字・文字列の数字は、数えない）。
import fs from "node:fs";
import path from "node:path";
import ts from "typescript";
import { LIMITS } from "../contract";

const SOURCE_PATH = path.join(__dirname, "frameLayout.ts");
const source = fs.readFileSync(SOURCE_PATH, "utf8");

function numericLiterals(text: string): Array<{ readonly value: number; readonly line: number; readonly text: string }> {
  const sourceFile = ts.createSourceFile("frameLayout.ts", text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
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

describe("frameLayout.ts は、フレームの構造の数値を直書きしない", () => {
  const ALLOWED = new Set([0, 1, 16, 32, 64]);

  test("数値リテラルは、小さい道具の定数（0・1・16・32・64）だけ", () => {
    const literals = numericLiterals(source);
    expect(literals.length).toBeGreaterThan(0);
    const unexpected = literals.filter((item) => !ALLOWED.has(item.value)).map((item) => `${path.basename(SOURCE_PATH)}:${item.line} ${item.text}`);
    expect(unexpected).toEqual([]);
  });

  test("契約のフレームの数値（ヘッダ 17・識別子 66 と 76・上限 2,097,152・種別の符号 1 から 7 と 129 から 135）が、数値として、ソースに現れない", () => {
    const contractValues = new Set<number>([
      LIMITS.ws_frame.header_bytes,
      ...LIMITS.ws_frame.magic,
      LIMITS.ws_frame.max_message_bytes,
      ...Object.values(LIMITS.ws_frame.types).map((entry) => entry.code),
      ...Object.values(LIMITS.ws_frame.header_fields).flatMap((field) => [field.offset, field.length]),
    ]);
    const small = new Set([0, 1]);
    const hardcoded = numericLiterals(source).filter((item) => contractValues.has(item.value) && !small.has(item.value));
    expect(hardcoded).toEqual([]);
  });

  test("ヘッダ・識別子・版・欄の位置・属性のビット・上限・方向・種別の表を、契約の定数（LIMITS.ws_frame）から読んでいる", () => {
    for (const key of ["header_bytes", "max_message_bytes", "header_fields", "magic", "version", "keyframe_attribute_bit", "directions", "types"]) {
      expect(source).toContain(`LIMITS.ws_frame.${key}`);
    }
    for (const field of Object.keys(LIMITS.ws_frame.header_fields)) {
      expect(source).toContain(`FIELDS.${field}.offset`);
    }
  });
});
