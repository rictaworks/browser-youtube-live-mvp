/**
 * @jest-environment node
 */
// 計測データの中身（ws-protocol.md の 3 章：任意のバイト列）。実際の回線は、経路の途中で圧縮されることがある（WebSocket の permessage-deflate など）ので、
// 0 の並びや、同じ内容の繰り返しにしない。決定的な擬似乱数（注入された種から。実時計・Math.random を使わない）で、毎回、違う内容を作る。
import { ProbePayloadGenerator } from "./probePayload";

describe("ProbePayloadGenerator", () => {
  test("指定した長さのバイト列を、毎回、新しい配列で返す", () => {
    const generator = new ProbePayloadGenerator(1);
    const first = generator.next(32_768);
    const second = generator.next(100);
    expect(first).toHaveLength(32_768);
    expect(second).toHaveLength(100);
    expect(first).not.toBe(second);
    first.fill(0);
    expect(generator.next(32_768).some((value) => value !== 0)).toBe(true);
  });

  test("同じ種からは、同じ列（決定的）。違う種からは、違う列", () => {
    const first = new ProbePayloadGenerator(12_345);
    const same = new ProbePayloadGenerator(12_345);
    const other = new ProbePayloadGenerator(54_321);
    for (let round = 0; round < 5; round += 1) {
      const a = first.next(1000);
      expect(Array.from(same.next(1000))).toEqual(Array.from(a));
      expect(Array.from(other.next(1000))).not.toEqual(Array.from(a));
    }
  });

  test("続けて作った内容は、互いに違う（圧縮で小さくならない）。0 の並びでもない", () => {
    const generator = new ProbePayloadGenerator(7);
    const chunks = Array.from({ length: 10 }, () => generator.next(32_768));
    const keys = new Set(chunks.map((chunk) => Buffer.from(chunk.subarray(0, 64)).toString("hex")));
    expect(keys.size).toBe(10);
    for (const chunk of chunks) {
      expect(new Set(chunk).size).toBeGreaterThanOrEqual(250);
    }
  });

  test("バイト値は、ほぼ一様（256 通りの出現が、平均の ±25% の範囲）。偏りがあると、圧縮される", () => {
    const generator = new ProbePayloadGenerator(99);
    const counts = new Array<number>(256).fill(0);
    const total = 256 * 400;
    const bytes = generator.next(total);
    for (const value of bytes) {
      counts[value] += 1;
    }
    for (const count of counts) {
      expect(count).toBeGreaterThan(400 * 0.75);
      expect(count).toBeLessThan(400 * 1.25);
    }
  });

  test("長さ 0 は、空の配列", () => {
    expect(new ProbePayloadGenerator(1).next(0)).toHaveLength(0);
  });

  test.each([
    ["種が 0（擬似乱数が、0 のまま動かなくなる）", 0],
    ["種が負", -1],
    ["種が小数", 1.5],
    ["種が NaN", Number.NaN],
    ["種が 32 ビットに収まらない", 2 ** 32],
  ])("%s は RangeError", (_label, seed) => {
    expect(() => new ProbePayloadGenerator(seed)).toThrow(RangeError);
  });

  test.each([
    ["負", -1],
    ["小数", 1.5],
    ["NaN", Number.NaN],
  ])("長さが %s なら RangeError", (_label, length) => {
    expect(() => new ProbePayloadGenerator(1).next(length)).toThrow(RangeError);
  });
});
