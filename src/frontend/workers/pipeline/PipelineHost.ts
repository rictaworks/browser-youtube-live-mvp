// PipelineHost（requirements.md 11.2〜11.7・12・13.1・27・30.1。issue #27）。配信パイプラインのワーカーの本体。
// 映像の合成（VideoCompositor）と H.264／AAC のエンコード（VideoEncoderPipeline・AudioEncoderPipeline）を、ワーカーの上で行う。
// 合成とエンコードは、画面の描画周期に依存せず、タブが非表示・最小化されても続く（メインスレッドのタイマ・requestAnimationFrame を使わない）。
//
// 駆動（重要な区別）
//   配信中    #26 のミキサーが送る音声の処理周期（累積サンプル数）が、駆動源。MediaClock が決めるフレーム番号ごとに 1 枚を合成し、符号化する
//             （映像 1 フレーム = 音声 1,470 サンプル）。ワーカーのタイマは使わない。時刻は、累積サンプル数から算出する（実時計で採番しない）
//   配信前    音声のクロックが無いので、ワーカーのタイマ（PreviewTicker）で 30 fps を駆動して、プレビューだけを描く。符号化しない。
//             配信の送出には使わない
// 音声が止まったとき（AudioContext の停止）は合成も止まり、再開時は、空白を埋めずに、キーフレームから再開する（MediaClock）。
//
// プレビュー  合成した 1 枚のキャンバスを、そのまま 1:1 で、プレビュー用の canvas（メインスレッドから転送された OffscreenCanvas）へ写す。
//             符号化へ渡す VideoFrame も、同じキャンバスの写しなので、プレビューは、実際に送出するものと同一の構図
// 映像ソース  メインスレッドが MediaStreamTrackProcessor を作り、その readable を転送する（Chrome では、ワーカー内で processor は使えず、
//             MediaStreamTrack も転送できない）。ワーカーで読み、各ソース最新の 1 枚だけを保持する（FrameStore。古いフレームは直ちに閉じる）
// 設定        configure でエンコーダを設定し、最初の出力（復号器設定 description）を得て返す。音声のクロックが動いていないと得られない（priming_timeout）
// 受け渡し    符号化結果は、送出の開始（begin_delivery）まで渡さない（エンコーダは動かし続ける）。開始・復帰では、映像はキーフレームから、音声はすぐ渡す
// エラー      例外は、ワーカーの未処理の例外にせず、型付きの故障として知らせる（メインスレッドで「ワーカーの異常終了」に見えるため）。
//             同じ原因の繰り返し（毎フレームの合成の失敗）は、1 回だけ知らせる。符号と、元のエラーの名前だけを載せる（機密・デバイス名を載せない）
// 解放        end_session でエンコーダ・音声のポートを閉じ、shutdown ですべて（フレーム・ソースの読み取り・プレビュー・タイマ）を解放する

import { MediaClock } from "@/core/clock";
import { LIMITS } from "@/core/contract";
import type { Layout, Profile } from "@/core/contract";
import type { VideoCodec } from "@/core/transport";
import { AudioClockDriver } from "@/lib/audio/AudioClockDriver";
import type { AudioTick } from "@/lib/audio/AudioClockDriver";
import { AudioContinuityError, WorkletProtocolError } from "@/lib/audio/errors";
import { parseWorkletMessage } from "@/lib/audio/workletProtocol";
import type { MixedAudioBlock } from "@/lib/audio/workletProtocol";
import type { EncodedChunk } from "@/lib/pipeline/chunks";
import { DECODER_CONFIG_TIMEOUT_MS, PREVIEW_PROFILE } from "@/lib/pipeline/config";
import { PipelineError, faultOf } from "@/lib/pipeline/errors";
import type { PipelineFault } from "@/lib/pipeline/errors";
import { NO_DIAGNOSTICS } from "@/lib/sources/diagnostics";
import type { DiagnosticSink } from "@/lib/sources/diagnostics";
import { AudioEncoderPipeline } from "./AudioEncoderPipeline";
import { ChunkGate } from "./ChunkGate";
import { FrameStore } from "./FrameStore";
import { LagGuard } from "./LagGuard";
import type { VideoSourceKind } from "./FrameStore";
import { PreviewSurface } from "./PreviewSurface";
import { PreviewTicker } from "./PreviewTicker";
import { SourcePump } from "./SourcePump";
import { VideoCompositor } from "./VideoCompositor";
import { VideoEncoderPipeline } from "./VideoEncoderPipeline";
import type { PipelineEnvironment } from "./environment";
import { parseCommand } from "./messages";
import type { PipelineCommand, PipelineEvent, PipelineStats, ReplyResult } from "./messages";

export interface PipelineHostOptions {
  readonly environment: PipelineEnvironment;
  /** ワーカー -> メインスレッド。転送対象（ArrayBuffer）の扱いは、呼び出し側（ワーカーの入り口）が、prepareEventForPost で行う */
  readonly post: (event: PipelineEvent) => void;
  /** 診断（ログ）の出力先。符号と、元のエラーの名前だけを出す。既定は、何も出さない */
  readonly diagnostic?: DiagnosticSink;
}

/** 配信 1 本分の、エンコーダなどの組。 */
interface Session {
  readonly profile: Profile;
  readonly codec: VideoCodec;
  readonly video: VideoEncoderPipeline;
  readonly audio: AudioEncoderPipeline;
  readonly gate: ChunkGate;
  /** 両方のエンコーダを設定し終えた。これ以降、音声のブロックと、合成したフレームを、エンコーダへ渡す */
  active: boolean;
}

const COMPOSE_FAILED = "compose_failed";

function requestIdOf(data: unknown): number | null {
  if (typeof data !== "object" || data === null) {
    return null;
  }
  const value = (data as Record<string, unknown>).requestId;
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 1 ? value : null;
}

export class PipelineHost {
  private readonly environment: PipelineEnvironment;
  private readonly post: (event: PipelineEvent) => void;
  private readonly diagnostic: DiagnosticSink;

  private readonly frames = new FrameStore<VideoFrame>();
  private readonly pumps = new Map<VideoSourceKind, SourcePump>();
  private readonly preview = new PreviewSurface();
  private readonly ticker: PreviewTicker;
  private compositor: VideoCompositor;

  private session: Session | null = null;
  private sessionGeneration = 0;

  private clock: MediaClock | null = null;
  private driver: AudioClockDriver | null = null;
  private audioPort: MessagePort | null = null;
  /** ブロックの累積サンプル数が連続しなくなった。時刻の基準が崩れたので、以後のブロックを取り込まない（end_session まで） */
  private audioBroken = false;

  /** ブロックの処理が積み上がっている（ワーカーが遅れている）ことの検知。遅れている間は、合成を飛ばす */
  private readonly lagGuard = new LagGuard();
  private behind = false;
  private skippedForLag = 0;

  private lastLayout: Layout | null = null;
  private composedFrames = 0;
  private composeFailures = 0;
  private deliveredVideoChunks = 0;
  private deliveredAudioChunks = 0;
  /** 知らせ済みで、まだ回復していない故障の符号。同じ原因の繰り返しを、1 回だけ知らせるため */
  private readonly activeFaults = new Set<string>();
  private disposed = false;

  constructor(options: PipelineHostOptions) {
    this.environment = options.environment;
    this.post = options.post;
    this.diagnostic = options.diagnostic ?? NO_DIAGNOSTICS;
    this.ticker = new PreviewTicker(this.environment.scheduler, (error) => this.reportFault(faultOf(error)));
    this.compositor = this.createCompositor(PREVIEW_PROFILE);
  }

  /** dispose 済み（shutdown を受けた）。 */
  get isDisposed(): boolean {
    return this.disposed;
  }

  // ---------------------------------------------------------------------------
  // メッセージの入り口
  // ---------------------------------------------------------------------------

  /** メインスレッドから届いた 1 メッセージを処理する。例外は投げない（故障として知らせる）。終了後は何もしない。 */
  handle(data: unknown): void {
    if (this.disposed) {
      return;
    }
    let command: PipelineCommand;
    try {
      command = parseCommand(data);
    } catch (error) {
      this.rejectInvalid(data, error);
      return;
    }
    try {
      this.dispatch(command);
    } catch (error) {
      this.reportFault(faultOf(error));
    }
  }

  /** すべての資源を解放する。以後のメッセージを受け付けない。何度呼んでもよい。 */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.endSession();
    for (const pump of this.pumps.values()) {
      void pump.stop();
    }
    this.pumps.clear();
    this.ticker.stop();
    this.preview.detach();
    try {
      this.frames.dispose();
    } catch (error) {
      this.diagnostic("frame_release_failed", { detail: faultOf(error).detail });
    }
    this.diagnostic("disposed", {});
  }

  private dispatch(command: PipelineCommand): void {
    switch (command.type) {
      case "attach_preview":
        this.preview.attach(command.canvas);
        this.refreshTicker();
        return;
      case "detach_preview":
        this.preview.detach();
        this.refreshTicker();
        return;
      case "add_source":
        this.addSource(command.kind, command.readable);
        return;
      case "remove_source":
        this.removeSource(command.kind);
        return;
      case "configure":
        this.respond(command.requestId, () => this.configure(command.profile, command.videoCodec, command.videoBitrateKbps));
        return;
      case "connect_audio":
        this.connectAudio(command.port);
        return;
      case "audio_stalled":
        this.driver?.onStall();
        // 停止の間は、ブロックが届かないまま、実時間だけが進む。待ちの深さの基準をやり直す（再開の直後を、遅れとしない）
        this.resetLagGuard();
        return;
      case "audio_resumed":
        this.driver?.onResume();
        this.resetLagGuard();
        return;
      case "set_bitrate":
        this.requireSession().video.setBitrate(command.kbps);
        return;
      case "request_keyframe":
        this.requireSession().video.forceKeyframe();
        return;
      case "begin_delivery":
        this.beginDelivery();
        return;
      case "pause_delivery":
        this.session?.gate.close();
        return;
      case "get_config":
        this.respond(command.requestId, () => this.currentConfig());
        return;
      case "get_stats":
        this.respond(command.requestId, () => ({ kind: "stats", stats: this.stats() }));
        return;
      case "end_session":
        this.respond(command.requestId, () => {
          this.endSession();
          return { kind: "ended" };
        });
        return;
      case "shutdown":
        this.dispose();
        return;
    }
  }

  /** 不正なメッセージ: 応答のある要求（requestId を持つ）なら、その要求への失敗の応答にする（待たせない）。そうでなければ、故障として知らせる。 */
  private rejectInvalid(data: unknown, error: unknown): void {
    const fault = faultOf(error);
    const requestId = requestIdOf(data);
    if (requestId === null) {
      this.reportFault(fault);
      return;
    }
    this.post({ type: "reply", requestId, ok: false, fault });
  }

  /** 応答のある要求を実行し、結果（または失敗）を、requestId つきで知らせる。失敗は型付きの故障にする。 */
  private respond(requestId: number, action: () => ReplyResult | Promise<ReplyResult>): void {
    void this.settleRequest(requestId, action).catch((error: unknown) => {
      this.diagnostic("reply_failed", { detail: faultOf(error).detail });
    });
  }

  private async settleRequest(requestId: number, action: () => ReplyResult | Promise<ReplyResult>): Promise<void> {
    let event: PipelineEvent;
    try {
      event = { type: "reply", requestId, ok: true, result: await action() };
    } catch (error) {
      event = { type: "reply", requestId, ok: false, fault: faultOf(error) };
    }
    this.post(event);
  }

  // ---------------------------------------------------------------------------
  // 映像ソース
  // ---------------------------------------------------------------------------

  private addSource(kind: VideoSourceKind, readable: ReadableStream<VideoFrame>): void {
    const previous = this.pumps.get(kind);
    if (previous !== undefined) {
      this.pumps.delete(kind);
      void previous.stop();
    }
    this.releaseFrame(kind);
    const pump: SourcePump = new SourcePump({
      kind,
      readable,
      store: this.frames,
      onEnded: () => this.handleSourceEnded(kind, pump),
      onError: (_kind, error) => this.handleSourceError(kind, pump, error),
    });
    this.pumps.set(kind, pump);
    pump.start();
  }

  private removeSource(kind: VideoSourceKind): void {
    const pump = this.pumps.get(kind);
    this.pumps.delete(kind);
    if (pump !== undefined) {
      void pump.stop();
    }
    this.releaseFrame(kind);
  }

  private handleSourceEnded(kind: VideoSourceKind, pump: SourcePump): void {
    if (this.disposed || this.pumps.get(kind) !== pump) {
      return;
    }
    this.pumps.delete(kind);
    this.releaseFrame(kind);
    this.post({ type: "source_ended", kind });
  }

  private handleSourceError(kind: VideoSourceKind, pump: SourcePump, error: unknown): void {
    if (this.disposed || this.pumps.get(kind) !== pump) {
      return;
    }
    this.pumps.delete(kind);
    this.releaseFrame(kind);
    this.reportFault(faultOf(new PipelineError("source_stream_failed", error)));
    this.post({ type: "source_ended", kind });
  }

  private releaseFrame(kind: VideoSourceKind): void {
    try {
      this.frames.release(kind);
    } catch (error) {
      this.reportFault(faultOf(new PipelineError("source_stream_failed", error)));
    }
  }

  // ---------------------------------------------------------------------------
  // 音声（メディアクロック）
  // ---------------------------------------------------------------------------

  private connectAudio(port: MessagePort): void {
    if (this.audioPort !== null) {
      port.close();
      throw new PipelineError("invalid_state");
    }
    const clock = new MediaClock();
    this.clock = clock;
    this.driver = new AudioClockDriver(clock, (tick) => this.onTick(tick));
    this.audioPort = port;
    this.audioBroken = false;
    this.resetLagGuard();
    port.onmessage = (event: MessageEvent) => this.onAudioMessage(event.data, event.timeStamp);
    this.refreshTicker();
    this.diagnostic("audio_connected", {});
  }

  private closeAudio(): void {
    const port = this.audioPort;
    this.audioPort = null;
    this.driver = null;
    this.clock = null;
    this.audioBroken = false;
    this.resetLagGuard();
    if (port !== null) {
      port.onmessage = null;
      port.close();
    }
  }

  /** 待ちの深さの基準と、遅れの状態を忘れる（新しいポート・音声の停止と再開）。 */
  private resetLagGuard(): void {
    this.lagGuard.reset();
    this.behind = false;
  }

  /** Worklet から直接届いたメッセージを、検査して、ブロックにする。不正なら、故障を知らせて null。 */
  private parseBlock(data: unknown): MixedAudioBlock | null {
    try {
      const message = parseWorkletMessage(data);
      if (message.type !== "block") {
        throw new PipelineError("invalid_message");
      }
      return { firstSample: message.firstSample, frames: message.frames, pcm: message.pcm };
    } catch (error) {
      this.reportFault(faultOf(error instanceof WorkletProtocolError ? new PipelineError("invalid_message", error) : error));
      return null;
    }
  }

  private onAudioMessage(data: unknown, timeStamp: unknown): void {
    if (this.disposed || this.audioBroken || this.driver === null) {
      return;
    }
    const block = this.parseBlock(data);
    if (block === null) {
      return;
    }
    // ブロックの処理待ちが積み上がっていれば、待ちが解けるまでの間に期限が来るフレームの合成を飛ばす（onTick）。待ちの深さは、timeStamp と累積サンプル数から推定する
    this.behind = this.lagGuard.observe(timeStamp, block.frames);
    try {
      this.driver.onBlock(block);
    } catch (error) {
      if (error instanceof AudioContinuityError) {
        this.audioBroken = true;
        this.reportFault(faultOf(new PipelineError("audio_continuity_lost", error)));
        return;
      }
      this.reportFault(faultOf(error));
    }
  }

  /** 音声の処理周期 1 回ごとに呼ばれる。ブロックを音声エンコーダへ、期限が来たフレームを合成して映像エンコーダへ渡す。 */
  private onTick(tick: AudioTick): void {
    const session = this.session;
    if (session !== null && session.active) {
      try {
        session.audio.encode(tick.block);
      } catch (error) {
        this.reportFault(faultOf(error));
      }
    }
    const { range } = tick;
    if (range.frameCount === 0) {
      return;
    }
    if (range.keyframeRequired && session !== null && session.active && !session.video.isFaulted) {
      // 飛ばす場合も、要求は残る（次に符号化するフレームが、キーフレームになる）
      session.video.forceKeyframe();
    }
    if (this.behind) {
      // 遅れている間は、合成を飛ばす。フレーム番号と時刻は、音声の累積サンプル数から決まるので、飛ばしても正しい。符号化の前に飛ばすので、参照の連鎖を壊さない
      this.skippedForLag += range.frameCount;
      return;
    }
    for (let offset = 0; offset < range.frameCount; offset += 1) {
      this.produceFrame(range.firstFrameIndex + offset, session);
    }
  }

  // ---------------------------------------------------------------------------
  // 合成・プレビュー・符号化
  // ---------------------------------------------------------------------------

  /** プレビューだけの間（音声のクロックが無い間）のタイマの 1 周期。合成して、プレビューへ写す。符号化しない。 */
  private previewTick(): void {
    this.composeOnce(null, null);
  }

  /** 配信中の 1 フレーム: 合成して、プレビューへ写し、設定済みなら符号化へ渡す。時刻は、フレーム番号から算出する。 */
  private produceFrame(frameIndex: number, session: Session | null): void {
    const clock = this.clock;
    this.composeOnce(session !== null && session.active && !session.video.isFaulted ? session : null, clock === null ? null : clock.videoTime(frameIndex));
  }

  /**
   * 1 枚を合成する。成功したら、プレビューへ写し、session と時刻があれば、符号化へ渡す。失敗（合成・VideoFrame の作成）したら、
   * そのフレームは符号化しない（描きかけを符号化しない）。同じ原因の失敗は、回復するまで、1 回だけ知らせる。
   */
  private composeOnce(session: Session | null, timestampUs: number | null): void {
    try {
      const result = this.compositor.compose({ screen: this.frames.latest("screen"), camera: this.frames.latest("camera") });
      this.composedFrames += 1;
      this.noteLayout(result.layout);
      this.presentPreview();
      if (session !== null && timestampUs !== null) {
        session.video.encode(this.compositor.snapshot(timestampUs));
      }
      this.activeFaults.delete(COMPOSE_FAILED);
    } catch (error) {
      const fault = faultOf(error);
      if (fault.code === COMPOSE_FAILED) {
        this.composeFailures += 1;
      }
      this.reportFaultOnce(fault);
    }
  }

  private presentPreview(): void {
    if (!this.preview.isAttached) {
      return;
    }
    try {
      this.preview.present(this.compositor.canvas);
    } catch (error) {
      // プレビューの失敗で、符号化を止めない。プレビューを外し、故障を知らせる
      this.preview.detach();
      this.refreshTicker();
      this.reportFault(faultOf(error));
    }
  }

  private noteLayout(layout: Layout): void {
    if (layout !== this.lastLayout) {
      this.lastLayout = layout;
      this.post({ type: "layout", layout });
    }
  }

  /** プレビューを描くタイマを動かすのは、プレビューの canvas があり、音声のクロックが無い（配信前）の間だけ。 */
  private refreshTicker(): void {
    if (!this.disposed && this.preview.isAttached && this.audioPort === null) {
      this.ticker.start(() => this.previewTick());
    } else {
      this.ticker.stop();
    }
  }

  private createCompositor(profile: Profile): VideoCompositor {
    const { width, height } = LIMITS.profiles[profile];
    return new VideoCompositor({ canvas: this.environment.createCanvas(width, height), profile, VideoFrame: this.environment.VideoFrame });
  }

  private switchCompositor(profile: Profile): void {
    if (this.compositor.profile !== profile) {
      this.compositor = this.createCompositor(profile);
    }
  }

  // ---------------------------------------------------------------------------
  // 設定・送出の受け渡し・終了
  // ---------------------------------------------------------------------------

  private requireSession(): Session {
    if (this.session === null || !this.session.active) {
      throw new PipelineError("not_configured");
    }
    return this.session;
  }

  /**
   * エンコーダを設定し、最初の出力（復号器設定）を得て返す。プロファイルは配信の開始時に確定し、配信中に変更しない
   * （設定済みで別のプロファイルは profile_locked、同じプロファイルは invalid_state）。
   * 失敗（設定が使えない・期限内に復号器設定を得られない・途中で終了された）したら、作ったエンコーダを閉じて、配信 1 本分の状態を戻す。
   */
  private async configure(profile: Profile, codec: VideoCodec, videoBitrateKbps: number): Promise<ReplyResult> {
    const current = this.session;
    if (current !== null) {
      throw new PipelineError(current.profile === profile ? "invalid_state" : "profile_locked");
    }
    const generation = ++this.sessionGeneration;
    const gate = new ChunkGate();
    const video = new VideoEncoderPipeline({
      VideoEncoder: this.environment.VideoEncoder,
      onChunk: (chunk) => this.deliver(gate, chunk),
      onFault: (fault) => this.reportFault(fault),
      onDecoderConfigChanged: (config) => this.post({ type: "decoder_config", config }),
    });
    const audio = new AudioEncoderPipeline({
      AudioEncoder: this.environment.AudioEncoder,
      AudioData: this.environment.AudioData,
      onChunk: (chunk) => this.deliver(gate, chunk),
      onFault: (fault) => this.reportFault(fault),
    });
    const session: Session = { profile, codec, video, audio, gate, active: false };
    this.session = session;
    try {
      this.switchCompositor(profile);
      await video.configure(profile, codec, videoBitrateKbps);
      await audio.configure();
      this.assertCurrent(generation, session);
      session.active = true;
      const [videoConfig, audioConfig] = await this.withTimeout(Promise.all([video.whenDecoderConfig(), audio.whenDecoderConfig()]), DECODER_CONFIG_TIMEOUT_MS);
      this.assertCurrent(generation, session);
      this.diagnostic("configured", { profile, codec });
      return { kind: "configured", video: videoConfig, audio: audioConfig };
    } catch (error) {
      if (this.sessionGeneration !== generation || this.session !== session) {
        // 設定の途中で、end_session・shutdown が来た。エンコーダは、そちらで閉じている
        throw new PipelineError("terminated");
      }
      session.gate.close();
      session.video.close();
      session.audio.close();
      this.session = null;
      this.switchCompositor(PREVIEW_PROFILE);
      throw error;
    }
  }

  private assertCurrent(generation: number, session: Session): void {
    if (this.sessionGeneration !== generation || this.session !== session) {
      throw new PipelineError("terminated");
    }
  }

  /** 期限（priming_timeout）つきで待つ。期限は、実行環境のタイマで数える（メディアの時刻ではない）。 */
  private withTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const handle = this.environment.scheduler.setTimeout(() => reject(new PipelineError("priming_timeout")), timeoutMs);
      promise.then(
        (value) => {
          this.environment.scheduler.clearTimeout(handle);
          resolve(value);
        },
        (error: unknown) => {
          this.environment.scheduler.clearTimeout(handle);
          reject(error);
        },
      );
    });
  }

  /** 符号化結果を、門（ゲート）を通して、メインスレッドへ渡す。 */
  private deliver(gate: ChunkGate, chunk: EncodedChunk): void {
    if (!gate.admit(chunk)) {
      return;
    }
    if (chunk.kind === "video") {
      this.deliveredVideoChunks += 1;
    } else {
      this.deliveredAudioChunks += 1;
    }
    this.post({ type: "chunk", chunk });
  }

  /** 送出を始める（開始時は状態通知で送出開始が伝えられたあと、復帰時はキーフレーム要求を受けたあと）。映像は、キーフレームから渡す。 */
  private beginDelivery(): void {
    const session = this.requireSession();
    const wasOpen = session.gate.isOpen;
    session.gate.open();
    if (!wasOpen && !session.video.isFaulted) {
      session.video.forceKeyframe();
    }
  }

  /** 配信 1 本分を終える: エンコーダ・音声のポートを閉じ、プレビューだけの状態へ戻す。設定していなくても、何度呼んでもよい。 */
  private endSession(): void {
    this.sessionGeneration += 1;
    const session = this.session;
    this.session = null;
    this.closeAudio();
    if (session !== null) {
      session.gate.close();
      session.video.close();
      session.audio.close();
      this.diagnostic("session_ended", {});
    }
    if (!this.disposed) {
      this.switchCompositor(PREVIEW_PROFILE);
    }
    this.refreshTicker();
  }

  private currentConfig(): ReplyResult {
    const session = this.session;
    return {
      kind: "config",
      video: session !== null && session.video.hasDecoderConfig ? session.video.configChunk() : null,
      audio: session !== null && session.audio.hasDecoderConfig ? session.audio.configChunk() : null,
    };
  }

  private stats(): PipelineStats {
    const session = this.session;
    const clock = this.clock;
    return {
      mode: this.audioPort !== null ? "clock" : "preview",
      profile: session === null ? null : session.profile,
      videoBitrateKbps: session === null ? null : session.video.bitrateKbps,
      layout: this.lastLayout,
      composedFrames: this.composedFrames,
      composeFailures: this.composeFailures,
      skippedForLag: this.skippedForLag,
      audioBacklogMs: Math.round(this.lagGuard.backlogMs),
      encodedVideoFrames: session === null ? 0 : session.video.encodedFrameCount,
      droppedBeforeEncode: session === null ? 0 : session.video.droppedBeforeEncodeCount,
      deliveredVideoChunks: this.deliveredVideoChunks,
      deliveredAudioChunks: this.deliveredAudioChunks,
      gateOpen: session === null ? false : session.gate.isOpen,
      gate: session === null ? { closedDiscardedVideo: 0, closedDiscardedAudio: 0, skippedBeforeKeyframe: 0 } : session.gate.counters,
      framesReceived: this.frames.receivedCount,
      framesClosed: this.frames.closedCount,
      framesRetained: this.frames.retainedCount,
      videoEncodeQueueSize: session === null ? 0 : session.video.encodeQueueSize,
      videoFaulted: session === null ? false : session.video.isFaulted,
      audioFaulted: session === null ? false : session.audio.isFaulted,
      clock: clock === null ? null : { sampleCount: clock.sampleCount, frameIndex: clock.frameIndex, stalled: clock.isStalled },
    };
  }

  // ---------------------------------------------------------------------------
  // 故障の通知
  // ---------------------------------------------------------------------------

  /** 故障を知らせる（メインスレッドへ。診断にも、符号と、元のエラーの名前だけを出す）。 */
  private reportFault(fault: PipelineFault): void {
    this.diagnostic("fault", { code: fault.code, detail: fault.detail });
    if (!this.disposed) {
      this.post({ type: "fault", fault });
    }
  }

  /** 同じ符号の故障は、回復する（activeFaults から外れる）まで、1 回だけ知らせる。 */
  private reportFaultOnce(fault: PipelineFault): void {
    if (this.activeFaults.has(fault.code)) {
      return;
    }
    this.activeFaults.add(fault.code);
    this.reportFault(fault);
  }
}
