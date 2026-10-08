/**
 * @jest-environment node
 */
// PreviewSurface・PreviewTicker（requirements.md 16.2・11.4・11.6。issue #27）。
//   - プレビューは、実際に送出するものと同一の構図であること: 合成した 1 枚のキャンバスを、そのまま（拡縮せず、1:1 で）プレビュー用のキャンバスへ写す。
//     別の合成をしない（プレビューと送出で、構図が食い違う余地を作らない）
//   - プレビュー用の canvas は、メインスレッドで transferControlToOffscreen したものをワーカーへ渡して描く（メインスレッドの描画で配信を妨げない）
//   - 配信前（音声のクロックが無い間）だけ、ワーカーのタイマで 30 fps を駆動する。このタイマは、配信の送出には使わない
import { PREVIEW_INTERVAL_MS } from "@/lib/pipeline/config";
import { PipelineError } from "@/lib/pipeline/errors";
import { PreviewSurface } from "./PreviewSurface";
import { PreviewTicker } from "./PreviewTicker";
import { FakeCanvas, FakeScheduler } from "./test-support";

describe("PreviewSurface", () => {
  it("attach: 2D コンテキストを得る（不透明）。attach するまでは、何も描かない（present は偽）", () => {
    const surface = new PreviewSurface();
    const preview = new FakeCanvas(300, 150);
    const composite = new FakeCanvas(1280, 720);

    expect(surface.isAttached).toBe(false);
    expect(surface.present(composite.asOffscreen())).toBe(false);
    expect(preview.context.calls).toEqual([]);

    surface.attach(preview.asOffscreen());

    expect(surface.isAttached).toBe(true);
    expect(preview.contextOptions).toEqual({ alpha: false });
  });

  it("present: 合成したキャンバスを、そのまま（1:1 で）写す。プレビューの大きさが違えば、合成の大きさに合わせる", () => {
    const surface = new PreviewSurface();
    const preview = new FakeCanvas(300, 150);
    const composite = new FakeCanvas(1280, 720);
    surface.attach(preview.asOffscreen());

    expect(surface.present(composite.asOffscreen())).toBe(true);

    expect(preview.width).toBe(1280);
    expect(preview.height).toBe(720);
    expect(preview.context.calls).toEqual([{ method: "drawImage", args: [composite, 0, 0], fillStyle: "" }]);
  });

  it("同じ大きさなら、大きさを設定し直さない（設定すると、キャンバスが消えてしまう）", () => {
    const surface = new PreviewSurface();
    const preview = new FakeCanvas(1280, 720);
    let widthWrites = 0;
    let heightWrites = 0;
    let width = 1280;
    let height = 720;
    Object.defineProperty(preview, "width", {
      get: () => width,
      set: (value: number) => {
        widthWrites += 1;
        width = value;
      },
    });
    Object.defineProperty(preview, "height", {
      get: () => height,
      set: (value: number) => {
        heightWrites += 1;
        height = value;
      },
    });
    surface.attach(preview.asOffscreen());

    surface.present(new FakeCanvas(1280, 720).asOffscreen());
    surface.present(new FakeCanvas(1280, 720).asOffscreen());

    expect(widthWrites).toBe(0);
    expect(heightWrites).toBe(0);
    expect(preview.context.calls).toHaveLength(2);
  });

  it("プレビューが描くのは、合成の画素をそのまま写すだけ（ソースを描く命令・塗りの命令を持たない）", () => {
    const surface = new PreviewSurface();
    const preview = new FakeCanvas(1280, 720);
    surface.attach(preview.asOffscreen());

    surface.present(new FakeCanvas(1280, 720).asOffscreen());

    expect(preview.context.methodNames).toEqual(["drawImage"]);
  });

  it("2D コンテキストを得られなければ preview_unavailable", () => {
    const surface = new PreviewSurface();
    const preview = new FakeCanvas(300, 150);
    preview.returnNullContext = true;

    expect(() => surface.attach(preview.asOffscreen())).toThrow(PipelineError);
    try {
      surface.attach(preview.asOffscreen());
    } catch (error) {
      expect((error as PipelineError).code).toBe("preview_unavailable");
    }
    expect(surface.isAttached).toBe(false);
  });

  it("getContext が例外を投げても preview_unavailable（元のエラーの名前を残す）", () => {
    const surface = new PreviewSurface();
    const preview = new FakeCanvas(300, 150);
    preview.getContext = () => {
      throw new DOMException("context lost", "InvalidStateError");
    };

    try {
      surface.attach(preview.asOffscreen());
      throw new Error("should have thrown");
    } catch (error) {
      expect((error as PipelineError).code).toBe("preview_unavailable");
      expect((error as PipelineError).detail).toBe("InvalidStateError");
    }
    expect(surface.isAttached).toBe(false);
  });

  it("描画の失敗は preview_unavailable（元のエラーの名前を残す）。例外は、呼び出し元（配信を続けるか決める側）へ伝える", () => {
    const surface = new PreviewSurface();
    const preview = new FakeCanvas(1280, 720);
    preview.context.failOn = "drawImage";
    surface.attach(preview.asOffscreen());

    try {
      surface.present(new FakeCanvas(1280, 720).asOffscreen());
      throw new Error("should have thrown");
    } catch (error) {
      expect(error).toBeInstanceOf(PipelineError);
      expect((error as PipelineError).code).toBe("preview_unavailable");
      expect((error as PipelineError).detail).toBe("InvalidStateError");
    }
  });

  it("detach: 以後は何も描かない。差し替え（attach をもう一度）は、新しいキャンバスへ描く", () => {
    const surface = new PreviewSurface();
    const first = new FakeCanvas(1280, 720);
    const second = new FakeCanvas(1280, 720);
    const composite = new FakeCanvas(1280, 720);
    surface.attach(first.asOffscreen());
    surface.present(composite.asOffscreen());

    surface.attach(second.asOffscreen());
    surface.present(composite.asOffscreen());
    surface.detach();
    const afterDetach = surface.present(composite.asOffscreen());

    expect(first.context.calls).toHaveLength(1);
    expect(second.context.calls).toHaveLength(1);
    expect(afterDetach).toBe(false);
    expect(surface.isAttached).toBe(false);
    expect(() => surface.detach()).not.toThrow();
  });
});

describe("PreviewTicker（配信前のプレビューだけを駆動する。配信の送出には使わない）", () => {
  it("30 fps の 1 周期（約 33.3 ミリ秒）ごとに、コールバックを呼ぶ", () => {
    const scheduler = new FakeScheduler();
    const ticker = new PreviewTicker(scheduler, () => undefined);
    let count = 0;

    ticker.start(() => {
      count += 1;
    });
    scheduler.advance(1010);

    expect(scheduler.intervalsStarted).toEqual([PREVIEW_INTERVAL_MS]);
    expect(count).toBe(30);
    expect(ticker.running).toBe(true);
  });

  it("start を重ねても、タイマは 1 つだけ", () => {
    const scheduler = new FakeScheduler();
    const ticker = new PreviewTicker(scheduler, () => undefined);

    ticker.start(() => undefined);
    ticker.start(() => undefined);

    expect(scheduler.activeIntervalCount).toBe(1);
  });

  it("stop: タイマを止める。以後はコールバックを呼ばない。何度呼んでもよい", () => {
    const scheduler = new FakeScheduler();
    const ticker = new PreviewTicker(scheduler, () => undefined);
    let count = 0;
    ticker.start(() => {
      count += 1;
    });
    scheduler.advance(100);

    ticker.stop();
    ticker.stop();
    scheduler.advance(1000);

    expect(count).toBe(3);
    expect(ticker.running).toBe(false);
    expect(scheduler.activeCount).toBe(0);
  });

  it("コールバックの例外は、タイマの外へ漏らさず（ワーカーの未処理の例外にしない）、onError へ渡す。タイマは続く", () => {
    const scheduler = new FakeScheduler();
    const errors: unknown[] = [];
    const ticker = new PreviewTicker(scheduler, (error) => errors.push(error));
    let calls = 0;
    ticker.start(() => {
      calls += 1;
      throw new RangeError("draw failed");
    });

    expect(() => scheduler.advance(100)).not.toThrow();

    expect(calls).toBe(3);
    expect(errors).toHaveLength(3);
    expect(errors[0]).toBeInstanceOf(RangeError);
    expect(ticker.running).toBe(true);
  });

  it("止めたあとに start し直せる", () => {
    const scheduler = new FakeScheduler();
    const ticker = new PreviewTicker(scheduler, () => undefined);
    let count = 0;
    ticker.start(() => undefined);
    ticker.stop();

    ticker.start(() => {
      count += 1;
    });
    scheduler.advance(100);

    expect(count).toBe(3);
  });
});
