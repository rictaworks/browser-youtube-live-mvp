// PipelineHost の試験の道具。ホストを疑似の環境で動かし、メインスレッドの役（コマンドの送信・音声のブロックの送信・応答の受信）を、テストが演じる。
// テストからだけ使う（実行時のコードから import しない）。疑似の部品は test-support.ts。
import { PipelineHost } from "./PipelineHost";
import type { PipelineEnvironment } from "./environment";
import type { PipelineEvent } from "./messages";
import {
  FakeAudioDataFactory,
  FakeAudioEncoder,
  FakeCanvas,
  FakePort,
  FakeScheduler,
  FakeVideoEncoder,
  FakeVideoFrameFactory,
  FrameLedger,
} from "./test-support";
import type { FakeVideoFrame } from "./test-support";


/** 非同期の処理（Promise・ストリームの読み取り）が進むのを待つ。 */
export async function settle(): Promise<void> {
  for (let index = 0; index < 6; index += 1) {
    await new Promise<void>((resolve) => setImmediate(resolve));
  }
}

const silentBlocks = new Map<number, Float32Array>();

/** 無音の PCM（サンプル数ごとに 1 つを共有する）。 */
export function silentPcm(frames: number): Float32Array {
  const existing = silentBlocks.get(frames);
  if (existing !== undefined) {
    return existing;
  }
  const created = new Float32Array(frames * 2);
  silentBlocks.set(frames, created);
  return created;
}

export interface FakeSource {
  readonly controller: ReadableStreamDefaultController<FakeVideoFrame>;
  readonly ledger: FrameLedger;
  readonly readable: ReadableStream<FakeVideoFrame>;
  cancelled: boolean;
}

/** ホストを、疑似の環境で動かし、メインスレッドの役（コマンドの送信・音声のブロックの送信・応答の受信）を演じる。 */
export class HostHarness {
  readonly events: PipelineEvent[] = [];
  readonly scheduler = new FakeScheduler();
  readonly canvases: FakeCanvas[] = [];
  readonly videoFrames = new FakeVideoFrameFactory();
  readonly audioData = new FakeAudioDataFactory();
  readonly diagnostics: Array<{ event: string; fields: Record<string, unknown> }> = [];
  readonly host: PipelineHost;
  private port: FakePort | null = null;
  private nextSample = 0;
  private nextRequestId = 1;
  private eventClockMs = 1000;
  /** configureAndPrime が、設定の完了を待ったあと、最初のブロックを送る直前の累積サンプル数（符号化の起点） */
  primeStartSample = 0;

  constructor() {
    FakeVideoEncoder.reset();
    FakeAudioEncoder.reset();
    const environment: PipelineEnvironment = {
      VideoEncoder: FakeVideoEncoder.asConstructor(),
      AudioEncoder: FakeAudioEncoder.asConstructor(),
      VideoFrame: this.videoFrames.constructorLike,
      AudioData: this.audioData.constructorLike,
      createCanvas: (width, height) => {
        const canvas = new FakeCanvas(width, height);
        this.canvases.push(canvas);
        return canvas.asOffscreen();
      },
      scheduler: this.scheduler,
    };
    this.host = new PipelineHost({
      environment,
      post: (event) => {
        this.events.push(event);
      },
      diagnostic: (event, fields) => {
        this.diagnostics.push({ event, fields: { ...fields } });
      },
    });
  }

  /** 最後に作られた合成用のキャンバス。 */
  get compositeCanvas(): FakeCanvas {
    return this.canvases[this.canvases.length - 1];
  }

  send(command: Record<string, unknown>): void {
    this.host.handle(command);
  }

  eventsOf<T extends PipelineEvent["type"]>(type: T): Array<Extract<PipelineEvent, { type: T }>> {
    return this.events.filter((event): event is Extract<PipelineEvent, { type: T }> => event.type === type);
  }

  faultCodes(): string[] {
    return this.eventsOf("fault").map((event) => event.fault.code);
  }

  /** プレビュー用のキャンバスを渡す。 */
  attachPreview(width = 300, height = 150): FakeCanvas {
    const preview = new FakeCanvas(width, height);
    this.send({ type: "attach_preview", canvas: preview.asOffscreen() });
    return preview;
  }

  /** 映像ソースを追加する（メインスレッドが転送した readable の役）。フレームは controller.enqueue で送る。 */
  addSource(kind: "screen" | "camera"): FakeSource {
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
    const source: FakeSource = {
      controller: holder.controller,
      ledger: new FrameLedger(),
      readable,
      get cancelled() {
        return holder.cancelled;
      },
      set cancelled(value: boolean) {
        holder.cancelled = value;
      },
    };
    this.send({ type: "add_source", kind, readable });
    return source;
  }

  /** 音声のポートを接続する（#26 のミキサーが、ワーカーへブロックを直接送る役）。音声の累積サンプル数は、0 から数える。 */
  connectAudio(): FakePort {
    const port = new FakePort();
    this.send({ type: "connect_audio", port: port.asMessagePort() });
    this.port = port;
    this.nextSample = 0;
    return port;
  }

  /**
   * 接続した音声のポートへ、連続したブロックを count 個送る。timing は、イベントの timeStamp の付け方:
   *   none    付けない（遅れの検知は働かない。既定）
   *   steady  ブロックの周期どおり（128 サンプルなら約 2.9 ミリ秒ごと）
   *   burst   周期の 1/30 の間隔（ワーカーが遅れて、積み上がった分を続けて処理する状態）
   */
  feedBlocks(count: number, frames = 128, timing: "none" | "steady" | "burst" = "none"): void {
    const port = this.port;
    if (port === null) {
      throw new Error("connectAudio() first");
    }
    const periodMs = (frames * 1000) / 44_100;
    for (let index = 0; index < count; index += 1) {
      if (timing === "steady") {
        this.eventClockMs += periodMs;
      } else if (timing === "burst") {
        this.eventClockMs += periodMs / 30;
      }
      port.receive({ type: "block", firstSample: this.nextSample, frames, pcm: silentPcm(frames) }, timing === "none" ? undefined : this.eventClockMs);
      this.nextSample += frames;
    }
  }

  /** 音声のイベントの時刻を、ms だけ進める（塊の間の、待ちの空きの疑似）。 */
  advanceEventClock(milliseconds: number): void {
    this.eventClockMs += milliseconds;
  }

  /** 音声を seconds 秒分（128 サンプルのブロック）送る。1 秒 = 44,100 サンプル。 */
  feedSeconds(seconds: number): void {
    const target = this.nextSample + Math.round(seconds * 44_100);
    while (this.nextSample + 128 <= target) {
      this.feedBlocks(1);
    }
  }

  get audioSamples(): number {
    return this.nextSample;
  }

  /** 応答のある要求を送る。応答は、非同期に、events に現れる。requestId を返す。 */
  request(type: string, extra: Record<string, unknown> = {}): number {
    const requestId = this.nextRequestId++;
    this.send({ type, requestId, ...extra });
    return requestId;
  }

  /** 要求の応答を、現れるまで待って返す。 */
  async replyTo(requestId: number): Promise<Extract<PipelineEvent, { type: "reply" }>> {
    for (let attempt = 0; attempt < 20; attempt += 1) {
      const found = this.eventsOf("reply").find((event) => event.requestId === requestId);
      if (found !== undefined) {
        return found;
      }
      await settle();
    }
    throw new Error(`no reply to request ${requestId}`);
  }

  /**
   * 設定を送り、音声のブロックと映像を流して、最初の出力（復号器設定）を得させ、応答を受け取る。
   * 音声のポートが接続されていなければ、接続する。映像ソースは、呼び出し側が先に追加しておく（無ければ代替スレート）。
   */
  async configureAndPrime(profile: "720p" | "480p" = "720p", videoCodec = "avc1.4D401F", videoBitrateKbps = 4500): Promise<Extract<PipelineEvent, { type: "reply" }>> {
    if (this.port === null) {
      this.connectAudio();
    }
    const requestId = this.request("configure", { profile, videoCodec, videoBitrateKbps });
    await settle();
    this.primeStartSample = this.nextSample;
    this.feedSeconds(0.3);
    return this.replyTo(requestId);
  }
}
