/**
 * @jest-environment node
 */
// trackReadable（requirements.md 11.4・30.1。issue #27）。映像トラックのフレームを、ワーカーへ渡せる形（readable）にする。
// Chrome では、MediaStreamTrackProcessor は Window にだけあり、ワーカー内では使えない。MediaStreamTrack も転送できない。
// メインスレッドで processor を作り、その readable（VideoFrame のストリーム）をワーカーへ転送する。
// processor は、readable が使われている間、参照を保つ（呼び出し側が、TrackReadable を持つ）。入力待ちは、最新の 1 枚だけ。
import { PipelineError } from "./errors";
import { createTrackReadable } from "./trackReadable";
import type { TrackProcessorConstructor } from "./trackReadable";
import { FakeVideoTrack } from "./test-support";

function fakeProcessorConstructor(): { constructorLike: TrackProcessorConstructor; inits: Array<{ track: MediaStreamTrack; maxBufferSize?: number }>; readables: ReadableStream<VideoFrame>[] } {
  const inits: Array<{ track: MediaStreamTrack; maxBufferSize?: number }> = [];
  const readables: ReadableStream<VideoFrame>[] = [];
  class FakeProcessor {
    readonly readable: ReadableStream<VideoFrame>;
    constructor(init: { track: MediaStreamTrack; maxBufferSize?: number }) {
      inits.push(init);
      this.readable = new ReadableStream<VideoFrame>();
      readables.push(this.readable);
    }
  }
  return { constructorLike: FakeProcessor, inits, readables };
}

describe("createTrackReadable", () => {
  it("トラックから processor を作り、その readable を返す。入力待ちは最新の 1 枚だけ（maxBufferSize: 1）。processor も返す（参照を保つため）", () => {
    const { constructorLike, inits, readables } = fakeProcessorConstructor();
    const track = new FakeVideoTrack();

    const result = createTrackReadable(track.asTrack(), constructorLike);

    expect(inits).toEqual([{ track, maxBufferSize: 1 }]);
    expect(result.readable).toBe(readables[0]);
    expect(result.processor).toBeDefined();
  });

  it("MediaStreamTrackProcessor が無い実行環境（Firefox など。Node の試験環境も同じ）は、environment_unsupported（別の方法へ黙って切り替えない）", () => {
    expect(() => createTrackReadable(new FakeVideoTrack().asTrack())).toThrow(PipelineError);
    try {
      createTrackReadable(new FakeVideoTrack().asTrack());
    } catch (error) {
      expect((error as PipelineError).code).toBe("environment_unsupported");
    }
  });

  it("processor の作成が失敗したら（終了したトラックなど）source_stream_failed。元のエラーの名前を残す", () => {
    class ThrowingProcessor {
      readonly readable = new ReadableStream<VideoFrame>();
      constructor() {
        throw new TypeError("track ended");
      }
    }

    try {
      createTrackReadable(new FakeVideoTrack().asTrack(), ThrowingProcessor);
      throw new Error("should have thrown");
    } catch (error) {
      expect((error as PipelineError).code).toBe("source_stream_failed");
      expect((error as PipelineError).detail).toBe("TypeError");
    }
  });
});
