/**
 * @jest-environment node
 */
// PipelineHost（プレビューだけの間・映像ソース。requirements.md 11.2〜11.4・16.2。issue #27）。
//   - 配信前（音声のクロックが無い間）は、ワーカーのタイマで 30 fps を駆動して、プレビューだけを描く。符号化はしない（配信の送出には使わない）
//   - 映像ソース（画面共有・カメラ）の readable をワーカーで読み、各ソース最新の 1 枚だけを保持する（古いフレームは直ちに閉じる）
//   - ソースの追加・解除・喪失で、レイアウトが変わっても、描画は止まらない。レイアウトの変化は、1 回ずつ知らせる
//   - 合成・プレビューの失敗は、型付きの故障として 1 回だけ知らせる（繰り返さない）。プレビューの失敗で、合成は止めない
import { COMPOSITION_LETTERBOX_COLOR, PREVIEW_INTERVAL_MS, SLATE } from "@/lib/pipeline/config";
import { HostHarness, settle } from "./host-support";
import { FakeCanvas, FakeVideoEncoder } from "./test-support";

/** タイマを 1 周期ぶん進める（プレビューの描画が 1 回行われる）。 */
function tick(harness: HostHarness, count = 1): void {
  harness.scheduler.advance(PREVIEW_INTERVAL_MS * count + 1);
}

describe("起動", () => {
  it("合成用のキャンバスは、配信前のプレビューの解像度（標準 720p）。起動しただけでは、何も知らせない（ready は、ワーカーの入り口が知らせる）", () => {
    const harness = new HostHarness();

    expect(harness.canvases).toHaveLength(1);
    expect(harness.compositeCanvas.width).toBe(1280);
    expect(harness.compositeCanvas.height).toBe(720);
    expect(harness.events).toEqual([]);
    expect(harness.scheduler.activeCount).toBe(0);
  });
});

describe("プレビューだけの間: ワーカーのタイマで 30 fps を駆動する（符号化しない）", () => {
  it("プレビュー用の canvas を受け取ると、30 fps の 1 周期ごとに、合成して、同じキャンバスをプレビューへ 1:1 で写す", () => {
    const harness = new HostHarness();
    const preview = harness.attachPreview(300, 150);

    expect(harness.scheduler.intervalsStarted).toEqual([PREVIEW_INTERVAL_MS]);
    tick(harness, 3);

    const draws = preview.context.calls.filter((call) => call.method === "drawImage");
    expect(draws).toHaveLength(3);
    expect(draws.every((call) => call.args[0] === harness.compositeCanvas && call.args[1] === 0 && call.args[2] === 0)).toBe(true);
    expect(preview.width).toBe(1280);
    expect(preview.height).toBe(720);
  });

  it("映像ソースが皆無なら、代替スレートを描く（単色の背景。文字を描かない）", () => {
    const harness = new HostHarness();
    harness.attachPreview();

    tick(harness);

    const first = harness.compositeCanvas.context.calls[0];
    expect(first).toEqual({ method: "fillRect", args: [0, 0, 1280, 720], fillStyle: SLATE.backgroundColor });
    expect(harness.eventsOf("layout")).toEqual([{ type: "layout", layout: "slate" }]);
  });

  it("符号化はしない: VideoFrame も、エンコーダも作らない。配信の送出には使わない（そのためのタイマは、プレビューだけ）", () => {
    const harness = new HostHarness();
    harness.attachPreview();

    tick(harness, 10);

    expect(harness.videoFrames.created).toHaveLength(0);
    expect(FakeVideoEncoder.instances).toHaveLength(0);
    expect(harness.eventsOf("chunk")).toEqual([]);
  });

  it("プレビューが無ければ、タイマを動かさない（描く先が無い）。外せば、止める。付け直せば、また動く", () => {
    const harness = new HostHarness();
    expect(harness.scheduler.activeIntervalCount).toBe(0);

    harness.attachPreview();
    expect(harness.scheduler.activeIntervalCount).toBe(1);

    harness.send({ type: "detach_preview" });
    expect(harness.scheduler.activeIntervalCount).toBe(0);

    harness.attachPreview();
    expect(harness.scheduler.activeIntervalCount).toBe(1);
  });

  it("プレビュー用の canvas を差し替えると、新しいほうへ描く", () => {
    const harness = new HostHarness();
    const first = harness.attachPreview();
    tick(harness);
    const second = harness.attachPreview();
    tick(harness);

    expect(first.context.calls.filter((call) => call.method === "drawImage")).toHaveLength(1);
    expect(second.context.calls.filter((call) => call.method === "drawImage")).toHaveLength(1);
    expect(harness.scheduler.activeIntervalCount).toBe(1);
  });

  it("プレビューの canvas が使えない（2D コンテキストを得られない）: preview_unavailable の故障。タイマは動かさない", () => {
    const harness = new HostHarness();
    const unusable = new FakeCanvas(300, 150);
    unusable.returnNullContext = true;

    harness.send({ type: "attach_preview", canvas: unusable.asOffscreen() });

    expect(harness.faultCodes()).toEqual(["preview_unavailable"]);
    expect(harness.scheduler.activeIntervalCount).toBe(0);
  });

  it("プレビューへの描画が失敗しても、故障を 1 回だけ知らせ、プレビューを外す。合成は続く（符号化を止めない）", () => {
    const harness = new HostHarness();
    const preview = harness.attachPreview();
    preview.context.failOn = "drawImage";

    tick(harness, 5);

    expect(harness.faultCodes()).toEqual(["preview_unavailable"]);
    expect(harness.scheduler.activeIntervalCount).toBe(0);
    expect(harness.compositeCanvas.context.calls.length).toBeGreaterThan(0);
  });
});

describe("映像ソース（画面共有・カメラ）の取り込みと、各ソース最新の 1 枚", () => {
  it("カメラのフレームが届くと、レイアウトはカメラのみになり、そのフレームを主映像として描く", async () => {
    const harness = new HostHarness();
    harness.attachPreview();
    tick(harness);
    const camera = harness.addSource("camera");
    const frame = camera.ledger.create(640, 480);

    camera.controller.enqueue(frame);
    await settle();
    harness.compositeCanvas.context.calls.length = 0;
    tick(harness);

    expect(harness.eventsOf("layout").map((event) => event.layout)).toEqual(["slate", "camera_only"]);
    expect(harness.compositeCanvas.context.calls.map((call) => call.method)).toEqual(["fillRect", "drawImage"]);
    expect(harness.compositeCanvas.context.calls[0].fillStyle).toBe(COMPOSITION_LETTERBOX_COLOR);
    expect(harness.compositeCanvas.context.calls[1].args).toEqual([frame, 160, 0, 960, 720]);
  });

  it("画面共有とカメラ: 画面共有が主映像、カメラがワイプ。レイアウトの変化は 1 回ずつ知らせる（同じレイアウトの間は知らせない）", async () => {
    const harness = new HostHarness();
    harness.attachPreview();
    const screen = harness.addSource("screen");
    const camera = harness.addSource("camera");
    screen.controller.enqueue(screen.ledger.create(1920, 1080));
    camera.controller.enqueue(camera.ledger.create(640, 480));
    await settle();

    tick(harness, 5);

    expect(harness.eventsOf("layout").map((event) => event.layout)).toEqual(["screen_with_wipe"]);
    expect(harness.compositeCanvas.context.calls.map((call) => call.method)).toContain("clip");
  });

  it("最新の 1 枚だけを保持する: 新しいフレームが届くと、古いフレームを直ちに閉じる。解放漏れが無い", async () => {
    const harness = new HostHarness();
    const camera = harness.addSource("camera");
    const frames = Array.from({ length: 50 }, () => camera.ledger.create(640, 480));

    for (const frame of frames) {
      camera.controller.enqueue(frame);
    }
    await settle();
    const requestId = harness.request("get_stats");
    const reply = await harness.replyTo(requestId);

    expect(reply.ok).toBe(true);
    if (reply.ok && reply.result.kind === "stats") {
      expect(reply.result.stats.framesReceived).toBe(50);
      expect(reply.result.stats.framesRetained).toBe(1);
      expect(reply.result.stats.framesClosed).toBe(49);
      expect(reply.result.stats.framesReceived).toBe(reply.result.stats.framesClosed + reply.result.stats.framesRetained);
    }
    expect(camera.ledger.openCount).toBe(1);
    expect(frames.filter((frame) => frame.closeCount === 1)).toHaveLength(49);
  });

  it("動きの無い画面共有（新しいフレームが届かない）でも、最後のフレームを描き続ける（描いた直後に閉じない）", async () => {
    const harness = new HostHarness();
    harness.attachPreview();
    const screen = harness.addSource("screen");
    const frame = screen.ledger.create(1920, 1080);
    screen.controller.enqueue(frame);
    await settle();

    tick(harness, 10);

    const draws = harness.compositeCanvas.context.calls.filter((call) => call.method === "drawImage");
    expect(draws).toHaveLength(10);
    expect(draws.every((call) => call.args[0] === frame)).toBe(true);
    expect(frame.closed).toBe(false);
  });

  it("ソースの解除（remove_source）: 保持しているフレームを直ちに閉じ、読み取りを取り消す。次の合成から、レイアウトが変わる（描画は途切れない）", async () => {
    const harness = new HostHarness();
    harness.attachPreview();
    const screen = harness.addSource("screen");
    const camera = harness.addSource("camera");
    screen.controller.enqueue(screen.ledger.create(1920, 1080));
    camera.controller.enqueue(camera.ledger.create(640, 480));
    await settle();
    tick(harness);
    const drawsBefore = harness.compositeCanvas.context.calls.length;

    harness.send({ type: "remove_source", kind: "screen" });
    await settle();
    tick(harness);

    expect(screen.ledger.openCount).toBe(0);
    expect(screen.cancelled).toBe(true);
    expect(harness.eventsOf("layout").map((event) => event.layout)).toEqual(["screen_with_wipe", "camera_only"]);
    expect(harness.compositeCanvas.context.calls.length).toBeGreaterThan(drawsBefore);
  });

  it("画面共有の喪失 -> カメラのみ -> カメラの喪失（代替スレート）: 毎回の描画が続き、レイアウトの変化が順に知らされる", async () => {
    const harness = new HostHarness();
    harness.attachPreview();
    const screen = harness.addSource("screen");
    const camera = harness.addSource("camera");
    screen.controller.enqueue(screen.ledger.create(1920, 1080));
    camera.controller.enqueue(camera.ledger.create(640, 480));
    await settle();
    tick(harness);

    screen.controller.close();
    await settle();
    tick(harness);
    camera.controller.close();
    await settle();
    tick(harness);

    expect(harness.eventsOf("layout").map((event) => event.layout)).toEqual(["screen_with_wipe", "camera_only", "slate"]);
    expect(harness.eventsOf("source_ended").map((event) => event.kind)).toEqual(["screen", "camera"]);
    expect(screen.ledger.openCount + camera.ledger.openCount).toBe(0);
  });

  it("ストリームの失敗: source_stream_failed の故障と、ソースの終了を知らせ、フレームを閉じる", async () => {
    const harness = new HostHarness();
    harness.attachPreview();
    const camera = harness.addSource("camera");
    camera.controller.enqueue(camera.ledger.create(640, 480));
    await settle();

    camera.controller.error(new DOMException("track failed", "AbortError"));
    await settle();

    expect(harness.eventsOf("fault").map((event) => event.fault)).toEqual([{ code: "source_stream_failed", detail: "AbortError" }]);
    expect(harness.eventsOf("source_ended").map((event) => event.kind)).toEqual(["camera"]);
    expect(camera.ledger.openCount).toBe(0);
  });

  it("同じ種類のソースを追加し直す（デバイスの切り替え）と、前のソースを止めて、保持しているフレームを閉じる", async () => {
    const harness = new HostHarness();
    const first = harness.addSource("camera");
    const firstFrame = first.ledger.create(640, 480);
    first.controller.enqueue(firstFrame);
    await settle();

    const second = harness.addSource("camera");
    await settle();
    const secondFrame = second.ledger.create(1280, 720);
    second.controller.enqueue(secondFrame);
    await settle();

    expect(first.cancelled).toBe(true);
    expect(firstFrame.closeCount).toBe(1);
    expect(secondFrame.closed).toBe(false);
  });

  it("映像ソースの種類として未知のもの（マイクなど）は、invalid_message の故障", () => {
    const harness = new HostHarness();

    harness.send({ type: "add_source", kind: "microphone", readable: { getReader: () => ({}) } });

    expect(harness.faultCodes()).toEqual(["invalid_message"]);
  });
});

describe("合成の失敗（描きかけを符号化しない）", () => {
  it("描画が失敗したら、compose_failed の故障を 1 回だけ知らせる（毎フレームは知らせない）。描画が回復したら、また知らせられる状態に戻る", async () => {
    const harness = new HostHarness();
    harness.attachPreview();
    const camera = harness.addSource("camera");
    camera.controller.enqueue(camera.ledger.create(640, 480));
    await settle();
    harness.compositeCanvas.context.failOn = "drawImage";

    tick(harness, 10);
    expect(harness.faultCodes()).toEqual(["compose_failed"]);

    harness.compositeCanvas.context.failOn = null;
    tick(harness, 3);
    harness.compositeCanvas.context.failOn = "drawImage";
    tick(harness, 3);

    expect(harness.faultCodes()).toEqual(["compose_failed", "compose_failed"]);
  });

  it("失敗した合成のフレームは、プレビューへ写さない（描きかけを表示しない）", async () => {
    const harness = new HostHarness();
    const preview = harness.attachPreview();
    const camera = harness.addSource("camera");
    camera.controller.enqueue(camera.ledger.create(640, 480));
    await settle();
    harness.compositeCanvas.context.failOn = "drawImage";

    tick(harness, 3);

    expect(preview.context.calls).toEqual([]);
  });
});
