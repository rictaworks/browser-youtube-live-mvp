/**
 * @jest-environment node
 */
// VideoCompositor（requirements.md 11.3・11.4。issue #27）。OffscreenCanvas の 2D コンテキストで、1 枚の完成フレームを合成する。
//   - 出力解像度はプロファイルに固定（入力に依存しない）。主映像は縦横比を保って内接し、余白は単色。ワイプは右下（幅 22%・余白 2.5%・角の丸め 6%）
//   - レイアウトは resolveLayout（画面共有 + カメラ = 画面共有が主・カメラがワイプ / 画面共有のみ / カメラのみ / 代替スレート）
//   - 合成の結果は毎回 1 枚の完成フレームとして確定する（描きかけを符号化しない）。ソースの追加・解除・喪失で、レイアウトが変わっても、中断しない
//   - 代替スレートは、文字を描かない（疑似のコンテキストは fillText を持たない。呼べば TypeError になる）
// モックの境界: キャンバスの 2D コンテキストは疑似（呼び出し・引数・その時点の fillStyle を記録する）。画素の確認は、test/ の実ブラウザの確認。
import { LIMITS, PROFILE_VALUES } from "@/core/contract";
import type { Profile } from "@/core/contract";
import { COMPOSITION_LETTERBOX_COLOR, SLATE } from "@/lib/pipeline/config";
import { PipelineError } from "@/lib/pipeline/errors";
import { VideoCompositor } from "./VideoCompositor";
import { FakeCanvas, FakeVideoFrame, FakeVideoFrameFactory, asVideoFrame } from "./test-support";

function setup(profile: Profile = "720p") {
  const canvas = new FakeCanvas();
  const factory = new FakeVideoFrameFactory();
  const compositor = new VideoCompositor({ canvas: canvas.asOffscreen(), profile, VideoFrame: factory.constructorLike });
  return { canvas, factory, compositor, context: canvas.context };
}

function source(width: number, height: number): FakeVideoFrame {
  return new FakeVideoFrame(width, height);
}

describe("構築", () => {
  it.each(PROFILE_VALUES.map((profile) => [profile] as const))("%s: キャンバスの大きさを、プロファイルの解像度に固定する（入力に依存しない）", (profile) => {
    const { canvas, compositor } = setup(profile);

    expect(canvas.width).toBe(LIMITS.profiles[profile].width);
    expect(canvas.height).toBe(LIMITS.profiles[profile].height);
    expect(compositor.width).toBe(LIMITS.profiles[profile].width);
    expect(compositor.height).toBe(LIMITS.profiles[profile].height);
    expect(compositor.profile).toBe(profile);
  });

  it("2D コンテキストは、不透明（alpha なし）で作る。余白を単色で塗るので、透過は要らない", () => {
    const { canvas } = setup();

    expect(canvas.contextOptions).toEqual({ alpha: false });
  });

  it("2D コンテキストを得られなければ compose_failed（推測して続けない）", () => {
    const canvas = new FakeCanvas();
    canvas.returnNullContext = true;

    expect(() => new VideoCompositor({ canvas: canvas.asOffscreen(), profile: "720p", VideoFrame: new FakeVideoFrameFactory().constructorLike })).toThrow(PipelineError);
  });

  it("未知のプロファイルは RangeError", () => {
    expect(() => new VideoCompositor({ canvas: new FakeCanvas().asOffscreen(), profile: "1080p" as never, VideoFrame: new FakeVideoFrameFactory().constructorLike })).toThrow(RangeError);
  });
});

describe("4 つのレイアウト（描画命令の位置・大きさ・クリップの丸め・背景色）", () => {
  it("画面共有のみ: 背景を単色で塗り、画面共有を内接させて描く", () => {
    const { compositor, context } = setup("720p");
    const screen = source(1080, 1920);

    const result = compositor.compose({ screen: asVideoFrame(screen), camera: null });

    expect(result.layout).toBe("screen_only");
    expect(context.methodNames).toEqual(["fillRect", "drawImage"]);
    expect(context.calls[0]).toEqual({ method: "fillRect", args: [0, 0, 1280, 720], fillStyle: COMPOSITION_LETTERBOX_COLOR });
    expect(context.calls[1].args).toEqual([screen, 437, 0, 405, 720]);
  });

  it("カメラのみ: カメラを主映像として内接させる", () => {
    const { compositor, context } = setup("720p");
    const camera = source(640, 480);

    const result = compositor.compose({ screen: null, camera: asVideoFrame(camera) });

    expect(result.layout).toBe("camera_only");
    expect(context.methodNames).toEqual(["fillRect", "drawImage"]);
    expect(context.calls[1].args).toEqual([camera, 160, 0, 960, 720]);
  });

  it("画面共有 + カメラ: 画面共有が主映像、カメラが右下のワイプ（角を丸くクリップ）。クリップは、描画のあとに必ず戻す", () => {
    const { compositor, context } = setup("720p");
    const screen = source(1920, 1080);
    const camera = source(1280, 720);

    const result = compositor.compose({ screen: asVideoFrame(screen), camera: asVideoFrame(camera) });

    expect(result.layout).toBe("screen_with_wipe");
    expect(context.methodNames).toEqual(["fillRect", "drawImage", "save", "beginPath", "roundRect", "clip", "drawImage", "restore"]);
    expect(context.calls[1].args).toEqual([screen, 0, 0, 1280, 720]);
    expect(context.calls[4].args).toEqual([966, 529, 282, 159, 17]);
    expect(context.calls[6].args).toEqual([camera, 966, 529, 282, 159]);
  });

  it("代替スレート: 単色の背景と、簡素な図形（角丸の枠と円）だけ。ソースは描かない。文字を描かない", () => {
    const { compositor, context } = setup("720p");

    const result = compositor.compose({ screen: null, camera: null });

    expect(result.layout).toBe("slate");
    expect(context.methodNames).toEqual(["fillRect", "beginPath", "roundRect", "fill", "beginPath", "arc", "fill"]);
    expect(context.calls[0]).toEqual({ method: "fillRect", args: [0, 0, 1280, 720], fillStyle: SLATE.backgroundColor });
    expect(context.calls[3].fillStyle).toBe(SLATE.frameColor);
    expect(context.calls[6].fillStyle).toBe(SLATE.markColor);
    expect(context.calls[5].args).toEqual([640, 360, 51, 0, Math.PI * 2]);
  });

  it.each(PROFILE_VALUES.map((profile) => [profile] as const))("%s: すべてのレイアウトで、描画は出力の枠の中に収まる", (profile) => {
    const { compositor, context } = setup(profile);
    const { width, height } = LIMITS.profiles[profile];
    const inputs = [
      { screen: source(1920, 1080), camera: source(640, 480) },
      { screen: source(1080, 1920), camera: source(720, 1280) },
      { screen: source(100, 100), camera: null },
      { screen: null, camera: source(3440, 1440) },
      { screen: null, camera: null },
    ];

    for (const input of inputs) {
      context.calls.length = 0;
      compositor.compose({ screen: input.screen === null ? null : asVideoFrame(input.screen), camera: input.camera === null ? null : asVideoFrame(input.camera) });
      for (const call of context.calls.filter((entry) => entry.method === "drawImage")) {
        const [, x, y, w, h] = call.args as [unknown, number, number, number, number];
        expect(x).toBeGreaterThanOrEqual(0);
        expect(y).toBeGreaterThanOrEqual(0);
        expect(x + w).toBeLessThanOrEqual(width);
        expect(y + h).toBeLessThanOrEqual(height);
      }
    }
  });

  it("480p: 出力の大きさが 854x480 になり、ワイプの幅は出力幅の約 22%", () => {
    const { compositor, context } = setup("480p");

    compositor.compose({ screen: asVideoFrame(source(1920, 1080)), camera: asVideoFrame(source(1280, 720)) });

    const roundRect = context.calls.find((call) => call.method === "roundRect");
    const wipeWidth = (roundRect?.args as number[])[2];
    expect(Math.abs(wipeWidth / 854 - 0.22)).toBeLessThan(0.003);
    expect(context.calls[0].args).toEqual([0, 0, 854, 480]);
  });
});

describe("ソースの追加・解除・喪失でレイアウトが変わっても、フレームは途切れない", () => {
  it("画面共有の喪失 -> カメラのみ -> カメラの喪失（スレート）-> 画面共有の再取得: どの合成も、完成した 1 枚で、毎回、背景から描き直す", () => {
    const { compositor, context, factory } = setup("720p");
    const screen = asVideoFrame(source(1920, 1080));
    const camera = asVideoFrame(source(640, 480));
    const sequence = [
      { screen, camera, layout: "screen_with_wipe" },
      { screen: null, camera, layout: "camera_only" },
      { screen: null, camera: null, layout: "slate" },
      { screen, camera: null, layout: "screen_only" },
      { screen, camera, layout: "screen_with_wipe" },
    ] as const;

    sequence.forEach((step, index) => {
      const before = context.calls.length;
      const result = compositor.compose({ screen: step.screen, camera: step.camera });
      const snapshot = compositor.snapshot(index * 33_333);

      expect(result.layout).toBe(step.layout);
      expect(context.calls[before].method).toBe("fillRect");
      expect((snapshot as unknown as FakeVideoFrame).drawCallsAtCreation).toBe(context.calls.length);
    });
    expect(factory.created).toHaveLength(sequence.length);
  });

  it("入力の大きさが途中で変わっても（共有する窓の大きさの変更）、次の合成が、新しい大きさで内接させる", () => {
    const { compositor, context } = setup("720p");

    compositor.compose({ screen: asVideoFrame(source(1920, 1080)), camera: null });
    compositor.compose({ screen: asVideoFrame(source(640, 480)), camera: null });

    const draws = context.calls.filter((call) => call.method === "drawImage");
    expect(draws[0].args.slice(1)).toEqual([0, 0, 1280, 720]);
    expect(draws[1].args.slice(1)).toEqual([160, 0, 960, 720]);
  });
});

describe("フレームの所有: 合成は、入力のフレームを閉じず、保持しない", () => {
  it("合成のあとも、入力のフレームは閉じられていない（閉じるのは FrameStore）", () => {
    const { compositor } = setup();
    const screen = source(1920, 1080);
    const camera = source(640, 480);

    compositor.compose({ screen: asVideoFrame(screen), camera: asVideoFrame(camera) });

    expect(screen.closeCount).toBe(0);
    expect(camera.closeCount).toBe(0);
  });

  it("前の合成のフレームを、次の合成で描かない（保持していない）", () => {
    const { compositor, context } = setup();
    const screen = source(1920, 1080);
    compositor.compose({ screen: asVideoFrame(screen), camera: null });
    context.calls.length = 0;

    compositor.compose({ screen: null, camera: null });

    expect(context.calls.some((call) => call.method === "drawImage")).toBe(false);
  });
});

describe("snapshot（完成した 1 枚を、符号化へ渡す VideoFrame にする）", () => {
  it("合成の前に呼ぶと invalid_state（描きかけ・未描画のフレームを符号化しない）", () => {
    const { compositor } = setup();

    expect(() => compositor.snapshot(0)).toThrow(PipelineError);
    try {
      compositor.snapshot(0);
    } catch (error) {
      expect((error as PipelineError).code).toBe("invalid_state");
    }
  });

  it("キャンバスから、指定の時刻（マイクロ秒）の VideoFrame を作る。描画がすべて終わったあとに作る", () => {
    const { compositor, context, canvas, factory } = setup();
    compositor.compose({ screen: asVideoFrame(source(1920, 1080)), camera: asVideoFrame(source(640, 480)) });

    const frame = compositor.snapshot(66_667) as unknown as FakeVideoFrame;

    expect(frame.source).toBe(canvas);
    expect(frame.timestamp).toBe(66_667);
    expect(frame.drawCallsAtCreation).toBe(context.calls.length);
    expect(factory.created).toEqual([frame]);
  });

  it("時刻は、0 以上の安全整数だけを受け付ける（実時計・小数の時刻を持ち込まない）", () => {
    const { compositor } = setup();
    compositor.compose({ screen: null, camera: null });

    expect(() => compositor.snapshot(-1)).toThrow(RangeError);
    expect(() => compositor.snapshot(0.5)).toThrow(RangeError);
    expect(() => compositor.snapshot(Number.NaN)).toThrow(RangeError);
    expect(() => compositor.snapshot(2 ** 53)).toThrow(RangeError);
  });

  it("VideoFrame の作成に失敗したら compose_failed（元のエラーの名前だけを残す）", () => {
    const { compositor, factory } = setup();
    compositor.compose({ screen: null, camera: null });
    factory.failNext = true;

    try {
      compositor.snapshot(0);
      throw new Error("should have thrown");
    } catch (error) {
      expect(error).toBeInstanceOf(PipelineError);
      expect((error as PipelineError).code).toBe("compose_failed");
      expect((error as PipelineError).detail).toBe("InvalidStateError");
    }
  });
});

describe("合成の失敗（描きかけを符号化しない）", () => {
  it("描画の途中で失敗したら compose_failed。そのあと snapshot は invalid_state（描きかけのキャンバスを符号化しない）", () => {
    const { compositor, context } = setup();
    context.failOn = "drawImage";

    expect(() => compositor.compose({ screen: asVideoFrame(source(1920, 1080)), camera: null })).toThrow(PipelineError);
    expect(() => compositor.snapshot(0)).toThrow(PipelineError);
  });

  it("ワイプの描画で失敗しても、save と restore は釣り合う（クリップが残らない）", () => {
    const { compositor, context } = setup();
    compositor.compose({ screen: asVideoFrame(source(1920, 1080)), camera: asVideoFrame(source(640, 480)) });
    context.calls.length = 0;
    context.failOn = "clip";

    expect(() => compositor.compose({ screen: asVideoFrame(source(1920, 1080)), camera: asVideoFrame(source(640, 480)) })).toThrow(PipelineError);

    const saves = context.calls.filter((call) => call.method === "save").length;
    const restores = context.calls.filter((call) => call.method === "restore").length;
    expect(saves).toBe(1);
    expect(restores).toBe(1);
  });

  it("失敗のあとでも、次の合成は、背景から描き直して成功する", () => {
    const { compositor, context } = setup();
    context.failOn = "drawImage";
    expect(() => compositor.compose({ screen: asVideoFrame(source(1920, 1080)), camera: null })).toThrow(PipelineError);
    context.failOn = null;
    context.calls.length = 0;

    const result = compositor.compose({ screen: asVideoFrame(source(1920, 1080)), camera: null });

    expect(result.layout).toBe("screen_only");
    expect(context.calls[0].method).toBe("fillRect");
    expect(() => compositor.snapshot(0)).not.toThrow();
  });

  it("閉じられたフレーム（寸法が 0）は、描かない。compose_failed", () => {
    const { compositor } = setup();
    const closed = source(0, 0);

    expect(() => compositor.compose({ screen: asVideoFrame(closed), camera: null })).toThrow(PipelineError);
  });
});
