/**
 * @jest-environment node
 */
// ワイプ（requirements.md 11.4）：出力枠の右下。幅 = 出力幅の 22%、外側の余白 = 出力幅の 2.5%、角の丸め = ワイプ幅の 6%。
// 絶対値を使わず、出力の大きさ（720p・480p）に対する比で決める。整数への丸めは四捨五入（0.5 は切り上げ）で、はみ出さない。
import { LIMITS } from "../contract";
import { Problems, seededRandom } from "../testing/helpers";
import { wipeRect } from "./wipeRect";

const OUTPUTS = [
  { name: "720p", width: LIMITS.profiles["720p"].width, height: LIMITS.profiles["720p"].height },
  { name: "480p", width: LIMITS.profiles["480p"].width, height: LIMITS.profiles["480p"].height },
] as const;

describe("wipeRect: 表のケース", () => {
  test.each([
    ["720p・16:9", 1280, 720, 16 / 9, { x: 966, y: 529, width: 282, height: 159, cornerRadius: 17 }],
    ["720p・4:3", 1280, 720, 4 / 3, { x: 966, y: 476, width: 282, height: 212, cornerRadius: 17 }],
    ["720p・1:1", 1280, 720, 1, { x: 966, y: 406, width: 282, height: 282, cornerRadius: 17 }],
    ["720p・縦長 9:16（スマートフォンのカメラ）", 1280, 720, 9 / 16, { x: 966, y: 187, width: 282, height: 501, cornerRadius: 17 }],
    ["720p・超横長 21:9", 1280, 720, 21 / 9, { x: 966, y: 567, width: 282, height: 121, cornerRadius: 17 }],
    ["480p・16:9", 854, 480, 16 / 9, { x: 645, y: 353, width: 188, height: 106, cornerRadius: 11 }],
    ["480p・4:3", 854, 480, 4 / 3, { x: 645, y: 318, width: 188, height: 141, cornerRadius: 11 }],
    ["480p・1:1", 854, 480, 1, { x: 645, y: 271, width: 188, height: 188, cornerRadius: 11 }],
    ["480p・縦長 9:16", 854, 480, 9 / 16, { x: 645, y: 125, width: 188, height: 334, cornerRadius: 11 }],
    ["480p・超横長 21:9", 854, 480, 21 / 9, { x: 645, y: 378, width: 188, height: 81, cornerRadius: 11 }],
  ])("%s", (_label, outWidth, outHeight, aspect, expected) => {
    expect(wipeRect(outWidth, outHeight, aspect)).toEqual(expected);
  });

  test("丸めの規則：720p の幅 281.6 -> 282、余白 32.0 -> 32、角 16.92 -> 17。480p の幅 187.88 -> 188、余白 21.35 -> 21、角 11.28 -> 11", () => {
    expect(wipeRect(1280, 720, 16 / 9)).toMatchObject({ width: 282, cornerRadius: 17 });
    expect(wipeRect(854, 480, 16 / 9)).toMatchObject({ width: 188, cornerRadius: 11 });
    // 余白は、右の余白 = 出力幅 - (x + 幅)、下の余白 = 出力高 - (y + 高さ)
    const wide = wipeRect(1280, 720, 16 / 9);
    expect(1280 - (wide.x + wide.width)).toBe(32);
    expect(720 - (wide.y + wide.height)).toBe(32);
    const light = wipeRect(854, 480, 16 / 9);
    expect(854 - (light.x + light.width)).toBe(21);
    expect(480 - (light.y + light.height)).toBe(21);
  });
});

describe("wipeRect: 比の検査（絶対値を使わない。720p・480p の両方）", () => {
  test.each(OUTPUTS)("$name：幅 = 出力幅の 22%、外側の余白 = 出力幅の 2.5%（右・下とも）、角の丸め = ワイプ幅の 6%（いずれも丸め 0.5 画素以内）", ({ width, height }) => {
    const aspects = [16 / 9, 4 / 3, 1, 3 / 2, 9 / 16, 21 / 9];
    const problems = new Problems();
    for (const aspect of aspects) {
      const rect = wipeRect(width, height, aspect);
      const label = `${width}x${height} aspect ${aspect}: ${JSON.stringify(rect)}`;
      if (Math.abs(rect.width - 0.22 * width) > 0.5) {
        problems.report(`width is not 22% of the output width ${label}`);
      }
      if (Math.abs(width - (rect.x + rect.width) - 0.025 * width) > 0.5) {
        problems.report(`right margin is not 2.5% of the output width ${label}`);
      }
      if (Math.abs(height - (rect.y + rect.height) - 0.025 * width) > 0.5) {
        problems.report(`bottom margin is not 2.5% of the output width ${label}`);
      }
      if (Math.abs(rect.cornerRadius - 0.06 * rect.width) > 0.5) {
        problems.report(`corner radius is not 6% of the wipe width ${label}`);
      }
      if (Math.abs(rect.height - rect.width / aspect) > 0.5 + 1e-9) {
        problems.report(`the wipe does not keep the camera aspect ratio ${label}`);
      }
    }
    expect(problems.list()).toEqual([]);
  });

  test("720p と 480p で、比が同じになる（幅の比は 22%、余白は 2.5%。絶対値の定数が無い）", () => {
    const large = wipeRect(1280, 720, 16 / 9);
    const small = wipeRect(854, 480, 16 / 9);
    expect(large.width / 1280).toBeCloseTo(small.width / 854, 2);
    expect((1280 - large.x - large.width) / 1280).toBeCloseTo((854 - small.x - small.width) / 854, 2);
    expect(large.cornerRadius / large.width).toBeCloseTo(small.cornerRadius / small.width, 1);
  });

  test("任意の出力の大きさでも、比が保たれる（出力幅 200〜4,000・高さは幅の 0.5〜0.8 倍・縦横比 0.5〜2.5・疑似乱数。高さで制限されない範囲）", () => {
    const random = seededRandom(11);
    const problems = new Problems();
    for (let i = 0; i < 5_000; i += 1) {
      const outWidth = 200 + Math.floor(random() * 3_800);
      const outHeight = Math.floor(outWidth * (0.5 + random() * 0.3));
      const aspect = 0.5 + random() * 2;
      const rect = wipeRect(outWidth, outHeight, aspect);
      const label = `${outWidth}x${outHeight} aspect ${aspect}: ${JSON.stringify(rect)}`;
      if (Math.abs(rect.width - 0.22 * outWidth) > 0.5) {
        problems.report(`width ratio ${label}`);
      }
      if (Math.abs(outWidth - (rect.x + rect.width) - 0.025 * outWidth) > 0.5) {
        problems.report(`margin ratio ${label}`);
      }
      if (Math.abs(rect.cornerRadius - 0.06 * rect.width) > 0.5) {
        problems.report(`corner radius ratio ${label}`);
      }
    }
    expect(problems.list()).toEqual([]);
  });
});

describe("wipeRect: はみ出さない（右下に配置・外側の余白を保つ）", () => {
  test("どの縦横比でも、整数で、出力の内側（上・左も外側の余白の分だけ内側）に収まる（疑似乱数 20,000 組）", () => {
    const random = seededRandom(22);
    const problems = new Problems();
    for (let i = 0; i < 20_000; i += 1) {
      const outWidth = 160 + Math.floor(random() * 3_840);
      const outHeight = 90 + Math.floor(random() * 2_160);
      const aspect = 10 ** (random() * 4 - 2); // 0.01 から 100
      let rect;
      try {
        rect = wipeRect(outWidth, outHeight, aspect);
      } catch (error) {
        // 出力が低すぎて、余白を取るとワイプの置き場が無い場合だけ、RangeError になる
        const margin = Math.floor((outWidth * 25 + 500) / 1000);
        if (!(error instanceof RangeError) || outHeight - 2 * margin >= 1) {
          problems.report(`unexpected error for ${outWidth}x${outHeight} aspect ${aspect}`);
        }
        continue;
      }
      const margin = Math.floor((outWidth * 25 + 500) / 1000);
      const label = `${outWidth}x${outHeight} aspect ${aspect}: ${JSON.stringify(rect)}`;
      if (![rect.x, rect.y, rect.width, rect.height, rect.cornerRadius].every(Number.isInteger)) {
        problems.report(`not integers ${label}`);
      }
      if (rect.width < 1 || rect.height < 1) {
        problems.report(`empty ${label}`);
      }
      if (rect.x + rect.width !== outWidth - margin || rect.y + rect.height !== outHeight - margin) {
        problems.report(`not anchored to the bottom right with the outer margin ${label}`);
      }
      if (rect.x < margin || rect.y < margin) {
        problems.report(`overflows the margin on the left or top ${label}`);
      }
      if (rect.cornerRadius < 0 || rect.cornerRadius * 2 > Math.min(rect.width, rect.height)) {
        problems.report(`corner radius exceeds half of the shorter side ${label}`);
      }
    }
    expect(problems.list()).toEqual([]);
  });

  test.each([
    ["720p・極端に縦長（0.1）：高さを上下の余白の間に収め、幅を縮めて縦横比を保つ", 1280, 720, 0.1, { x: 1182, y: 32, width: 66, height: 656, cornerRadius: 4 }],
    ["480p・極端に縦長（0.1）", 854, 480, 0.1, { x: 789, y: 21, width: 44, height: 438, cornerRadius: 3 }],
    ["720p・極端に横長（10）：角の丸めは、短い辺の半分を超えない（17 -> 14）", 1280, 720, 10, { x: 966, y: 660, width: 282, height: 28, cornerRadius: 14 }],
    ["720p・極端に横長（1000）：高さは 1 画素を下回らない", 1280, 720, 1000, { x: 966, y: 687, width: 282, height: 1, cornerRadius: 0 }],
  ])("%s", (_label, outWidth, outHeight, aspect, expected) => {
    expect(wipeRect(outWidth, outHeight, aspect)).toEqual(expected);
  });
});

describe("wipeRect: 不正な入力（フォールバックせず RangeError）", () => {
  test.each([
    ["出力の幅が 0", [0, 720, 1.5]],
    ["出力の高さが 0", [1280, 0, 1.5]],
    ["出力が小数", [1280.5, 720, 1.5]],
    ["縦横比が 0", [1280, 720, 0]],
    ["縦横比が負", [1280, 720, -1.5]],
    ["縦横比が NaN", [1280, 720, Number.NaN]],
    ["縦横比が無限大", [1280, 720, Number.POSITIVE_INFINITY]],
    ["出力が低すぎて、外側の余白を取るとワイプの置き場が無い（1000x10）", [1000, 10, 1.5]],
  ])("%s", (_label, args) => {
    const [outWidth, outHeight, aspect] = args as [number, number, number];
    expect(() => wipeRect(outWidth, outHeight, aspect)).toThrow(RangeError);
  });

  test("結果は変更できない（凍結されている）", () => {
    expect(Object.isFrozen(wipeRect(1280, 720, 16 / 9))).toBe(true);
  });
});
