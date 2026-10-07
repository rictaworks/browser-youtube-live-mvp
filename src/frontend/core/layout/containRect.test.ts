/**
 * @jest-environment node
 */
// 主映像の内接（requirements.md 11.4）。縦横比を保ったまま出力枠に内接させる（余白は呼び出し側が単色で埋める）。
// 結果は整数の長方形。丸めは四捨五入（0.5 は切り上げ）、余白は左・上が小さく（切り捨て）、右・下が大きくなる。
import { Problems, seededRandom } from "../testing/helpers";
import { containRect } from "./containRect";

describe("containRect: 表のケース（1280x720 の出力）", () => {
  test.each([
    ["同じ大きさ（16:9）", 1280, 720, { x: 0, y: 0, width: 1280, height: 720 }],
    ["1920x1080（16:9）の入力は、縮小して全面", 1920, 1080, { x: 0, y: 0, width: 1280, height: 720 }],
    ["4:3（1024x768）は、高さに合わせ、左右に余白", 1024, 768, { x: 160, y: 0, width: 960, height: 720 }],
    ["縦長の 9:16（1080x1920）は、高さに合わせ、左右に広い余白（余りの 1 画素は右へ）", 1080, 1920, { x: 437, y: 0, width: 405, height: 720 }],
    ["超横長の 21:9（2560x1080）は、幅に合わせ、上下に余白", 2560, 1080, { x: 0, y: 90, width: 1280, height: 540 }],
    ["正方形（1000x1000）は、高さに合わせる", 1000, 1000, { x: 280, y: 0, width: 720, height: 720 }],
    ["出力より小さい入力（320x180）は、拡大して全面", 320, 180, { x: 0, y: 0, width: 1280, height: 720 }],
    ["出力より小さい正方形（100x100）は、拡大して高さに合わせる", 100, 100, { x: 280, y: 0, width: 720, height: 720 }],
    ["出力よりはるかに大きい入力（7680x4320）", 7680, 4320, { x: 0, y: 0, width: 1280, height: 720 }],
  ])("%s", (_label, srcWidth, srcHeight, expected) => {
    expect(containRect(srcWidth, srcHeight, 1280, 720)).toEqual(expected);
  });
});

describe("containRect: 表のケース（854x480 の出力）", () => {
  test.each([
    ["1920x1080（16:9）は、854x480 がちょうど 16:9 ではないため、高さに合わせて右に 1 画素の余白", 1920, 1080, { x: 0, y: 0, width: 853, height: 480 }],
    ["4:3（1024x768）", 1024, 768, { x: 107, y: 0, width: 640, height: 480 }],
    ["縦長の 9:16（1080x1920）", 1080, 1920, { x: 292, y: 0, width: 270, height: 480 }],
    ["超横長の 21:9（2560x1080）", 2560, 1080, { x: 0, y: 60, width: 854, height: 360 }],
  ])("%s", (_label, srcWidth, srcHeight, expected) => {
    expect(containRect(srcWidth, srcHeight, 854, 480)).toEqual(expected);
  });
});

describe("containRect: 丸めの規則（奇数の大きさ・端数）", () => {
  test.each([
    ["奇数の出力：51 に収まる 100x100 は 51x51。左の余白 25・右の余白 25", 100, 100, 101, 51, { x: 25, y: 0, width: 51, height: 51 }],
    ["四捨五入で 0.5 は切り上げる：3x2 を 101x51 へ（高さに合わせた幅は 76.5 -> 77）", 3, 2, 101, 51, { x: 12, y: 0, width: 77, height: 51 }],
    ["四捨五入で 0.5 は切り上げる：2x1 を 5x5 へ（幅に合わせた高さは 2.5 -> 3）。余白は上 1・下 1", 2, 1, 5, 5, { x: 0, y: 1, width: 5, height: 3 }],
    ["余白が奇数なら、左・上が小さく右・下が大きい：4x1 を 10x6 へ（高さ 2.5 -> 3、余白 3 を上 1・下 2）", 4, 1, 10, 6, { x: 0, y: 1, width: 10, height: 3 }],
    ["奇数の入力（1921x1081）を 1280x720 へ：高さに合わせた幅は 1279.48 -> 1279", 1921, 1081, 1280, 720, { x: 0, y: 0, width: 1279, height: 720 }],
    ["1 画素の入力は、全面に拡大する", 1, 1, 8, 8, { x: 0, y: 0, width: 8, height: 8 }],
    ["出力が 1x1", 1920, 1080, 1, 1, { x: 0, y: 0, width: 1, height: 1 }],
  ])("%s", (_label, srcWidth, srcHeight, outWidth, outHeight, expected) => {
    expect(containRect(srcWidth, srcHeight, outWidth, outHeight)).toEqual(expected);
  });
});

describe("containRect: 極端な縦横比（どちらの辺も 1 画素以上を保つ）", () => {
  test.each([
    ["極端に縦長（1x10000）", 1, 10_000, 1280, 720, { x: 639, y: 0, width: 1, height: 720 }],
    ["極端に横長（10000x1）", 10_000, 1, 1280, 720, { x: 0, y: 359, width: 1280, height: 1 }],
    ["出力が極端に縦長（10x1000）に、横長の入力（16:9）", 1920, 1080, 10, 1000, { x: 0, y: 497, width: 10, height: 6 }],
  ])("%s", (_label, srcWidth, srcHeight, outWidth, outHeight, expected) => {
    expect(containRect(srcWidth, srcHeight, outWidth, outHeight)).toEqual(expected);
  });
});

describe("containRect: 性質（疑似乱数 20,000 組）", () => {
  test("出力の内側に収まる・少なくとも 1 辺が出力に接する・縦横比が丸め 0.5 画素以内・中央に置く（余白の差は 1 画素以内）", () => {
    const random = seededRandom(24);
    const problems = new Problems();
    const pick = (max: number): number => 1 + Math.floor(random() * max);

    for (let i = 0; i < 20_000; i += 1) {
      const srcWidth = pick(4_000);
      const srcHeight = pick(4_000);
      const outWidth = pick(2_000);
      const outHeight = pick(2_000);
      const rect = containRect(srcWidth, srcHeight, outWidth, outHeight);
      const label = `${srcWidth}x${srcHeight} -> ${outWidth}x${outHeight}: ${JSON.stringify(rect)}`;

      if (rect.x < 0 || rect.y < 0 || rect.width < 1 || rect.height < 1 || rect.x + rect.width > outWidth || rect.y + rect.height > outHeight) {
        problems.report(`out of bounds ${label}`);
      }
      if (rect.width !== outWidth && rect.height !== outHeight) {
        problems.report(`touches neither edge ${label}`);
      }
      const scale = Math.min(outWidth / srcWidth, outHeight / srcHeight);
      const idealWidth = srcWidth * scale;
      const idealHeight = srcHeight * scale;
      const widthOk = Math.abs(rect.width - idealWidth) <= 0.5 + 1e-9 || (rect.width === 1 && idealWidth < 1);
      const heightOk = Math.abs(rect.height - idealHeight) <= 0.5 + 1e-9 || (rect.height === 1 && idealHeight < 1);
      if (!widthOk || !heightOk) {
        problems.report(`aspect ratio is not kept within half a pixel ${label}`);
      }
      const leftover = outWidth - rect.width - rect.x;
      const bottomLeftover = outHeight - rect.height - rect.y;
      if (leftover - rect.x < 0 || leftover - rect.x > 1 || bottomLeftover - rect.y < 0 || bottomLeftover - rect.y > 1) {
        problems.report(`not centered ${label}`);
      }
      if (![rect.x, rect.y, rect.width, rect.height].every(Number.isInteger)) {
        problems.report(`not integers ${label}`);
      }
    }
    expect(problems.list()).toEqual([]);
  });

  test("同じ縦横比の入力は、どの大きさでも同じ結果になる（拡大・縮小に依らない）", () => {
    expect(containRect(1920, 1080, 1280, 720)).toEqual(containRect(16, 9, 1280, 720));
    expect(containRect(1920, 1080, 1280, 720)).toEqual(containRect(3840, 2160, 1280, 720));
  });
});

describe("containRect: 不正な入力（フォールバックせず RangeError）", () => {
  test.each([
    ["入力の幅が 0", [0, 1080, 1280, 720]],
    ["入力の高さが 0", [1920, 0, 1280, 720]],
    ["出力の幅が 0", [1920, 1080, 0, 720]],
    ["出力の高さが 0", [1920, 1080, 1280, 0]],
    ["負の数", [-1920, 1080, 1280, 720]],
    ["小数", [1920.5, 1080, 1280, 720]],
    ["NaN", [Number.NaN, 1080, 1280, 720]],
    ["無限大", [1920, Number.POSITIVE_INFINITY, 1280, 720]],
    ["大きすぎる値（計算が安全整数に収まらない）", [2 ** 30, 2 ** 30, 2 ** 30, 2 ** 30]],
  ])("%s", (_label, args) => {
    const [srcWidth, srcHeight, outWidth, outHeight] = args as [number, number, number, number];
    expect(() => containRect(srcWidth, srcHeight, outWidth, outHeight)).toThrow(RangeError);
  });

  test("結果は変更できない（凍結されている）", () => {
    expect(Object.isFrozen(containRect(1920, 1080, 1280, 720))).toBe(true);
  });
});
