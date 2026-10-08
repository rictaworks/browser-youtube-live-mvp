/**
 * @jest-environment node
 */
// 描画命令の計算（requirements.md 11.3・11.4。issue #27）。レイアウトと、入力の大きさから、1 枚の完成フレームを描く命令の列を決める純粋な関数。
//   - 出力解像度はプロファイルに固定（入力に依存しない）。主映像は縦横比を保って内接（containRect）し、余白は単色で埋める
//   - ワイプは右下（幅 = 出力幅の 22%・外側の余白 = 2.5%・角の丸め = ワイプ幅の 6%。wipeRect）。絶対値を使わない
//   - 代替スレートは、文字を描かない（単色の背景と、簡素な図形のみ）
import { containRect, wipeRect } from "@/core/layout";
import { LAYOUT_VALUES, LIMITS, PROFILE_VALUES } from "@/core/contract";
import type { Layout, Profile } from "@/core/contract";
import { COMPOSITION_LETTERBOX_COLOR, SLATE } from "./config";
import { planFrame } from "./drawPlan";
import type { DrawCommand, FramePlanInput, SourceSize } from "./drawPlan";

function sizeOf(profile: Profile): { outputWidth: number; outputHeight: number } {
  return { outputWidth: LIMITS.profiles[profile].width, outputHeight: LIMITS.profiles[profile].height };
}

function input(layout: Layout, profile: Profile, screen: SourceSize | null, camera: SourceSize | null): FramePlanInput {
  return { layout, ...sizeOf(profile), screen, camera };
}

const FULL_HD: SourceSize = { width: 1920, height: 1080 };
const CAMERA_4_3: SourceSize = { width: 640, height: 480 };

describe("出力解像度はプロファイルに固定（入力に依存しない）", () => {
  it.each(PROFILE_VALUES.map((profile) => [profile] as const))("%s: すべての命令が、出力の枠の中に収まる（入力がどんな大きさでも）", (profile) => {
    const { outputWidth, outputHeight } = sizeOf(profile);
    const sizes: SourceSize[] = [FULL_HD, CAMERA_4_3, { width: 1080, height: 1920 }, { width: 3440, height: 1440 }, { width: 100, height: 100 }, { width: 4, height: 4000 }, { width: 7680, height: 4320 }];

    for (const screen of sizes) {
      for (const camera of sizes) {
        for (const layout of LAYOUT_VALUES) {
          for (const command of planFrame(input(layout, profile, screen, camera))) {
            const rect = "rect" in command ? command.rect : null;
            if (rect !== null) {
              expect(rect.x).toBeGreaterThanOrEqual(0);
              expect(rect.y).toBeGreaterThanOrEqual(0);
              expect(rect.width).toBeGreaterThanOrEqual(1);
              expect(rect.height).toBeGreaterThanOrEqual(1);
              expect(rect.x + rect.width).toBeLessThanOrEqual(outputWidth);
              expect(rect.y + rect.height).toBeLessThanOrEqual(outputHeight);
            }
          }
        }
      }
    }
  });

  it("最初の命令は、出力の全体を単色で埋める（余白の色。描きかけの前のフレームが残らない）", () => {
    for (const profile of PROFILE_VALUES) {
      const { outputWidth, outputHeight } = sizeOf(profile);
      for (const layout of ["screen_with_wipe", "screen_only", "camera_only"] as const) {
        const [first] = planFrame(input(layout, profile, FULL_HD, CAMERA_4_3));
        expect(first).toEqual({ op: "fill_rect", color: COMPOSITION_LETTERBOX_COLOR, rect: { x: 0, y: 0, width: outputWidth, height: outputHeight } });
      }
    }
  });
});

describe("主映像は、縦横比を保って出力枠に内接する（containRect）", () => {
  // 720p の期待値は、手計算（交差乗算と四捨五入）
  it.each([
    ["横長 16:9（1920x1080）", { width: 1920, height: 1080 }, { x: 0, y: 0, width: 1280, height: 720 }],
    ["4:3（640x480）: 左右に余白", { width: 640, height: 480 }, { x: 160, y: 0, width: 960, height: 720 }],
    ["縦長 9:16（1080x1920）: 左右に広い余白", { width: 1080, height: 1920 }, { x: 437, y: 0, width: 405, height: 720 }],
    ["超横長 21:9（3440x1440）: 上下に余白", { width: 3440, height: 1440 }, { x: 0, y: 92, width: 1280, height: 536 }],
    ["正方形（100x100）: 拡大して内接", { width: 100, height: 100 }, { x: 280, y: 0, width: 720, height: 720 }],
    ["出力と同じ（1280x720）", { width: 1280, height: 720 }, { x: 0, y: 0, width: 1280, height: 720 }],
  ])("720p・画面共有のみ: %s", (_name, screen, expected) => {
    const plan = planFrame(input("screen_only", "720p", screen, null));

    expect(plan).toHaveLength(2);
    expect(plan[1]).toEqual({ op: "draw_source", slot: "screen", rect: expected });
  });

  it.each(PROFILE_VALUES.map((profile) => [profile] as const))("%s: containRect の結果と一致する（画面共有のみ・カメラのみ）", (profile) => {
    const { outputWidth, outputHeight } = sizeOf(profile);
    for (const source of [FULL_HD, CAMERA_4_3, { width: 1080, height: 1920 }, { width: 3440, height: 1440 }]) {
      const screenPlan = planFrame(input("screen_only", profile, source, null));
      const cameraPlan = planFrame(input("camera_only", profile, null, source));
      const expected = containRect(source.width, source.height, outputWidth, outputHeight);

      expect(screenPlan[1]).toEqual({ op: "draw_source", slot: "screen", rect: expected });
      expect(cameraPlan[1]).toEqual({ op: "draw_source", slot: "camera", rect: expected });
    }
  });

  it("カメラのみ: カメラが主映像として内接する。ワイプは無い", () => {
    const plan = planFrame(input("camera_only", "720p", FULL_HD, CAMERA_4_3));

    expect(plan.map((command) => command.op)).toEqual(["fill_rect", "draw_source"]);
    expect(plan[1]).toEqual({ op: "draw_source", slot: "camera", rect: { x: 160, y: 0, width: 960, height: 720 } });
  });
});

describe("ワイプ: 右下・幅 22%・外側の余白 2.5%・角の丸め 6%（wipeRect）", () => {
  it("720p・カメラ 16:9: 手計算の値（幅 282・高さ 159・余白 32・角 17）", () => {
    const plan = planFrame(input("screen_with_wipe", "720p", FULL_HD, { width: 1280, height: 720 }));

    expect(plan.map((command) => command.op)).toEqual(["fill_rect", "draw_source", "draw_source_rounded"]);
    expect(plan[1]).toEqual({ op: "draw_source", slot: "screen", rect: { x: 0, y: 0, width: 1280, height: 720 } });
    expect(plan[2]).toEqual({ op: "draw_source_rounded", slot: "camera", rect: { x: 966, y: 529, width: 282, height: 159 }, cornerRadius: 17 });
  });

  it.each(PROFILE_VALUES.map((profile) => [profile] as const))("%s: wipeRect の結果と一致し、右・下の外側の余白が等しい", (profile) => {
    const { outputWidth, outputHeight } = sizeOf(profile);
    for (const camera of [{ width: 1280, height: 720 }, CAMERA_4_3, { width: 720, height: 1280 }, { width: 1000, height: 4000 }]) {
      const plan = planFrame(input("screen_with_wipe", profile, FULL_HD, camera));
      const wipe = plan[2] as Extract<DrawCommand, { op: "draw_source_rounded" }>;
      const expected = wipeRect(outputWidth, outputHeight, camera.width / camera.height);

      expect(wipe.slot).toBe("camera");
      expect(wipe.rect).toEqual({ x: expected.x, y: expected.y, width: expected.width, height: expected.height });
      expect(wipe.cornerRadius).toBe(expected.cornerRadius);
      expect(outputWidth - (wipe.rect.x + wipe.rect.width)).toBe(outputHeight - (wipe.rect.y + wipe.rect.height));
    }
  });

  it("ワイプの幅は出力幅の 22%（絶対値でなく、比）: 480p でも 22%", () => {
    const plan720 = planFrame(input("screen_with_wipe", "720p", FULL_HD, { width: 1280, height: 720 }));
    const plan480 = planFrame(input("screen_with_wipe", "480p", FULL_HD, { width: 1280, height: 720 }));
    const width720 = (plan720[2] as Extract<DrawCommand, { op: "draw_source_rounded" }>).rect.width;
    const width480 = (plan480[2] as Extract<DrawCommand, { op: "draw_source_rounded" }>).rect.width;

    expect(Math.abs(width720 / 1280 - 0.22)).toBeLessThan(0.002);
    expect(Math.abs(width480 / 854 - 0.22)).toBeLessThan(0.003);
  });

  it("角の丸めはワイプ幅の 6%（上限は短い辺の半分）", () => {
    const plan = planFrame(input("screen_with_wipe", "720p", FULL_HD, { width: 1280, height: 720 }));
    const wipe = plan[2] as Extract<DrawCommand, { op: "draw_source_rounded" }>;

    expect(Math.abs(wipe.cornerRadius / wipe.rect.width - 0.06)).toBeLessThan(0.005);
    expect(wipe.cornerRadius).toBeLessThanOrEqual(Math.floor(Math.min(wipe.rect.width, wipe.rect.height) / 2));
  });

  it("ワイプは主映像の上に描く（最後の命令）", () => {
    const plan = planFrame(input("screen_with_wipe", "480p", CAMERA_4_3, FULL_HD));

    expect(plan[plan.length - 1].op).toBe("draw_source_rounded");
  });
});

describe("代替スレート（映像ソースが皆無のとき。常に利用できる静止の映像）", () => {
  it("入力の大きさ（null）に依存せず、単色の背景と簡素な図形だけ。ソースを描く命令を含まない", () => {
    for (const profile of PROFILE_VALUES) {
      const plan = planFrame(input("slate", profile, null, null));

      expect(plan.map((command) => command.op)).toEqual(["fill_rect", "fill_round_rect", "fill_circle"]);
      expect(plan.some((command) => command.op === "draw_source" || command.op === "draw_source_rounded")).toBe(false);
    }
  });

  it("背景は出力の全体を埋め、図形は出力の中央に収まる", () => {
    const { outputWidth, outputHeight } = sizeOf("720p");
    const [background, frame, mark] = planFrame(input("slate", "720p", null, null)) as [
      Extract<DrawCommand, { op: "fill_rect" }>,
      Extract<DrawCommand, { op: "fill_round_rect" }>,
      Extract<DrawCommand, { op: "fill_circle" }>,
    ];

    expect(background).toEqual({ op: "fill_rect", color: SLATE.backgroundColor, rect: { x: 0, y: 0, width: outputWidth, height: outputHeight } });
    expect(frame.rect.x + frame.rect.width / 2).toBeCloseTo(outputWidth / 2, 0);
    expect(frame.rect.y + frame.rect.height / 2).toBeCloseTo(outputHeight / 2, 0);
    expect(frame.rect.width).toBe(Math.round((outputWidth * SLATE.frameWidthPermille) / 1000));
    expect(mark.centerX).toBe(outputWidth / 2);
    expect(mark.centerY).toBe(outputHeight / 2);
    expect(mark.radius).toBeGreaterThan(0);
    expect(mark.radius).toBeLessThan(frame.rect.height / 2);
  });

  it("文字を描く命令の種類が無い（利用者の文言を含めない）", () => {
    const operations = new Set<string>();
    for (const layout of LAYOUT_VALUES) {
      for (const command of planFrame(input(layout, "720p", FULL_HD, CAMERA_4_3))) {
        operations.add(command.op);
      }
    }

    expect(Array.from(operations).sort()).toEqual(["draw_source", "draw_source_rounded", "fill_circle", "fill_rect", "fill_round_rect"]);
  });

  it("スレートの色は、すべて設定（config.ts）の値", () => {
    const plan = planFrame(input("slate", "720p", null, null));
    const colors = plan.flatMap((command) => ("color" in command ? [command.color] : []));

    expect(colors).toEqual([SLATE.backgroundColor, SLATE.frameColor, SLATE.markColor]);
  });
});

describe("不整合な入力は、推測せず RangeError", () => {
  it.each([
    ["画面共有とワイプなのに、画面共有が無い", "screen_with_wipe" as const, null, CAMERA_4_3],
    ["画面共有とワイプなのに、カメラが無い", "screen_with_wipe" as const, FULL_HD, null],
    ["画面共有のみなのに、画面共有が無い", "screen_only" as const, null, CAMERA_4_3],
    ["カメラのみなのに、カメラが無い", "camera_only" as const, FULL_HD, null],
  ])("%s", (_name, layout, screen, camera) => {
    expect(() => planFrame(input(layout, "720p", screen, camera))).toThrow(RangeError);
  });

  it("未知のレイアウト", () => {
    expect(() => planFrame({ ...input("slate", "720p", null, null), layout: "grid" as unknown as Layout })).toThrow(RangeError);
  });

  it.each([
    ["出力の幅が 0", { outputWidth: 0, outputHeight: 720 }],
    ["出力の高さが負", { outputWidth: 1280, outputHeight: -1 }],
    ["出力が小数", { outputWidth: 1280.5, outputHeight: 720 }],
  ])("%s", (_name, size) => {
    expect(() => planFrame({ ...input("screen_only", "720p", FULL_HD, null), ...size })).toThrow(RangeError);
  });

  it.each([
    ["幅が 0", { width: 0, height: 100 }],
    ["高さが NaN", { width: 100, height: Number.NaN }],
    ["小数", { width: 100.5, height: 100 }],
  ])("入力の大きさが不正: %s", (_name, screen) => {
    expect(() => planFrame(input("screen_only", "720p", screen, null))).toThrow(RangeError);
  });
});

describe("計算は純粋（同じ入力に、同じ出力。入力を変更しない）", () => {
  it("2 回呼んで同じ結果。結果は凍結されている", () => {
    const given = input("screen_with_wipe", "720p", FULL_HD, CAMERA_4_3);
    const snapshot = JSON.stringify(given);

    const first = planFrame(given);
    const second = planFrame(given);

    expect(second).toEqual(first);
    expect(JSON.stringify(given)).toBe(snapshot);
    expect(Object.isFrozen(first)).toBe(true);
  });
});
