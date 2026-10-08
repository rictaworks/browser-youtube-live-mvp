/**
 * @jest-environment node
 */
// FrameStore（requirements.md 11.4。issue #27）。取得した映像フレームは、各ソース最新の 1 枚だけを保持する。古いフレームは、新しいフレームが届いた時点で
// 直ちに close() する。保持数は常に 1 以下で、解放漏れが無い（受け取った数 = 閉じた数 + 保持している数）。
import { FrameStore } from "./FrameStore";
import { FrameLedger } from "./test-support";
import type { FakeVideoFrame } from "./test-support";

describe("各ソース最新の 1 枚だけを保持する", () => {
  it("新しいフレームが届くと、古いフレームを直ちに close() する。最新の 1 枚は、閉じずに持つ", () => {
    const ledger = new FrameLedger();
    const store = new FrameStore<FakeVideoFrame>();
    const first = ledger.create(640, 480);
    const second = ledger.create(640, 480);

    store.put("camera", first);
    expect(first.closed).toBe(false);
    expect(store.latest("camera")).toBe(first);

    store.put("camera", second);

    expect(first.closeCount).toBe(1);
    expect(second.closed).toBe(false);
    expect(store.latest("camera")).toBe(second);
    expect(store.retainedCount).toBe(1);
  });

  it("画面共有とカメラは、互いに影響しない（それぞれ最新の 1 枚。合計で 2 枚まで）", () => {
    const ledger = new FrameLedger();
    const store = new FrameStore<FakeVideoFrame>();
    const screen = ledger.create(1920, 1080);
    const camera = ledger.create(640, 480);

    store.put("screen", screen);
    store.put("camera", camera);
    store.put("camera", ledger.create(640, 480));

    expect(screen.closed).toBe(false);
    expect(camera.closeCount).toBe(1);
    expect(store.retained("screen")).toBe(1);
    expect(store.retained("camera")).toBe(1);
    expect(store.retainedCount).toBe(2);
  });

  it("まだ届いていないソースの最新は null", () => {
    const store = new FrameStore<FakeVideoFrame>();

    expect(store.latest("screen")).toBeNull();
    expect(store.retained("screen")).toBe(0);
  });

  it("未知のソースの種類は RangeError（推測しない）", () => {
    const store = new FrameStore<FakeVideoFrame>();

    expect(() => store.latest("microphone" as never)).toThrow(RangeError);
    expect(() => store.put("microphone" as never, new FrameLedger().create(1, 1))).toThrow(RangeError);
  });
});

describe("解放漏れが無い（受け取った数 = 閉じた数 + 保持している数）", () => {
  it("1,000 回の操作（届く・解除）の途中のどの時点でも、保持数は 1 以下（ソースごと）で、帳簿と一致する", () => {
    const ledger = new FrameLedger();
    const store = new FrameStore<FakeVideoFrame>();
    let seed = 12345;
    const random = (): number => {
      seed = (seed * 1103515245 + 12345) % 2147483648;
      return seed / 2147483648;
    };

    for (let step = 0; step < 1000; step += 1) {
      const kind = random() < 0.5 ? "screen" : "camera";
      if (random() < 0.9) {
        store.put(kind, ledger.create(640, 480));
      } else {
        store.release(kind);
      }

      expect(store.retained("screen")).toBeLessThanOrEqual(1);
      expect(store.retained("camera")).toBeLessThanOrEqual(1);
      expect(store.receivedCount).toBe(store.closedCount + store.retainedCount);
      expect(ledger.openCount).toBe(store.retainedCount);
      expect(ledger.doubleClosedCount).toBe(0);
    }
  });

  it("release は、保持しているフレームを閉じる。何も無ければ何もしない", () => {
    const store = new FrameStore<FakeVideoFrame>();
    const ledger = new FrameLedger();
    const frame = ledger.create(640, 480);
    store.put("camera", frame);

    store.release("camera");
    store.release("camera");

    expect(frame.closeCount).toBe(1);
    expect(store.latest("camera")).toBeNull();
    expect(store.retainedCount).toBe(0);
  });

  it("releaseAll は、すべてのソースのフレームを閉じる", () => {
    const ledger = new FrameLedger();
    const store = new FrameStore<FakeVideoFrame>();
    store.put("screen", ledger.create(1920, 1080));
    store.put("camera", ledger.create(640, 480));

    store.releaseAll();

    expect(ledger.openCount).toBe(0);
    expect(store.retainedCount).toBe(0);
    expect(store.receivedCount).toBe(store.closedCount);
  });

  it("同じフレームをもう一度 put しても、二重に閉じない・二重に数えない", () => {
    const ledger = new FrameLedger();
    const store = new FrameStore<FakeVideoFrame>();
    const frame = ledger.create(640, 480);

    store.put("camera", frame);
    store.put("camera", frame);

    expect(frame.closeCount).toBe(0);
    expect(store.receivedCount).toBe(1);
    expect(store.retainedCount).toBe(1);
  });
});

describe("破棄（dispose）のあと", () => {
  it("保持していたフレームを閉じ、以後に届いたフレームも、受け取ってすぐ閉じる（解放漏れを作らない）", () => {
    const ledger = new FrameLedger();
    const store = new FrameStore<FakeVideoFrame>();
    const held = ledger.create(640, 480);
    store.put("camera", held);

    store.dispose();
    const late = ledger.create(640, 480);
    store.put("camera", late);

    expect(held.closeCount).toBe(1);
    expect(late.closeCount).toBe(1);
    expect(store.latest("camera")).toBeNull();
    expect(store.retainedCount).toBe(0);
    expect(store.receivedCount).toBe(store.closedCount);
    expect(ledger.openCount).toBe(0);
  });

  it("dispose は何度呼んでもよい", () => {
    const store = new FrameStore<FakeVideoFrame>();

    store.dispose();

    expect(() => store.dispose()).not.toThrow();
  });
});

describe("close() が例外を投げても、保持の状態は壊れない", () => {
  it("閉じるのに失敗したフレームは、保持から外す（二度と描かない）。失敗は呼び出し元に伝える", () => {
    const ledger = new FrameLedger();
    const store = new FrameStore<FakeVideoFrame>();
    const bad = ledger.create(640, 480);
    bad.close = () => {
      throw new DOMException("cannot close", "InvalidStateError");
    };
    store.put("camera", bad);

    expect(() => store.put("camera", ledger.create(640, 480))).toThrow(DOMException);

    expect(store.retained("camera")).toBe(1);
    expect(store.latest("camera")).not.toBe(bad);
  });
});
