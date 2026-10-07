/**
 * @jest-environment node
 */
// 回線計測の数値を、契約から読み、直書きしないことの検知（CLAUDE.md「設定値の分離」、issue #25）。
//   - 3 秒・最大 6,000 kbps・32 KB・ヘッダ 17 バイト・メッセージの上限は、契約の定数（LIMITS.line_probe・LIMITS.ws_frame）から読む
//   - probePlan.ts・UplinkProbe.ts の数値リテラルは、単位の換算と、実装の仮置き（猶予 5,000 ms・計画の長さの上限・擬似乱数の種）だけ
import fs from "node:fs";
import path from "node:path";
import ts from "typescript";
import { LIMITS } from "../contract";

function numericLiterals(fileName: string): Array<{ readonly value: number; readonly line: number; readonly text: string }> {
  const text = fs.readFileSync(path.join(__dirname, fileName), "utf8");
  const sourceFile = ts.createSourceFile(fileName, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
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

describe("回線計測のソースは、契約の数値を直書きしない", () => {
  // 契約の line_probe・ws_frame の数値
  const contractValues = new Set<number>([
    LIMITS.line_probe.duration_seconds,
    LIMITS.line_probe.max_rate_kbps,
    LIMITS.line_probe.message_bytes_hint,
    LIMITS.ws_frame.header_bytes,
    LIMITS.ws_frame.max_message_bytes,
    LIMITS.relay.ack_interval_ms,
  ]);

  test.each(["probePlan.ts", "UplinkProbe.ts"])("%s の数値リテラルに、契約の値（3・6,000・32,768・17・2,097,152）が現れない", (fileName) => {
    const hardcoded = numericLiterals(fileName).filter((item) => contractValues.has(item.value));
    expect(hardcoded.map((item) => `${fileName}:${item.line} ${item.text}`)).toEqual([]);
  });

  test("probePlan.ts の数値リテラルは、ビット数への換算（8）と、計画の長さの上限（100,000）と、0・1 だけ", () => {
    const allowed = new Set([0, 1, 8, 100_000]);
    expect(numericLiterals("probePlan.ts").filter((item) => !allowed.has(item.value)).map((item) => `${item.line} ${item.text}`)).toEqual([]);
  });

  test("UplinkProbe.ts の数値リテラルは、猶予の既定（5,000）・擬似乱数の種・ミリ秒への換算（1,000）・0 と 1（数え上げ）だけ", () => {
    const allowed = new Set([0, 1, 1000, 5000, 0x9e3779b9]);
    expect(numericLiterals("UplinkProbe.ts").filter((item) => !allowed.has(item.value)).map((item) => `${item.line} ${item.text}`)).toEqual([]);
  });

  test("計測の長さ・最大のレート・メッセージの大きさ・ヘッダの大きさを、契約の定数から読んでいる", () => {
    const source = fs.readFileSync(path.join(__dirname, "UplinkProbe.ts"), "utf8");
    for (const key of ["duration_seconds", "max_rate_kbps", "message_bytes_hint"]) {
      expect(source).toContain(`LIMITS.line_probe.${key}`);
    }
    expect(source).toContain("LIMITS.ws_frame.header_bytes");
  });
});
