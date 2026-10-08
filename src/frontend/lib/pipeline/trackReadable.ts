// trackReadable（requirements.md 11.4・30.1。issue #27）。映像トラックのフレームを、ワーカーへ渡せる形（readable）にする。
//
//   Chrome では、MediaStreamTrackProcessor は Window にだけあり、ワーカー内では使えない。MediaStreamTrack も転送できない（DataCloneError）。
//   そこで、メインスレッドで processor を作り、その readable（VideoFrame のストリーム）をワーカーへ転送する。
//   Chromium は readable の転送を最適化しており、フレームは、メインスレッドを経由せず、ワーカーへ直接届く。
//   （WORK/factcheck/20261007_external-facts.md の項目 12。実測は test/ の実ブラウザの確認）
//   入力待ちは、最新の 1 枚だけ（maxBufferSize: 1）。古いフレームを溜めない。processor は、readable が使われている間、参照を保つ
//   （呼び出し側が、返した値を持つ）。

import { PipelineError } from "./errors";
import { TRACK_PROCESSOR_MAX_BUFFER_SIZE } from "./config";

/** MediaStreamTrackProcessor のコンストラクタ（Window にだけある）。TypeScript の DOM 型には、まだ無い。 */
export type TrackProcessorConstructor = new (init: { track: MediaStreamTrack; maxBufferSize?: number }) => { readonly readable: ReadableStream<VideoFrame> };

export interface TrackReadable {
  /** ワーカーへ転送する、VideoFrame のストリーム */
  readonly readable: ReadableStream<VideoFrame>;
  /** processor。readable が使われている間、参照を保つ（手放すと、ストリームが止まり得る） */
  readonly processor: unknown;
}

function globalProcessorConstructor(): TrackProcessorConstructor | undefined {
  return (globalThis as { MediaStreamTrackProcessor?: TrackProcessorConstructor }).MediaStreamTrackProcessor;
}

/**
 * 映像トラックから readable を作る。MediaStreamTrackProcessor が無い実行環境は environment_unsupported（能力検出（#24）で開始を提供しない環境）。
 * processor の作成が失敗したら（終了したトラックなど）source_stream_failed。
 */
export function createTrackReadable(track: MediaStreamTrack, constructorLike: TrackProcessorConstructor | undefined = globalProcessorConstructor()): TrackReadable {
  if (constructorLike === undefined) {
    throw new PipelineError("environment_unsupported");
  }
  try {
    const processor = new constructorLike({ track, maxBufferSize: TRACK_PROCESSOR_MAX_BUFFER_SIZE });
    return { readable: processor.readable, processor };
  } catch (error) {
    throw new PipelineError("source_stream_failed", error);
  }
}
