// 配信パイプラインのワーカー側（合成・エンコード）のテストの共通部品。テストからだけ使う（実行時のコードから import しない）。
//
// モックの境界: VideoFrame・AudioData・OffscreenCanvas（2D コンテキスト）・VideoEncoder・AudioEncoder・MessagePort・タイマは、すべて疑似。
// 描画は、呼び出し（メソッド名・引数・その時点の fillStyle）を記録するだけで、画素は作らない。エンコーダは、設定・入力・出力のコールバックを記録し、
// 出力は決まった規則（最初の出力に decoderConfig が付く・キーフレームの指定に従う）で作る。
// 画素・実際の H.264 の符号化は、test/ の実ブラウザの確認（実機の Chromium）が受け持つ。AAC は Linux の Chromium では使えないので、疑似でだけ検査する。
import type { MixedAudioBlock } from "@/lib/audio/workletProtocol";

// ---------------------------------------------------------------------------
// 映像フレーム
// ---------------------------------------------------------------------------

/** VideoFrame の疑似。close の回数を数える（解放漏れ・二重の解放の検査）。 */
export class FakeVideoFrame {
  readonly displayWidth: number;
  readonly displayHeight: number;
  timestamp: number;
  /** 画素の出どころ（合成の VideoFrame の場合は、キャンバス） */
  readonly source: unknown;
  /** このフレームが作られた時点での、出どころのキャンバスへの描画呼び出しの数（描きかけを符号化していないことの検査） */
  readonly drawCallsAtCreation: number;
  closeCount = 0;

  constructor(displayWidth: number, displayHeight: number, timestamp = 0, source: unknown = null, drawCallsAtCreation = 0) {
    this.displayWidth = displayWidth;
    this.displayHeight = displayHeight;
    this.timestamp = timestamp;
    this.source = source;
    this.drawCallsAtCreation = drawCallsAtCreation;
  }

  get closed(): boolean {
    return this.closeCount > 0;
  }

  close(): void {
    this.closeCount += 1;
  }
}

/** 作ったフレームをすべて覚える帳簿。「作った数 = 閉じた数 + 保持している数」を検査する。 */
export class FrameLedger {
  readonly frames: FakeVideoFrame[] = [];

  create(width: number, height: number, timestamp = 0): FakeVideoFrame {
    const frame = new FakeVideoFrame(width, height, timestamp);
    this.frames.push(frame);
    return frame;
  }

  get openCount(): number {
    return this.frames.filter((frame) => !frame.closed).length;
  }

  get doubleClosedCount(): number {
    return this.frames.filter((frame) => frame.closeCount > 1).length;
  }
}

// ---------------------------------------------------------------------------
// キャンバス
// ---------------------------------------------------------------------------

export interface RecordedCall {
  readonly method: string;
  readonly args: readonly unknown[];
  /** その呼び出しの時点の fillStyle（fillRect・fill の色の検査） */
  readonly fillStyle: string;
}

/**
 * OffscreenCanvasRenderingContext2D の疑似。実際に使うメソッドだけを持つ（持たないメソッド、たとえば fillText を呼ぶと TypeError になる。
 * 代替スレートに文字を描かないことの検査に使う）。
 */
export class FakeContext2D {
  fillStyle = "";
  failOn: string | null = null;
  readonly calls: RecordedCall[] = [];

  private record(method: string, args: readonly unknown[]): void {
    if (this.failOn === method) {
      throw new DOMException(`fake failure in ${method}`, "InvalidStateError");
    }
    this.calls.push({ method, args, fillStyle: this.fillStyle });
  }

  fillRect(x: number, y: number, width: number, height: number): void {
    this.record("fillRect", [x, y, width, height]);
  }

  save(): void {
    this.record("save", []);
  }

  restore(): void {
    this.record("restore", []);
  }

  beginPath(): void {
    this.record("beginPath", []);
  }

  roundRect(x: number, y: number, width: number, height: number, radius: number): void {
    this.record("roundRect", [x, y, width, height, radius]);
  }

  arc(x: number, y: number, radius: number, startAngle: number, endAngle: number): void {
    this.record("arc", [x, y, radius, startAngle, endAngle]);
  }

  clip(): void {
    this.record("clip", []);
  }

  fill(): void {
    this.record("fill", []);
  }

  drawImage(image: unknown, ...rest: number[]): void {
    this.record("drawImage", [image, ...rest]);
  }

  get methodNames(): string[] {
    return this.calls.map((call) => call.method);
  }
}

/** OffscreenCanvas の疑似。 */
export class FakeCanvas {
  width: number;
  height: number;
  readonly context = new FakeContext2D();
  contextOptions: unknown = undefined;
  returnNullContext = false;

  constructor(width = 0, height = 0) {
    this.width = width;
    this.height = height;
  }

  getContext(contextId: string, options?: unknown): FakeContext2D | null {
    if (contextId !== "2d") {
      return null;
    }
    this.contextOptions = options;
    return this.returnNullContext ? null : this.context;
  }

  asOffscreen(): OffscreenCanvas {
    return this as unknown as OffscreenCanvas;
  }
}

/** 疑似の VideoFrame のコンストラクタを作る（new VideoFrame(canvas, { timestamp }) の疑似）。作ったフレームは created に記録する。 */
function makeVideoFrameConstructor(created: FakeVideoFrame[], control: { failNext: boolean }): typeof VideoFrame {
  function FakeVideoFrameConstructor(this: unknown, source: unknown, init: { timestamp: number }): FakeVideoFrame {
    if (control.failNext) {
      control.failNext = false;
      throw new DOMException("fake failure creating a frame", "InvalidStateError");
    }
    const canvas = source as FakeCanvas;
    const frame = new FakeVideoFrame(canvas.width, canvas.height, init.timestamp, source, canvas.context.calls.length);
    created.push(frame);
    return frame;
  }
  return FakeVideoFrameConstructor as unknown as typeof VideoFrame;
}

/** new VideoFrame(canvas, { timestamp }) の疑似。作ったフレームを記録する。 */
export class FakeVideoFrameFactory {
  readonly created: FakeVideoFrame[] = [];
  private readonly control = { failNext: false };
  readonly constructorLike: typeof VideoFrame = makeVideoFrameConstructor(this.created, this.control);

  /** 真にすると、次の 1 回だけ、フレームの作成が失敗する。 */
  set failNext(value: boolean) {
    this.control.failNext = value;
  }
}

export function asVideoFrame(frame: FakeVideoFrame): VideoFrame {
  return frame as unknown as VideoFrame;
}

// ---------------------------------------------------------------------------
// 音声
// ---------------------------------------------------------------------------

export interface AudioDataInit {
  readonly format: string;
  readonly sampleRate: number;
  readonly numberOfFrames: number;
  readonly numberOfChannels: number;
  readonly timestamp: number;
  readonly data: Float32Array;
}

/** AudioData の疑似。 */
export class FakeAudioData {
  readonly init: AudioDataInit;
  closeCount = 0;

  constructor(init: AudioDataInit) {
    this.init = init;
  }

  get timestamp(): number {
    return this.init.timestamp;
  }

  get numberOfFrames(): number {
    return this.init.numberOfFrames;
  }

  close(): void {
    this.closeCount += 1;
  }
}

/** 疑似の AudioData のコンストラクタを作る。作ったものは created に記録する。 */
function makeAudioDataConstructor(created: FakeAudioData[], control: { failNext: boolean }): typeof AudioData {
  function FakeAudioDataConstructor(this: unknown, init: AudioDataInit): FakeAudioData {
    if (control.failNext) {
      control.failNext = false;
      throw new TypeError("fake failure creating audio data");
    }
    const data = new FakeAudioData(init);
    created.push(data);
    return data;
  }
  return FakeAudioDataConstructor as unknown as typeof AudioData;
}

export class FakeAudioDataFactory {
  readonly created: FakeAudioData[] = [];
  private readonly control = { failNext: false };
  readonly constructorLike: typeof AudioData = makeAudioDataConstructor(this.created, this.control);

  /** 真にすると、次の 1 回だけ、AudioData の作成が失敗する。 */
  set failNext(value: boolean) {
    this.control.failNext = value;
  }
}

/** 混合した音声の 1 ブロック（#26 の MixedAudioBlock。インターリーブの f32）。 */
export function audioBlock(firstSample: number, frames = 128): MixedAudioBlock {
  return { firstSample, frames, pcm: new Float32Array(frames * 2) };
}

// ---------------------------------------------------------------------------
// エンコーダ
// ---------------------------------------------------------------------------

export interface FakeChunkInit {
  readonly type: "key" | "delta";
  readonly timestamp: number;
  readonly bytes: Uint8Array;
}

/** EncodedVideoChunk・EncodedAudioChunk の疑似。 */
export class FakeEncodedChunk {
  readonly type: "key" | "delta";
  readonly timestamp: number;
  readonly byteLength: number;
  private readonly bytes: Uint8Array;

  constructor(init: FakeChunkInit) {
    this.type = init.type;
    this.timestamp = init.timestamp;
    this.bytes = init.bytes;
    this.byteLength = init.bytes.length;
  }

  copyTo(destination: Uint8Array): void {
    destination.set(this.bytes);
  }
}

/** AVCDecoderConfigurationRecord の例（版 1・Main・レベル 3.1）。 */
export const FAKE_AVCC_DESCRIPTION = new Uint8Array([1, 0x4d, 0x40, 0x1f, 0xff, 0xe1, 0x00, 0x04, 0x67, 0x4d, 0x40, 0x1f, 0x01, 0x00, 0x02, 0x68, 0xee]);
/** AudioSpecificConfig の例（AAC-LC・44.1 kHz・2 ch）。 */
export const FAKE_AUDIO_SPECIFIC_CONFIG = new Uint8Array([0x12, 0x10]);

interface EncoderOutputMetadata {
  readonly decoderConfig?: { readonly codec: string; readonly description?: Uint8Array };
}

interface EncoderInit<Chunk> {
  readonly output: (chunk: Chunk, metadata?: EncoderOutputMetadata) => void;
  readonly error: (error: unknown) => void;
}

export interface RecordedVideoEncode {
  readonly timestamp: number;
  readonly keyFrame: boolean;
  readonly frameClosedAtCall: boolean;
}

/**
 * VideoEncoder の疑似。encode のたびに、決まった規則で出力する。
 *   - 出力: キーフレームの指定がある、または configure 後の最初の出力は key。それ以外は delta。バイト列は AVCC 風（先頭 4 バイトが長さ）
 *   - 最初の出力（configure のあと）に、decoderConfig（description）を付ける
 *   - encodeQueueSize は、テストが直接設定できる（入力待ちの積み上がりの疑似）
 *   - holdOutputs を真にすると、出力を溜め、flushOutputs で出す（出力が遅れる実際のエンコーダの疑似）
 *   - dropNextInputs で、内部のフレーム間引き（latencyMode: realtime で起こり得る）を疑似する
 */
export class FakeVideoEncoder {
  static instances: FakeVideoEncoder[] = [];
  /** isConfigSupported が真を返すコーデック文字列。空なら、すべて偽 */
  static supportedCodecs = new Set<string>(["avc1.4D401F", "avc1.42E01F"]);
  static supportedChecks: unknown[] = [];

  state: "unconfigured" | "configured" | "closed" = "unconfigured";
  encodeQueueSize = 0;
  holdOutputs = false;
  dropNextInputs = 0;
  description: Uint8Array | undefined = FAKE_AVCC_DESCRIPTION;
  readonly configureCalls: Record<string, unknown>[] = [];
  readonly encodeCalls: RecordedVideoEncode[] = [];
  closeCalls = 0;
  flushCalls = 0;

  private readonly init: EncoderInit<FakeEncodedChunk>;
  private firstOutputPending = true;
  private currentCodec = "";
  private held: Array<{ chunk: FakeEncodedChunk; metadata?: EncoderOutputMetadata }> = [];

  constructor(init: EncoderInit<FakeEncodedChunk>) {
    this.init = init;
    FakeVideoEncoder.instances.push(this);
  }

  static reset(): void {
    FakeVideoEncoder.instances = [];
    FakeVideoEncoder.supportedCodecs = new Set(["avc1.4D401F", "avc1.42E01F"]);
    FakeVideoEncoder.supportedChecks = [];
  }

  static isConfigSupported(config: { codec: string }): Promise<{ supported: boolean; config: unknown }> {
    FakeVideoEncoder.supportedChecks.push(config);
    return Promise.resolve({ supported: FakeVideoEncoder.supportedCodecs.has(config.codec), config });
  }

  static asConstructor(): typeof VideoEncoder {
    return FakeVideoEncoder as unknown as typeof VideoEncoder;
  }

  configure(config: Record<string, unknown>): void {
    if (this.state === "closed") {
      throw new DOMException("closed", "InvalidStateError");
    }
    this.state = "configured";
    this.currentCodec = String(config.codec);
    this.configureCalls.push(config);
    this.firstOutputPending = true;
  }

  encode(frame: FakeVideoFrame, options?: { keyFrame?: boolean }): void {
    if (this.state !== "configured") {
      throw new DOMException("not configured", "InvalidStateError");
    }
    this.encodeCalls.push({ timestamp: frame.timestamp, keyFrame: options?.keyFrame === true, frameClosedAtCall: frame.closed });
    if (this.dropNextInputs > 0) {
      this.dropNextInputs -= 1;
      return;
    }
    const isKey = options?.keyFrame === true || this.firstOutputPending;
    const bytes = new Uint8Array(isKey ? 12 : 8);
    bytes[3] = bytes.length - 4;
    const chunk = new FakeEncodedChunk({ type: isKey ? "key" : "delta", timestamp: frame.timestamp, bytes });
    const metadata: EncoderOutputMetadata | undefined = this.firstOutputPending
      ? { decoderConfig: { codec: this.currentCodec, ...(this.description === undefined ? {} : { description: this.description }) } }
      : undefined;
    this.firstOutputPending = false;
    if (this.holdOutputs) {
      this.held.push({ chunk, metadata });
      return;
    }
    this.init.output(chunk, metadata);
  }

  /** 溜めた出力を、すべて出す。 */
  flushOutputs(): void {
    const pending = this.held;
    this.held = [];
    for (const entry of pending) {
      this.init.output(entry.chunk, entry.metadata);
    }
  }

  flush(): Promise<void> {
    this.flushCalls += 1;
    this.flushOutputs();
    return Promise.resolve();
  }

  close(): void {
    this.closeCalls += 1;
    this.state = "closed";
  }

  /** エンコーダの error コールバックを起こす（エンコーダは、以後 closed）。 */
  fail(error: unknown): void {
    this.state = "closed";
    this.init.error(error);
  }
}

/**
 * AudioEncoder の疑似。AudioData を受けて、1,024 サンプルがたまるたびに、出力を 1 つ出す（AAC-LC のフレームの長さ）。
 * 最初の出力に decoderConfig（AudioSpecificConfig）を付ける。出力の時刻は、わざと実際の値と違う値（入力の時刻に 1 を足す）にして、
 * パイプラインが、エンコーダの時刻に頼らず、累積サンプル数から時刻を付けることを検査できるようにする。
 */
export class FakeAudioEncoder {
  static instances: FakeAudioEncoder[] = [];
  static aacSupported = true;
  static supportedChecks: unknown[] = [];

  state: "unconfigured" | "configured" | "closed" = "unconfigured";
  description: Uint8Array | undefined = FAKE_AUDIO_SPECIFIC_CONFIG;
  readonly configureCalls: Record<string, unknown>[] = [];
  readonly encodedTimestamps: number[] = [];
  closeCalls = 0;

  private readonly init: EncoderInit<FakeEncodedChunk>;
  private firstOutputPending = true;
  private bufferedSamples = 0;

  constructor(init: EncoderInit<FakeEncodedChunk>) {
    this.init = init;
    FakeAudioEncoder.instances.push(this);
  }

  static reset(): void {
    FakeAudioEncoder.instances = [];
    FakeAudioEncoder.aacSupported = true;
    FakeAudioEncoder.supportedChecks = [];
  }

  static isConfigSupported(config: unknown): Promise<{ supported: boolean; config: unknown }> {
    FakeAudioEncoder.supportedChecks.push(config);
    return Promise.resolve({ supported: FakeAudioEncoder.aacSupported, config });
  }

  static asConstructor(): typeof AudioEncoder {
    return FakeAudioEncoder as unknown as typeof AudioEncoder;
  }

  configure(config: Record<string, unknown>): void {
    if (this.state === "closed") {
      throw new DOMException("closed", "InvalidStateError");
    }
    this.state = "configured";
    this.configureCalls.push(config);
    this.firstOutputPending = true;
  }

  encode(data: FakeAudioData): void {
    if (this.state !== "configured") {
      throw new DOMException("not configured", "InvalidStateError");
    }
    this.encodedTimestamps.push(data.timestamp);
    this.bufferedSamples += data.numberOfFrames;
    while (this.bufferedSamples >= 1024) {
      this.bufferedSamples -= 1024;
      const chunk = new FakeEncodedChunk({ type: "key", timestamp: data.timestamp + 1, bytes: new Uint8Array([0x21, 0x10, 0x04]) });
      const metadata: EncoderOutputMetadata | undefined = this.firstOutputPending
        ? { decoderConfig: { codec: "mp4a.40.2", ...(this.description === undefined ? {} : { description: this.description }) } }
        : undefined;
      this.firstOutputPending = false;
      this.init.output(chunk, metadata);
    }
  }

  flush(): Promise<void> {
    return Promise.resolve();
  }

  close(): void {
    this.closeCalls += 1;
    this.state = "closed";
  }

  fail(error: unknown): void {
    this.state = "closed";
    this.init.error(error);
  }
}

// ---------------------------------------------------------------------------
// タイマ・ポート
// ---------------------------------------------------------------------------

/** 手動で進めるタイマ。setInterval・setTimeout を疑似する（実時間を待たない）。 */
export class FakeScheduler {
  private nextHandle = 1;
  private readonly timers = new Map<number, { readonly callback: () => void; readonly intervalMs: number; due: number; readonly repeat: boolean }>();
  private now = 0;
  readonly intervalsStarted: number[] = [];
  clearedCount = 0;

  setInterval = (callback: () => void, intervalMs: number): unknown => {
    const handle = this.nextHandle++;
    this.timers.set(handle, { callback, intervalMs, due: this.now + intervalMs, repeat: true });
    this.intervalsStarted.push(intervalMs);
    return handle;
  };

  clearInterval = (handle: unknown): void => {
    if (this.timers.delete(handle as number)) {
      this.clearedCount += 1;
    }
  };

  setTimeout = (callback: () => void, delayMs: number): unknown => {
    const handle = this.nextHandle++;
    this.timers.set(handle, { callback, intervalMs: delayMs, due: this.now + delayMs, repeat: false });
    return handle;
  };

  clearTimeout = (handle: unknown): void => {
    if (this.timers.delete(handle as number)) {
      this.clearedCount += 1;
    }
  };

  get activeCount(): number {
    return this.timers.size;
  }

  get activeIntervalCount(): number {
    return Array.from(this.timers.values()).filter((timer) => timer.repeat).length;
  }

  /** 時刻を ms だけ進め、期限の来たタイマを、期限の順に実行する。 */
  advance(ms: number): void {
    const target = this.now + ms;
    for (;;) {
      let nextHandleToRun: number | null = null;
      let nextDue = Number.POSITIVE_INFINITY;
      for (const [handle, timer] of this.timers) {
        if (timer.due <= target && timer.due < nextDue) {
          nextDue = timer.due;
          nextHandleToRun = handle;
        }
      }
      if (nextHandleToRun === null) {
        break;
      }
      const timer = this.timers.get(nextHandleToRun);
      if (timer === undefined) {
        break;
      }
      this.now = timer.due;
      if (timer.repeat) {
        timer.due += timer.intervalMs;
      } else {
        this.timers.delete(nextHandleToRun);
      }
      timer.callback();
    }
    this.now = target;
  }
}

/** MessagePort の疑似（同期。メッセージの受信は receive で疑似する）。 */
export class FakePort {
  onmessage: ((event: { data: unknown; timeStamp?: number }) => void) | null = null;
  closeCount = 0;
  readonly posted: Array<{ data: unknown; transfer: readonly unknown[] }> = [];

  postMessage(data: unknown, transfer: readonly unknown[] = []): void {
    this.posted.push({ data, transfer });
  }

  /** メッセージの受信を疑似する。timeStamp は、イベントの timeStamp（受け取った側の時刻。ミリ秒）。省くと、時刻の無いイベント。 */
  receive(data: unknown, timeStamp?: number): void {
    this.onmessage?.(timeStamp === undefined ? { data } : { data, timeStamp });
  }

  close(): void {
    this.closeCount += 1;
    this.onmessage = null;
  }

  asMessagePort(): MessagePort {
    return this as unknown as MessagePort;
  }
}
