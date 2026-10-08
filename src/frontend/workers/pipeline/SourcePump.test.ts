/**
 * @jest-environment node
 */
// SourcePump（requirements.md 11.4・13.1。issue #27）。メインスレッドから転送された readable（VideoFrame のストリーム）を、ワーカー上で読み、
// FrameStore（各ソース最新の 1 枚）へ渡す。
//   - 読んだフレームは、FrameStore が最新の 1 枚だけを保持し、古いものを直ちに閉じる（解放漏れが無い）
//   - ストリームが自然に終わった（トラックの終了）ら、onEnded で知らせる。失敗したら onError（黙って止まらない）
//   - stop（ソースの解除）で読み取りを取り消す。取り消しの途中で届いたフレームは、保持せず、閉じる
import { FrameStore } from "./FrameStore";
import { SourcePump } from "./SourcePump";
import { FakeVideoFrame, FrameLedger } from "./test-support";

/** 非同期の読み取りが進むのを待つ。 */
async function settle(): Promise<void> {
  for (let index = 0; index < 5; index += 1) {
    await new Promise<void>((resolve) => setImmediate(resolve));
  }
}

function createStream(): { readable: ReadableStream<FakeVideoFrame>; controller: ReadableStreamDefaultController<FakeVideoFrame>; cancelled: () => boolean } {
  const captured: { controller: ReadableStreamDefaultController<FakeVideoFrame> | null; cancelled: boolean } = { controller: null, cancelled: false };
  const readable = new ReadableStream<FakeVideoFrame>({
    start: (controller) => {
      captured.controller = controller;
    },
    cancel: () => {
      captured.cancelled = true;
    },
  });
  if (captured.controller === null) {
    throw new Error("the stream controller was not captured");
  }
  return { readable, controller: captured.controller, cancelled: () => captured.cancelled };
}

function setup() {
  const ledger = new FrameLedger();
  const store = new FrameStore<FakeVideoFrame>();
  const ended: string[] = [];
  const errors: Array<{ kind: string; error: unknown }> = [];
  const { readable, controller, cancelled } = createStream();
  const pump = new SourcePump({
    kind: "camera",
    readable: readable as unknown as ReadableStream<VideoFrame>,
    store: store as unknown as FrameStore<VideoFrame>,
    onEnded: (kind) => ended.push(kind),
    onError: (kind, error) => errors.push({ kind, error }),
  });
  return { ledger, store, ended, errors, controller, cancelled, pump };
}

describe("フレームを読んで、最新の 1 枚だけを保持する", () => {
  it("届いたフレームは FrameStore の最新になり、古いフレームは閉じられる。解放漏れが無い（受け取った数 = 閉じた数 + 保持している数）", async () => {
    const { ledger, store, controller, pump } = setup();
    pump.start();
    const frames = [ledger.create(640, 480), ledger.create(640, 480), ledger.create(640, 480)];

    for (const frame of frames) {
      controller.enqueue(frame);
    }
    await settle();

    expect(store.latest("camera")).toBe(frames[2]);
    expect(frames.map((frame) => frame.closeCount)).toEqual([1, 1, 0]);
    expect(store.receivedCount).toBe(3);
    expect(store.receivedCount).toBe(store.closedCount + store.retainedCount);
    expect(ledger.openCount).toBe(1);
  });

  it("多数のフレーム（1,000 枚）を流しても、保持は常に 1 枚以下で、最後に 1 枚だけが残る", async () => {
    const { ledger, store, controller, pump } = setup();
    pump.start();

    for (let index = 0; index < 1000; index += 1) {
      controller.enqueue(ledger.create(640, 480));
      if (index % 50 === 0) {
        await settle();
        expect(store.retained("camera")).toBeLessThanOrEqual(1);
      }
    }
    await settle();

    expect(ledger.openCount).toBe(1);
    expect(store.retainedCount).toBe(1);
    expect(ledger.doubleClosedCount).toBe(0);
  });

  it("start を重ねても、読み取りは 1 つだけ（フレームを二重に取り込まない）", async () => {
    const { ledger, store, controller, pump } = setup();

    pump.start();
    pump.start();
    controller.enqueue(ledger.create(640, 480));
    await settle();

    expect(store.receivedCount).toBe(1);
    expect(pump.isRunning).toBe(true);
  });
});

describe("ストリームの終わり・失敗", () => {
  it("ストリームが閉じたら（トラックの終了）、onEnded を 1 回呼ぶ。保持しているフレームの解放は、呼び出し側（ホスト）が行う", async () => {
    const { ledger, store, ended, controller, pump } = setup();
    pump.start();
    controller.enqueue(ledger.create(640, 480));
    await settle();

    controller.close();
    await settle();

    expect(ended).toEqual(["camera"]);
    expect(pump.isRunning).toBe(false);
    expect(store.retained("camera")).toBe(1);
  });

  it("ストリームが失敗したら、onError に、ソースの種類と原因を渡す（黙って止まらない）", async () => {
    const { errors, ended, controller, pump } = setup();
    pump.start();

    controller.error(new DOMException("track failed", "AbortError"));
    await settle();

    expect(errors).toHaveLength(1);
    expect(errors[0].kind).toBe("camera");
    expect((errors[0].error as DOMException).name).toBe("AbortError");
    expect(ended).toEqual([]);
    expect(pump.isRunning).toBe(false);
  });

  it("FrameStore がフレームを閉じられなくても（close の失敗）、onError に渡す", async () => {
    const { ledger, errors, controller, pump } = setup();
    pump.start();
    const bad = ledger.create(640, 480);
    bad.close = () => {
      throw new DOMException("cannot close", "InvalidStateError");
    };
    controller.enqueue(bad);
    controller.enqueue(ledger.create(640, 480));
    await settle();

    expect(errors).toHaveLength(1);
    expect((errors[0].error as DOMException).name).toBe("InvalidStateError");
  });
});

describe("stop（ソースの解除）", () => {
  it("読み取りを取り消す（ストリームも取り消される）。以後に届くフレームは取り込まない。onEnded は呼ばない（呼び出し側が止めたため）", async () => {
    const { ledger, store, ended, cancelled, pump } = setup();
    pump.start();

    await pump.stop();

    expect(cancelled()).toBe(true);
    expect(pump.isRunning).toBe(false);
    expect(ended).toEqual([]);
    expect(store.receivedCount).toBe(0);
    expect(ledger.openCount).toBe(0);
  });

  it("取り消しの途中で届いたフレームは、保持せず、閉じる（解放漏れを作らない）", async () => {
    const ledger = new FrameLedger();
    const store = new FrameStore<FakeVideoFrame>();
    const late = ledger.create(640, 480);
    let resolveRead: (result: ReadableStreamReadResult<FakeVideoFrame>) => void = () => undefined;
    const reader = {
      read: () =>
        new Promise<ReadableStreamReadResult<FakeVideoFrame>>((resolve) => {
          resolveRead = resolve;
        }),
      cancel: () => Promise.resolve(),
      releaseLock: () => undefined,
    };
    const pump = new SourcePump({
      kind: "screen",
      readable: { getReader: () => reader } as unknown as ReadableStream<VideoFrame>,
      store: store as unknown as FrameStore<VideoFrame>,
      onEnded: () => undefined,
      onError: () => undefined,
    });
    pump.start();

    const stopping = pump.stop();
    resolveRead({ done: false, value: late });
    await stopping;

    expect(late.closeCount).toBe(1);
    expect(store.receivedCount).toBe(0);
    expect(store.retainedCount).toBe(0);
  });

  it("stop は何度呼んでもよい。start する前の stop も、何も起こさない", async () => {
    const { pump } = setup();

    await expect(pump.stop()).resolves.toBeUndefined();
    pump.start();
    await pump.stop();
    await expect(pump.stop()).resolves.toBeUndefined();
  });
});
