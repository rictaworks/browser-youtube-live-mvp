// PipelineClient（メインスレッド側のワーカーのクライアント。requirements.md 11.4・11.6・13.1・30.1。issue #27）。
// 配信パイプラインのワーカー（合成とエンコード）を起動し、型付きのメッセージで操作する。画面（#29）と配信の制御（#28）が使う。
//
//   映像ソース  メインスレッドで MediaStreamTrackProcessor を作り、その readable（VideoFrame のストリーム）をワーカーへ転送する
//               （Chrome では、ワーカー内で processor は使えず、MediaStreamTrack も転送できない）。processor の参照は、ソースが外れるまで保つ
//   プレビュー  <canvas> を transferControlToOffscreen して、ワーカーへ渡す。ワーカーが描くので、メインスレッドの描画で配信を妨げない。
//               同じ <canvas> は 1 回しか渡せない（2 回目は preview_already_transferred）。画面を作り直したら、新しい <canvas> を渡す
//   音声        #26 のミキサーの出力先（MessagePort）を作り、ワーカーへ渡す（openAudioSink）。ブロックは、メインスレッドを経由せず、ワーカーへ直接届く。
//               AudioContext の停止・再開は、audioListener（ミキサーの購読者）が、ワーカーへ転送する（メディアクロックの停止・再開）
//   要求        configure・getConfig・getStats・endSession は、requestId で応答と対応づけ、期限を持つ（有限時間で終端へ進む）
//   異常終了    ワーカーの error イベントを検知して、worker_crashed の故障を 1 回だけ通知し、ワーカーを終了する
//   解放        terminate で、shutdown を送り、ワーカーを終了し、processor の参照を手放し、待っている要求を拒否する
//
// ワーカーの作り方（createWorker）・MediaStreamTrackProcessor・MessageChannel・タイマは、注入される（テストは疑似を渡す）。
// 実際のワーカーは、defaultWorker.ts の createPipelineWorker()（new Worker(new URL(…, import.meta.url), { type: "module" })）。
// 時刻は扱わない（符号化結果の時刻は、ワーカーが、メディアクロックから付ける）。メッセージ・例外に、機密・デバイス名・URL を載せない。

import type { AudioMixerListener } from "@/lib/audio/AudioMixer";
import type { Layout, Profile } from "@/core/contract";
import type { VideoCodec } from "@/core/transport";
import { NO_DIAGNOSTICS } from "@/lib/sources/diagnostics";
import type { DiagnosticSink } from "@/lib/sources/diagnostics";
import { isVideoSourceKind } from "@/workers/pipeline/FrameStore";
import type { VideoSourceKind } from "@/workers/pipeline/FrameStore";
import { parseEvent, transferablesOfCommand } from "@/workers/pipeline/messages";
import type { PipelineCommand, PipelineEvent, PipelineStats, ReplyResult } from "@/workers/pipeline/messages";
import type { DecoderConfigChunk, EncodedChunk } from "./chunks";
import { PIPELINE_REQUEST_TIMEOUT_MS, PIPELINE_START_TIMEOUT_MS } from "./config";
import { buildVideoEncoderConfig } from "./encoderConfig";
import { PipelineError, errorFromFault, faultOf } from "./errors";
import type { PipelineFault } from "./errors";
import { defaultTimers } from "./timers";
import { createTrackReadable } from "./trackReadable";
import type { TrackReadable } from "./trackReadable";

/** クライアントが使う Worker の面（本物の Worker は、そのまま渡せる）。 */
export interface PipelineWorkerLike {
  postMessage(message: unknown, transfer: Transferable[]): void;
  terminate(): void;
  onmessage: ((event: MessageEvent) => void) | null;
  onerror: ((event: ErrorEvent) => void) | null;
  onmessageerror: ((event: MessageEvent) => void) | null;
}

/** 応答の期限と起動の期限のためのタイマ（注入）。 */
export interface TimerApi {
  setTimeout(callback: () => void, delayMs: number): unknown;
  clearTimeout(handle: unknown): void;
}

/** プレビュー用の <canvas>（HTMLCanvasElement）のうち、使う面。 */
export interface PreviewCanvasSource {
  transferControlToOffscreen(): OffscreenCanvas;
}

export interface PipelineClientOptions {
  /** ワーカーを作る。実際には createPipelineWorker（defaultWorker.ts） */
  readonly createWorker: () => PipelineWorkerLike;
  /** 映像トラックから readable を作る。既定は createTrackReadable（Window の MediaStreamTrackProcessor） */
  readonly createTrackReadable?: (track: MediaStreamTrack) => TrackReadable;
  /** 音声の出力先のチャンネルを作る。既定は new MessageChannel() */
  readonly createMessageChannel?: () => MessageChannel;
  readonly timers?: TimerApi;
  /** 符号化結果。送信待ち（#25 の SendQueue）へ積む（呼び出しの順は #28） */
  readonly onChunk: (chunk: EncodedChunk) => void;
  /** 故障（エンコーダのエラー・ワーカーの異常終了・不正なメッセージなど）。型付きで、符号と、元のエラーの名前だけ */
  readonly onFault: (fault: PipelineFault) => void;
  /** 復号器設定の内容が変わった（再設定のあと）。中継へ設定を再送する必要がある */
  readonly onDecoderConfigChanged?: (config: DecoderConfigChunk) => void;
  /** 合成のレイアウトが変わった（ソースの追加・解除・喪失。代替スレートへの切り替えを含む） */
  readonly onLayoutChanged?: (layout: Layout) => void;
  /** 映像ソースのストリームが終わった（トラックの終了） */
  readonly onSourceEnded?: (kind: VideoSourceKind) => void;
  readonly diagnostic?: DiagnosticSink;
  readonly startTimeoutMs?: number;
  readonly requestTimeoutMs?: number;
}

export interface ConfigureOptions {
  readonly profile: Profile;
  readonly videoCodec: VideoCodec;
  /** 映像ビットレートの開始値（kbps） */
  readonly videoBitrateKbps: number;
}

/** 設定の結果: 映像・音声の復号器設定（開始通知 start の description_b64 になる）。 */
export interface ConfiguredResult {
  readonly video: DecoderConfigChunk;
  readonly audio: DecoderConfigChunk;
}

export interface ConfigSnapshot {
  readonly video: DecoderConfigChunk | null;
  readonly audio: DecoderConfigChunk | null;
}

type Phase = "idle" | "starting" | "running" | "closed";

interface PendingRequest {
  readonly resolve: (result: ReplyResult) => void;
  readonly reject: (error: PipelineError) => void;
  readonly timer: unknown;
}

interface StartWaiter {
  readonly resolve: () => void;
  readonly reject: (error: PipelineError) => void;
  readonly timer: unknown;
}

/** 診断に残すための、メッセージの種類（type が文字列のときだけ。長さを制限する）。 */
function messageTypeOf(data: unknown): string | null {
  if (typeof data !== "object" || data === null) {
    return null;
  }
  const type = (data as { type?: unknown }).type;
  return typeof type === "string" ? type.slice(0, 32) : null;
}

export class PipelineClient {
  /** AudioMixer.subscribe に渡す購読者。AudioContext の停止・再開を、ワーカーのメディアクロックへ転送する。終了後は、何もしない。 */
  readonly audioListener: AudioMixerListener = {
    onStall: () => this.sendIfRunning({ type: "audio_stalled" }),
    onResume: () => this.sendIfRunning({ type: "audio_resumed" }),
  };

  private readonly options: PipelineClientOptions;
  private readonly timers: TimerApi;
  private readonly diagnostic: DiagnosticSink;
  private phase: Phase = "idle";
  private worker: PipelineWorkerLike | null = null;
  private startWaiter: StartWaiter | null = null;
  private nextRequestId = 1;
  private readonly pending = new Map<number, PendingRequest>();
  private readonly held = new Map<VideoSourceKind, TrackReadable>();
  private readonly transferredCanvases = new WeakSet<object>();

  constructor(options: PipelineClientOptions) {
    this.options = options;
    this.timers = options.timers ?? defaultTimers;
    this.diagnostic = options.diagnostic ?? NO_DIAGNOSTICS;
  }

  /** ワーカーが保持している processor の数（映像ソースの数）。 */
  get heldSourceCount(): number {
    return this.held.size;
  }

  // ---------------------------------------------------------------------------
  // 起動・終了
  // ---------------------------------------------------------------------------

  /**
   * ワーカーを起動し、準備完了（ready）まで待つ。期限内に ready が無ければ worker_start_timeout、ワーカーが起動の失敗（実行環境に必要な機能が無い、など）を
   * 知らせたらその符号、スクリプトの読み込みの失敗は worker_crashed。いずれもワーカーを終了する。2 回目の呼び出しは invalid_state。
   */
  start(): Promise<void> {
    if (this.phase !== "idle") {
      return Promise.reject(new PipelineError("invalid_state"));
    }
    let worker: PipelineWorkerLike;
    try {
      worker = this.options.createWorker();
    } catch (error) {
      this.phase = "closed";
      return Promise.reject(new PipelineError("worker_crashed", error));
    }
    this.phase = "starting";
    this.worker = worker;
    worker.onmessage = (event: MessageEvent) => this.handleMessage(event.data);
    worker.onerror = () => this.handleCrash();
    worker.onmessageerror = () => this.options.onFault({ code: "invalid_message", detail: null });
    return new Promise<void>((resolve, reject) => {
      const timer = this.timers.setTimeout(() => this.failStart(new PipelineError("worker_start_timeout")), this.options.startTimeoutMs ?? PIPELINE_START_TIMEOUT_MS);
      this.startWaiter = { resolve, reject, timer };
    });
  }

  /** shutdown を送り、ワーカーを終了し、processor の参照を手放し、待っている要求を terminated で拒否する。何度呼んでもよい。 */
  terminate(): void {
    if (this.phase === "closed") {
      return;
    }
    if (this.phase === "idle") {
      this.phase = "closed";
      return;
    }
    try {
      this.worker?.postMessage({ type: "shutdown" }, []);
    } catch (error) {
      // 終了を丁寧に伝えられなくても、ワーカーは、すぐあとで強制的に終了する。原因は診断に残す
      this.diagnostic("shutdown_post_failed", { detail: faultOf(error).detail });
    }
    this.close(new PipelineError("terminated"));
  }

  // ---------------------------------------------------------------------------
  // プレビュー・映像ソース・音声
  // ---------------------------------------------------------------------------

  /**
   * プレビュー用の <canvas> を、OffscreenCanvas にして、ワーカーへ渡す。同じ <canvas> は 1 回だけ（preview_already_transferred）。
   * すでに getContext した <canvas> など、渡せないものは preview_unavailable。
   */
  attachPreview(canvas: PreviewCanvasSource): void {
    this.requireRunning();
    if (this.transferredCanvases.has(canvas)) {
      throw new PipelineError("preview_already_transferred");
    }
    let offscreen: OffscreenCanvas;
    try {
      offscreen = canvas.transferControlToOffscreen();
    } catch (error) {
      throw new PipelineError("preview_unavailable", error);
    }
    this.transferredCanvases.add(canvas);
    this.send({ type: "attach_preview", canvas: offscreen });
  }

  detachPreview(): void {
    this.send({ type: "detach_preview" });
  }

  /**
   * 映像ソース（画面共有・カメラ）を追加する。トラックから readable を作り、ワーカーへ転送する（トラック自体は転送できない）。
   * 同じ種類を追加し直すと、前のソースを置き換える。映像でないトラックは RangeError、終了したトラックは invalid_state。
   */
  addVideoSource(kind: VideoSourceKind, track: MediaStreamTrack): void {
    if (!isVideoSourceKind(kind)) {
      throw new RangeError(`unknown video source kind: ${String(kind)}`);
    }
    if (track.kind !== "video") {
      throw new RangeError(`the track must be a video track: ${String(track.kind)}`);
    }
    this.requireRunning();
    if (track.readyState === "ended") {
      throw new PipelineError("invalid_state");
    }
    const create = this.options.createTrackReadable ?? ((source: MediaStreamTrack) => createTrackReadable(source));
    const trackReadable = create(track);
    this.held.set(kind, trackReadable);
    try {
      this.send({ type: "add_source", kind, readable: trackReadable.readable });
    } catch (error) {
      this.held.delete(kind);
      throw error;
    }
  }

  removeVideoSource(kind: VideoSourceKind): void {
    if (!isVideoSourceKind(kind)) {
      throw new RangeError(`unknown video source kind: ${String(kind)}`);
    }
    this.send({ type: "remove_source", kind });
    this.held.delete(kind);
  }

  /**
   * #26 のミキサーの出力先（MessagePort）を作り、片方をワーカーへ渡し、もう片方を返す（AudioMixer.start({ sink }) へ渡す）。
   * ブロックは、メインスレッドを経由せず、ワーカーへ直接届く（タブが非表示でも、メインスレッドのタイマに依存しない）。
   */
  openAudioSink(): MessagePort {
    this.requireRunning();
    const channel = this.options.createMessageChannel?.() ?? new MessageChannel();
    try {
      this.send({ type: "connect_audio", port: channel.port1 });
    } catch (error) {
      channel.port1.close();
      channel.port2.close();
      throw error;
    }
    return channel.port2;
  }

  // ---------------------------------------------------------------------------
  // 設定・適応制御・送出の受け渡し・終了
  // ---------------------------------------------------------------------------

  /**
   * エンコーダを設定し、最初の出力（復号器設定）を得て返す（配信の開始時に 1 回）。音声のクロックが動いていないと得られない（priming_timeout）。
   * 範囲外のビットレートは、送る前に bitrate_out_of_range。
   */
  async configure(options: ConfigureOptions): Promise<ConfiguredResult> {
    buildVideoEncoderConfig(options.profile, options.videoCodec, options.videoBitrateKbps);
    return this.request(
      (requestId) => ({ type: "configure", requestId, profile: options.profile, videoCodec: options.videoCodec, videoBitrateKbps: options.videoBitrateKbps }),
      (result) => {
        if (result.kind !== "configured") {
          throw new PipelineError("invalid_message");
        }
        return { video: result.video, audio: result.audio };
      },
    );
  }

  /** 映像ビットレートの目標を変える（適応制御）。範囲の検査は、ワーカー（プロファイルを知っている）。 */
  setBitrate(kbps: number): void {
    if (!Number.isFinite(kbps)) {
      throw new RangeError(`kbps must be a finite number: ${String(kbps)}`);
    }
    this.send({ type: "set_bitrate", kbps });
  }

  /** 次に符号化するフレームを、キーフレームにする（滞留 4 秒超・復帰時）。 */
  requestKeyframe(): void {
    this.send({ type: "request_keyframe" });
  }

  /** 符号化結果の受け渡しを始める（開始時は状態通知で送出開始が伝えられたあと、復帰時はキーフレーム要求を受けたあと）。映像は、キーフレームから。 */
  beginDelivery(): void {
    this.send({ type: "begin_delivery" });
  }

  /** 符号化結果の受け渡しを止める（再接続中。エンコーダは動かし続け、結果は捨てる）。 */
  pauseDelivery(): void {
    this.send({ type: "pause_delivery" });
  }

  /** 復号器設定を再取得する（再接続のあと、中継へ設定を再送するため）。設定していなければ null。 */
  getConfig(): Promise<ConfigSnapshot> {
    return this.request(
      (requestId) => ({ type: "get_config", requestId }),
      (result) => {
        if (result.kind !== "config") {
          throw new PipelineError("invalid_message");
        }
        return { video: result.video, audio: result.audio };
      },
    );
  }

  /** ワーカーの統計（破棄フレーム数・フレームの帳簿・統計）。 */
  getStats(): Promise<PipelineStats> {
    return this.request(
      (requestId) => ({ type: "get_stats", requestId }),
      (result) => {
        if (result.kind !== "stats") {
          throw new PipelineError("invalid_message");
        }
        return result.stats;
      },
    );
  }

  /** 配信 1 本分を終える（エンコーダ・音声のポートを閉じ、プレビューだけの状態へ戻る）。ワーカーとプレビューは、生きたまま。 */
  endSession(): Promise<void> {
    return this.request(
      (requestId) => ({ type: "end_session", requestId }),
      (result) => {
        if (result.kind !== "ended") {
          throw new PipelineError("invalid_message");
        }
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  private requireRunning(): PipelineWorkerLike {
    if (this.phase !== "running" || this.worker === null) {
      throw new PipelineError("invalid_state");
    }
    return this.worker;
  }

  private send(command: PipelineCommand): void {
    const worker = this.requireRunning();
    try {
      worker.postMessage(command, transferablesOfCommand(command));
    } catch (error) {
      throw new PipelineError("unexpected", error);
    }
  }

  private sendIfRunning(command: PipelineCommand): void {
    if (this.phase === "running") {
      this.send(command);
    }
  }

  private request<T>(build: (requestId: number) => PipelineCommand, accept: (result: ReplyResult) => T): Promise<T> {
    if (this.phase !== "running") {
      return Promise.reject(new PipelineError("invalid_state"));
    }
    const requestId = this.nextRequestId++;
    return new Promise<T>((resolve, reject) => {
      const timer = this.timers.setTimeout(() => {
        this.pending.delete(requestId);
        reject(new PipelineError("request_timeout"));
      }, this.options.requestTimeoutMs ?? PIPELINE_REQUEST_TIMEOUT_MS);
      this.pending.set(requestId, {
        resolve: (result) => {
          try {
            resolve(accept(result));
          } catch (error) {
            reject(error);
          }
        },
        reject,
        timer,
      });
      try {
        this.send(build(requestId));
      } catch (error) {
        this.timers.clearTimeout(timer);
        this.pending.delete(requestId);
        reject(error);
      }
    });
  }

  private handleMessage(data: unknown): void {
    if (this.phase === "closed") {
      return;
    }
    let event: PipelineEvent;
    try {
      event = parseEvent(data);
    } catch (error) {
      // 届いたメッセージの種類だけを診断に残す（中身は、符号化データ・機密を含み得るので、残さない）
      this.diagnostic("invalid_inbound_message", { type: messageTypeOf(data) });
      this.options.onFault(faultOf(error));
      return;
    }
    switch (event.type) {
      case "ready":
        this.finishStart();
        return;
      case "reply":
        this.settle(event);
        return;
      case "chunk":
        this.options.onChunk(event.chunk);
        return;
      case "decoder_config":
        this.options.onDecoderConfigChanged?.(event.config);
        return;
      case "layout":
        this.options.onLayoutChanged?.(event.layout);
        return;
      case "source_ended":
        this.held.delete(event.kind);
        this.options.onSourceEnded?.(event.kind);
        return;
      case "fault":
        if (this.phase === "starting") {
          this.failStart(errorFromFault(event.fault));
          return;
        }
        this.options.onFault(event.fault);
        return;
    }
  }

  private finishStart(): void {
    const waiter = this.startWaiter;
    if (this.phase !== "starting" || waiter === null) {
      return;
    }
    this.startWaiter = null;
    this.timers.clearTimeout(waiter.timer);
    this.phase = "running";
    waiter.resolve();
  }

  /** 起動の失敗: ワーカーを終了して、start を拒否する。 */
  private failStart(error: PipelineError): void {
    const waiter = this.startWaiter;
    this.startWaiter = null;
    this.close(error);
    if (waiter !== null) {
      this.timers.clearTimeout(waiter.timer);
      waiter.reject(error);
    }
  }

  private settle(event: Extract<PipelineEvent, { type: "reply" }>): void {
    const request = this.pending.get(event.requestId);
    if (request === undefined) {
      // 期限切れ・終了済みの要求への、遅れた応答
      this.diagnostic("unknown_reply", { requestId: event.requestId });
      return;
    }
    this.pending.delete(event.requestId);
    this.timers.clearTimeout(request.timer);
    if (event.ok) {
      request.resolve(event.result);
    } else {
      request.reject(errorFromFault(event.fault));
    }
  }

  /** ワーカーの異常終了（error イベント。スクリプトの読み込みの失敗を含む）。故障を 1 回だけ通知し、ワーカーを終了する。 */
  private handleCrash(): void {
    if (this.phase === "closed") {
      return;
    }
    const wasStarting = this.phase === "starting";
    const waiter = this.startWaiter;
    this.startWaiter = null;
    const error = new PipelineError("worker_crashed");
    this.close(error);
    if (wasStarting && waiter !== null) {
      this.timers.clearTimeout(waiter.timer);
      waiter.reject(error);
      return;
    }
    this.options.onFault({ code: "worker_crashed", detail: null });
  }

  /** ワーカーを終了し、待っている要求を拒否し、processor の参照を手放す。以後、クライアントは使えない。 */
  private close(reason: PipelineError): void {
    const worker = this.worker;
    const waiter = this.startWaiter;
    this.phase = "closed";
    this.worker = null;
    this.startWaiter = null;
    this.held.clear();
    for (const [requestId, request] of this.pending) {
      this.timers.clearTimeout(request.timer);
      this.pending.delete(requestId);
      request.reject(reason);
    }
    if (waiter !== null) {
      this.timers.clearTimeout(waiter.timer);
      waiter.reject(reason);
    }
    if (worker !== null) {
      worker.onmessage = null;
      worker.onerror = null;
      worker.onmessageerror = null;
      worker.terminate();
    }
  }
}
