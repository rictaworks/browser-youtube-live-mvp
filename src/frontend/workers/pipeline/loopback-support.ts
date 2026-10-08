// クライアント（PipelineClient）と、ワーカーの入り口（startPipelineWorker + PipelineHost）を、メモリの中でつなぐ試験の道具（issue #27）。
// テストからだけ使う（実行時のコードから import しない）。
//
// 両側とも、実際のコード（PipelineClient・startPipelineWorker・PipelineHost・メッセージの検証）を使う。疑似にするのは、ブラウザが与えるものだけ:
// Worker（メッセージを、マイクロタスクで渡す）・WebCodecs のエンコーダ・OffscreenCanvas・VideoFrame・AudioData・タイマ・MessagePort・
// MediaStreamTrackProcessor の readable。メッセージは構造化複製しない（参照のまま渡す）。複製・転送の振る舞いは、test/ の実ブラウザの確認が受け持つ。
import type { PipelineWorkerLike } from "@/lib/pipeline/PipelineClient";
import type { TrackReadable } from "@/lib/pipeline/trackReadable";
import { startPipelineWorker } from "./startWorker";
import type { PipelineWorkerScope } from "./startWorker";
import type { PipelineHost } from "./PipelineHost";
import { silentPcm } from "./host-support";
import { FakeAudioDataFactory, FakeAudioEncoder, FakeCanvas, FakePort, FakeScheduler, FakeVideoEncoder, FakeVideoFrameFactory, FrameLedger } from "./test-support";
import type { FakeVideoFrame } from "./test-support";

export interface LoopbackSource {
  readonly controller: ReadableStreamDefaultController<FakeVideoFrame>;
  readonly ledger: FrameLedger;
  cancelled: boolean;
}

/** クライアントから見た Worker。ワーカーの大域（scope）へ、メッセージを渡し、ワーカーからのメッセージを、クライアントへ渡す。 */
export class LoopbackWorker implements PipelineWorkerLike {
  onmessage: ((event: MessageEvent) => void) | null = null;
  onerror: ((event: ErrorEvent) => void) | null = null;
  onmessageerror: ((event: MessageEvent) => void) | null = null;
  readonly scheduler = new FakeScheduler();
  readonly canvases: FakeCanvas[] = [];
  readonly videoFrames = new FakeVideoFrameFactory();
  /** クライアントがワーカーへ送ったメッセージ（種類の順） */
  readonly fromClient: Array<{ readonly message: { readonly type?: string }; readonly transfer: readonly unknown[] }> = [];
  /** ワーカーがクライアントへ送ったメッセージ（種類の順） */
  readonly toClient: Array<{ readonly type?: string; readonly [key: string]: unknown }> = [];
  terminateCount = 0;
  closeCount = 0;
  host: PipelineHost | null = null;
  readonly scope: PipelineWorkerScope;

  constructor() {
    FakeVideoEncoder.reset();
    FakeAudioEncoder.reset();
    const canvases = this.canvases;
    function OffscreenCanvasConstructor(this: unknown, width: number, height: number): FakeCanvas {
      const canvas = new FakeCanvas(width, height);
      canvases.push(canvas);
      return canvas;
    }
    this.scope = {
      VideoEncoder: FakeVideoEncoder,
      AudioEncoder: FakeAudioEncoder,
      VideoFrame: this.videoFrames.constructorLike,
      AudioData: new FakeAudioDataFactory().constructorLike,
      OffscreenCanvas: OffscreenCanvasConstructor,
      setInterval: this.scheduler.setInterval,
      clearInterval: this.scheduler.clearInterval,
      setTimeout: this.scheduler.setTimeout,
      clearTimeout: this.scheduler.clearTimeout,
      postMessage: (message: unknown) => {
        this.toClient.push(message as { type?: string });
        queueMicrotask(() => this.onmessage?.({ data: message } as MessageEvent));
      },
      onmessage: null,
      close: () => {
        this.closeCount += 1;
      },
    } as unknown as PipelineWorkerScope;
  }

  /** ワーカーのスクリプトを走らせる（ready を知らせる）。本物のワーカーも、生成の直後ではなく、少しあとに ready を知らせる。 */
  boot(): void {
    this.host = startPipelineWorker(this.scope, { diagnostic: () => undefined });
  }

  postMessage(message: unknown, transfer: Transferable[]): void {
    this.fromClient.push({ message: message as { type?: string }, transfer });
    queueMicrotask(() => this.scope.onmessage?.({ data: message } as MessageEvent));
  }

  terminate(): void {
    this.terminateCount += 1;
  }

  /** ワーカーの未処理の例外（異常終了）を疑似する。 */
  crash(): void {
    this.onerror?.({ message: "Uncaught Error: secret detail at https://example.invalid/x" } as ErrorEvent);
  }

  /** クライアントがワーカーへ送ったメッセージのうち、種類が type のもの。 */
  commands(type: string): Array<{ readonly message: { readonly type?: string }; readonly transfer: readonly unknown[] }> {
    return this.fromClient.filter((entry) => entry.message.type === type);
  }

  eventsToClient(type: string): Array<{ readonly type?: string; readonly [key: string]: unknown }> {
    return this.toClient.filter((event) => event.type === type);
  }
}

/** ワーカーと、メインスレッド側が渡す部品（映像トラックの readable・音声のポート）を束ねる。 */
export class Loopback {
  readonly previewCanvas = new FakeCanvas(1280, 720);
  readonly sources = new Map<unknown, LoopbackSource>();
  audioPort: FakePort | null = null;
  private created: LoopbackWorker | null = null;
  private nextSample = 0;

  /** PipelineClientOptions.createWorker に渡す。ワーカーは、start のときに作る（ready は、クライアントが onmessage を設定したあとに届く）。 */
  readonly createWorker = (): PipelineWorkerLike => {
    const worker = new LoopbackWorker();
    this.created = worker;
    queueMicrotask(() => worker.boot());
    return worker;
  };

  get worker(): LoopbackWorker {
    if (this.created === null) {
      throw new Error("the worker has not been created yet (call client.start() first)");
    }
    return this.created;
  }

  /** PipelineClientOptions.createTrackReadable に渡す。トラックごとに、フレームを流せるストリームを作る。 */
  readonly createTrackReadable = (track: MediaStreamTrack): TrackReadable => {
    const holder: { controller: ReadableStreamDefaultController<FakeVideoFrame> | null; cancelled: boolean } = { controller: null, cancelled: false };
    const readable = new ReadableStream<FakeVideoFrame>({
      start: (controller) => {
        holder.controller = controller;
      },
      cancel: () => {
        holder.cancelled = true;
      },
    });
    if (holder.controller === null) {
      throw new Error("the stream controller was not captured");
    }
    const source: LoopbackSource = {
      controller: holder.controller,
      ledger: new FrameLedger(),
      get cancelled() {
        return holder.cancelled;
      },
      set cancelled(value: boolean) {
        holder.cancelled = value;
      },
    };
    this.sources.set(track, source);
    return { readable: readable as unknown as ReadableStream<VideoFrame>, processor: { track } };
  };

  /** PipelineClientOptions.createMessageChannel に渡す。ワーカーへ渡すポートは FakePort（audioPort）。 */
  readonly createMessageChannel = (): MessageChannel => {
    const port = new FakePort();
    this.audioPort = port;
    return { port1: port.asMessagePort(), port2: { close: () => undefined } as unknown as MessagePort } as unknown as MessageChannel;
  };

  /** プレビュー用の <canvas> の疑似（PipelineClient.attachPreview に渡す）。 */
  get previewSource(): { transferControlToOffscreen(): OffscreenCanvas } {
    return { transferControlToOffscreen: () => this.previewCanvas.asOffscreen() };
  }

  /** トラックの映像ソースへ、1 フレームを流す。 */
  feedFrame(track: unknown, width = 640, height = 480): FakeVideoFrame {
    const source = this.sources.get(track);
    if (source === undefined) {
      throw new Error("the track was not added to the pipeline");
    }
    const frame = source.ledger.create(width, height);
    source.controller.enqueue(frame);
    return frame;
  }

  /** 接続した音声のポートへ、連続したブロック（128 サンプル）を seconds 秒分、送る。累積サンプル数は、続けて数える。 */
  feedAudioSeconds(seconds: number): void {
    const port = this.audioPort;
    if (port === null) {
      throw new Error("openAudioSink() first");
    }
    const target = this.nextSample + Math.round(seconds * 44_100);
    while (this.nextSample + 128 <= target) {
      port.receive({ type: "block", firstSample: this.nextSample, frames: 128, pcm: silentPcm(128) });
      this.nextSample += 128;
    }
  }

  get audioSamples(): number {
    return this.nextSample;
  }
}
