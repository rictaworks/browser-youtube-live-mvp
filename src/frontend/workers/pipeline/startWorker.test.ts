/**
 * @jest-environment node
 */
// ワーカーの入り口（issue #27）。配線だけを行う薄い層: 実行環境（WebCodecs・OffscreenCanvas・タイマ）を作り、ホストを作り、メッセージを渡す。
//   - 準備ができたら ready を知らせる。実行環境に必要な機能が無ければ、ready の代わりに、型付きの故障を知らせる（メインスレッドが、起動の失敗を知れる）
//   - 符号化結果は、ArrayBuffer を転送して送る（コピーしない）
//   - shutdown のあとは、ワーカー自身を閉じる
import { createEncodedChunk } from "@/lib/pipeline/chunks";
import { createPoster, startPipelineWorker } from "./startWorker";
import type { PipelineWorkerScope } from "./startWorker";
import { FakeAudioDataFactory, FakeAudioEncoder, FakeCanvas, FakeVideoEncoder, FakeVideoFrameFactory } from "./test-support";

interface Posted {
  readonly message: unknown;
  readonly transfer: readonly unknown[];
}

function createScope(overrides: Partial<Record<keyof PipelineWorkerScope, unknown>> = {}): { scope: PipelineWorkerScope; posted: Posted[]; closed: () => number } {
  FakeVideoEncoder.reset();
  FakeAudioEncoder.reset();
  const posted: Posted[] = [];
  let closeCount = 0;
  function OffscreenCanvasConstructor(this: unknown, width: number, height: number): FakeCanvas {
    return new FakeCanvas(width, height);
  }
  const scope = {
    VideoEncoder: FakeVideoEncoder,
    AudioEncoder: FakeAudioEncoder,
    VideoFrame: new FakeVideoFrameFactory().constructorLike,
    AudioData: new FakeAudioDataFactory().constructorLike,
    OffscreenCanvas: OffscreenCanvasConstructor,
    setInterval: () => 1,
    clearInterval: () => undefined,
    setTimeout: () => 1,
    clearTimeout: () => undefined,
    postMessage: (message: unknown, transfer: readonly unknown[] = []) => {
      posted.push({ message, transfer });
    },
    onmessage: null,
    close: () => {
      closeCount += 1;
    },
    ...overrides,
  } as unknown as PipelineWorkerScope;
  return { scope, posted, closed: () => closeCount };
}

describe("起動", () => {
  it("準備ができたら ready を知らせる。メッセージの受け口を設定する", () => {
    const { scope, posted } = createScope();

    const host = startPipelineWorker(scope, { diagnostic: () => undefined });

    expect(host).not.toBeNull();
    expect(posted.map((entry) => entry.message)).toEqual([{ type: "ready" }]);
    expect(typeof scope.onmessage).toBe("function");
  });

  it("届いたメッセージは、ホストへ渡す（get_stats の応答が返る）", async () => {
    const { scope, posted } = createScope();
    startPipelineWorker(scope, { diagnostic: () => undefined });

    scope.onmessage?.({ data: { type: "get_stats", requestId: 1 } } as MessageEvent);
    await new Promise<void>((resolve) => setImmediate(resolve));

    const reply = posted.map((entry) => entry.message).find((message) => (message as { type?: string }).type === "reply");
    expect(reply).toMatchObject({ type: "reply", requestId: 1, ok: true });
  });

  it.each(["VideoEncoder", "AudioEncoder", "VideoFrame", "AudioData", "OffscreenCanvas", "setInterval", "setTimeout"] as const)(
    "実行環境に %s が無ければ、ready の代わりに environment_unsupported の故障を知らせる（推測して続けない）。受け口は設定しない",
    (missing) => {
      const { scope, posted } = createScope({ [missing]: undefined });

      const host = startPipelineWorker(scope, { diagnostic: () => undefined });

      expect(host).toBeNull();
      expect(posted.map((entry) => entry.message)).toEqual([{ type: "fault", fault: { code: "environment_unsupported", detail: null } }]);
      expect(scope.onmessage).toBeNull();
    },
  );
});

describe("終了", () => {
  it("shutdown を受けたら、ホストの資源を解放し、ワーカー自身を閉じる", () => {
    const { scope, closed } = createScope();
    startPipelineWorker(scope, { diagnostic: () => undefined });

    scope.onmessage?.({ data: { type: "shutdown" } } as MessageEvent);

    expect(closed()).toBe(1);
  });

  it("shutdown 以外のメッセージでは、閉じない", () => {
    const { scope, closed } = createScope();
    startPipelineWorker(scope, { diagnostic: () => undefined });

    scope.onmessage?.({ data: { type: "detach_preview" } } as MessageEvent);

    expect(closed()).toBe(0);
  });
});

describe("メッセージの送り出し（createPoster）", () => {
  it("符号化結果は、ArrayBuffer を転送して送る", () => {
    const { scope, posted } = createScope();
    const data = new Uint8Array([1, 2, 3]);

    createPoster(scope)({ type: "chunk", chunk: createEncodedChunk({ kind: "video", timestampUs: 0, keyframe: true, data }) });

    expect(posted).toHaveLength(1);
    expect(posted[0].transfer).toEqual([data.buffer]);
  });

  it("それ以外は、転送対象なしで送る", () => {
    const { scope, posted } = createScope();

    createPoster(scope)({ type: "layout", layout: "slate" });

    expect(posted).toEqual([{ message: { type: "layout", layout: "slate" }, transfer: [] }]);
  });
});

describe("診断", () => {
  it("診断の出力先へ、故障の符号と、元のエラーの名前だけを出す", () => {
    const { scope } = createScope();
    const diagnostics: Array<{ event: string; fields: unknown }> = [];
    startPipelineWorker(scope, { diagnostic: (event, fields) => diagnostics.push({ event, fields }) });

    scope.onmessage?.({ data: { type: "set_bitrate", kbps: 3000 } } as MessageEvent);

    expect(diagnostics).toEqual([{ event: "fault", fields: { code: "not_configured", detail: null } }]);
  });
});
