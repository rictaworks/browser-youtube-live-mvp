// AudioMixer（requirements.md 11.2・11.5・11.6・13.1。issue #26）。AudioContext 上の AudioWorklet で、マイクと共有音声を混合する。
//
// 音声の処理周期が、メディアクロックと合成の駆動源になる（11.6）
//   Worklet の process()（128 サンプル）ごとに、PCM のブロックと累積サンプル数が、メッセージポートで送られてくる。
//   開始（start）の後は、ソースの有無にかかわらず、1 回も欠かさずに送られる（音声ソースが無ければ、無音のブロック。11.5）。
//   送り先は、(a) start({sink}) で渡した MessagePort（配信パイプラインのワーカーへ、メインスレッドを経由せず、直接。タブが非表示でも、メインスレッドの
//   タイマに依存しない）、または (b) subscribe した購読者の onBlock（メインスレッド）。時刻は、累積サンプル数から、MediaClock が算出する
//   （AudioClockDriver）。ここでは、実時計（Date・performance）を使わない。
//   AudioContext の停止（suspended・interrupted・端末の休止・close）は onStall、再開は onResume で通知する。MediaClock の onAudioStall・onAudioResume へ
//   つなぐ（再開では、空白を埋めず、キーフレームから再開する。#24）。
//
// グラフ（AudioContext は、サンプリング周波数 44,100 Hz。異なる周波数のソースは、MediaStreamAudioSourceNode が、混合の段で変換する）
//   マイク -> MediaStreamAudioSourceNode -> ミキサー（入力 0）
//   共有音声 -> MediaStreamAudioSourceNode -> ミキサー（入力 1）
//   ミキサーの出力 -> MediaStreamAudioDestinationNode（終端。ノードが処理され続けるためだけの物。出力は無音で、ストリームは使わない）
//   出力先（AudioContext の destination。スピーカー）へは、どのノードもつながない。取得した音声を、配信者自身へ折り返して再生しない（11.2）
//
// 開始の操作（利用者のクリック）の中で start を呼ぶ。AudioContext の resume は、その呼び出しの中で、最初の非同期呼び出しとして、同期的に呼ぶ。
// resume が期限（既定 5 秒）までに実行状態にならなければ、typed なエラー（context_not_running）で失敗する（止まったまま、何も起きない状態にしない）。
//
// ソースの追加・解除は、開始の前後を問わず行える（ストリーム・AudioContext・Worklet を再生成せず、MediaStreamAudioSourceNode の接続だけを変える）。
// 停止（stop）のあとも、登録したソースと音量は残り、もう一度 start すると、つなぎ直す。
//
// デバイス名・ラベルを、診断（ログ）へ出さない。

import { MIXER_CHANNEL_COUNT, MIXER_GAIN_MAX, MIXER_INPUT_KINDS, MIXER_PROCESSOR_NAME, MIXER_SAMPLE_RATE_HZ, MIXER_START_TIMEOUT_MS, MIXER_WORKLET_MODULE_URL, DEFAULT_MIXER_GAINS, mixerInputIndex } from "./config";
import type { MixerInputKind } from "./config";
import type { AudioEnvironment } from "./environment";
import { AudioMixerError, WorkletProtocolError } from "./errors";
import { assertGain, createMixerParameters } from "./MixerCore";
import type { MixerParameters } from "./MixerCore";
import { createProcessorOptions, parseWorkletMessage } from "./workletProtocol";
import type { MixedAudioBlock, WorkletCommand, WorkletMessage } from "./workletProtocol";
import { NO_DIAGNOSTICS } from "@/lib/sources/diagnostics";
import type { DiagnosticSink } from "@/lib/sources/diagnostics";
import { Emitter, rethrowLater } from "@/lib/sources/emitter";
import { nameOf } from "@/lib/sources/error-name";

/**
 *   idle      まだ開始していない（開始に失敗したときも、ここへ戻る）
 *   starting  開始中
 *   running   混合が動いている（AudioContext が実行状態）
 *   stalled   AudioContext が停止している（suspended・interrupted・closed）。合成も止まる
 *   stopped   stop が呼ばれた（もう一度 start できる）
 *   faulted   Worklet のプロセッサが例外を起こした（音声の処理が止まっている。stop して、やり直す）
 */
export type AudioMixerStatus = "idle" | "starting" | "running" | "stalled" | "stopped" | "faulted";

export type AudioMixerFaultCode = "processor_error" | "malformed_message" | "command_rejected";

export interface AudioMixerFault {
  readonly code: AudioMixerFaultCode;
  /** 補足の符号（元のメッセージの内容は入れない）。無ければ null */
  readonly detail: string | null;
}

/** 購読者。必要なものだけ実装する。 */
export interface AudioMixerListener {
  /** 混合したブロック（処理周期 1 回分）。start({sink}) で送り先を渡した場合は、メインスレッドへは来ない */
  onBlock?(block: MixedAudioBlock): void;
  /** AudioContext が停止した（メディアクロックの onAudioStall へ） */
  onStall?(): void;
  /** AudioContext が再開した（メディアクロックの onAudioResume へ） */
  onResume?(): void;
  /** 継続できない・想定外の事象（プロセッサの例外・不正なメッセージ・拒否されたコマンド） */
  onFault?(fault: AudioMixerFault): void;
}

export interface AudioMixerOptions {
  readonly environment: AudioEnvironment;
  /** 入力の種別ごとの、初期の音量（倍率）。指定しない種別は、既定（マイク 1・共有音声 0.6） */
  readonly gains?: Partial<Readonly<Record<MixerInputKind, number>>>;
  /** Worklet のモジュールの URL。既定は、設定の値 */
  readonly moduleUrl?: string;
  /** start が、AudioContext の実行状態を待つ上限（ミリ秒）。既定は、設定の値 */
  readonly startTimeoutMs?: number;
  /** 診断の出力先。デバイス名・ラベルは出さない。既定は、何も出さない */
  readonly onDiagnostic?: DiagnosticSink;
  /** 購読者の例外の扱い。既定は、次のタスクで投げ直す（握りつぶさない） */
  readonly onListenerError?: (error: unknown) => void;
}

export interface AudioMixerStartOptions {
  /**
   * ブロックの送り先の MessagePort（配信パイプラインのワーカーへ渡す、MessageChannel の片方）。Worklet へ転送する。
   * 渡さなければ、ブロックは、メインスレッドの購読者（onBlock）へ届く。
   */
  readonly sink?: MessagePort;
}

interface SourceEntry {
  readonly track: MediaStreamTrack;
  /** 開始中・実行中の、MediaStreamAudioSourceNode（開始の前・停止のあとは null） */
  node: MediaStreamAudioSourceNode | null;
}

export class AudioMixer {
  private readonly environment: AudioEnvironment;
  private readonly moduleUrl: string;
  private readonly startTimeoutMs: number;
  private readonly parameters: MixerParameters;
  private readonly diagnostic: DiagnosticSink;
  private readonly emitter: Emitter<AudioMixerListener>;
  private readonly gains: Record<MixerInputKind, number>;
  private readonly sources = new Map<MixerInputKind, SourceEntry>();
  private currentStatus: AudioMixerStatus = "idle";
  /** start・stop のたびに進める。開始の途中で stop が呼ばれたことを、start が知るために使う */
  private generation = 0;
  private context: AudioContext | null = null;
  private node: AudioWorkletNode | null = null;

  constructor(options: AudioMixerOptions) {
    this.environment = options.environment;
    this.moduleUrl = options.moduleUrl ?? MIXER_WORKLET_MODULE_URL;
    this.startTimeoutMs = options.startTimeoutMs ?? MIXER_START_TIMEOUT_MS;
    this.parameters = createMixerParameters(MIXER_SAMPLE_RATE_HZ);
    this.diagnostic = options.onDiagnostic ?? NO_DIAGNOSTICS;
    this.emitter = new Emitter<AudioMixerListener>(options.onListenerError ?? rethrowLater);
    this.gains = { ...DEFAULT_MIXER_GAINS, ...options.gains };
    for (const kind of MIXER_INPUT_KINDS) {
      assertGain(this.gains[kind], MIXER_GAIN_MAX);
    }
  }

  get status(): AudioMixerStatus {
    return this.currentStatus;
  }

  subscribe(listener: AudioMixerListener): () => void {
    return this.emitter.subscribe(listener);
  }

  /**
   * 混合を始める。開始の操作（利用者のクリック）の中で呼ぶこと（AudioContext の resume を、この呼び出しの中で、同期的に呼ぶ）。
   * 失敗したら、AudioContext を閉じて idle へ戻り、AudioMixerError で失敗する。開始の途中で stop が呼ばれたら、aborted で失敗する。
   */
  async start(options: AudioMixerStartOptions = {}): Promise<void> {
    if (this.currentStatus !== "idle" && this.currentStatus !== "stopped") {
      throw new AudioMixerError("invalid_state");
    }
    this.generation += 1;
    const generation = this.generation;
    this.currentStatus = "starting";
    this.diagnostic("mixer_start", {});

    let context: AudioContext | null = null;
    try {
      context = this.createContext();
      this.context = context;
      const audioWorklet = this.requireUsable(context);

      context.addEventListener("statechange", this.handleStateChange);
      const resumed = context.resume();
      // 開始が失敗して、待たれなくなった resume の拒否を、未処理の拒否にしない（待つときは、waitUntilRunning が、別に拒否を受け取る）
      resumed.catch(() => undefined);
      await this.loadModule(audioWorklet);
      this.assertCurrent(generation);

      const node = this.openGraph(context);
      await this.waitUntilRunning(context, resumed);
      this.assertCurrent(generation);
      this.beginBlocks(node, options.sink);
    } catch (error) {
      const failure = this.normalize(error);
      await this.abortStart(generation, context);
      this.diagnostic("mixer_start_failed", { code: failure.code });
      throw failure;
    }
  }

  /** 混合を止める。ソースとノードを外し、AudioContext を閉じる。登録したソースと音量は残る。何度呼んでもよい。 */
  async stop(): Promise<void> {
    if (this.currentStatus === "idle" || this.currentStatus === "stopped") {
      return;
    }
    this.generation += 1;
    const context = this.context;
    this.teardownGraph();
    this.currentStatus = "stopped";
    this.diagnostic("mixer_stopped", {});
    if (context !== null) {
      await this.closeContext(context);
    }
  }

  /**
   * 混合の対象に加える（マイク・共有音声のトラック）。開始の前にも、配信中にも行える。同じ種別を加え直すと、置き換える。
   * 音声でないトラック・すでに終了したトラックは、invalid_track。不明な種別は RangeError。
   */
  addSource(kind: MixerInputKind, track: MediaStreamTrack): void {
    mixerInputIndex(kind);
    if (track.kind !== "audio" || track.readyState === "ended") {
      throw new AudioMixerError("invalid_track");
    }
    const previous = this.sources.get(kind);
    if (previous !== undefined) {
      this.disconnectSource(previous);
    }
    const entry: SourceEntry = { track, node: null };
    this.sources.set(kind, entry);
    this.connectSource(kind, entry);
    this.diagnostic("mixer_source_added", { kind });
  }

  /** 混合の対象から外す。登録が無ければ、何も起きない。皆無になっても、混合は止まらず、無音を出し続ける。 */
  removeSource(kind: MixerInputKind): void {
    mixerInputIndex(kind);
    const entry = this.sources.get(kind);
    if (entry === undefined) {
      return;
    }
    this.disconnectSource(entry);
    this.sources.delete(kind);
    this.diagnostic("mixer_source_removed", { kind });
  }

  hasSource(kind: MixerInputKind): boolean {
    mixerInputIndex(kind);
    return this.sources.has(kind);
  }

  /** 入力の音量（倍率）を設定する。マイクを基準（既定 1）とし、共有音声の既定は 0.6。開始のあとは、Worklet へなだらかに反映する。不正な値は RangeError。 */
  setGain(kind: MixerInputKind, value: number): void {
    const index = mixerInputIndex(kind);
    assertGain(value, this.parameters.gainMax);
    this.gains[kind] = value;
    if (this.node !== null) {
      const command: WorkletCommand = { type: "gain", index, value };
      this.node.port.postMessage(command);
    }
    this.diagnostic("mixer_gain", { kind, value });
  }

  getGain(kind: MixerInputKind): number {
    mixerInputIndex(kind);
    return this.gains[kind];
  }

  // ---------------------------------------------------------------------------
  // 開始の部品
  // ---------------------------------------------------------------------------

  private createContext(): AudioContext {
    try {
      return this.environment.createContext({ sampleRate: MIXER_SAMPLE_RATE_HZ });
    } catch (error) {
      // 44.1 kHz を指定できない環境は、別の周波数のまま続けず、失敗にする（11.5）
      throw new AudioMixerError(nameOf(error) === "NotSupportedError" ? "sample_rate_unsupported" : "unexpected", error);
    }
  }

  /** 要求した 44,100 Hz で作られ、AudioWorklet が使える AudioContext か。そうでなければ、別の値のまま続けず、失敗にする。AudioWorklet を返す。 */
  private requireUsable(context: AudioContext): AudioWorklet {
    if (context.sampleRate !== MIXER_SAMPLE_RATE_HZ) {
      throw new AudioMixerError("sample_rate_unsupported");
    }
    const audioWorklet: AudioWorklet | undefined = context.audioWorklet;
    if (audioWorklet === undefined || typeof audioWorklet.addModule !== "function") {
      throw new AudioMixerError("unsupported");
    }
    return audioWorklet;
  }

  /** Worklet のモジュールを読み込む。addModule は、この呼び出しの中で、同期的に呼ばれる（resume と並べて、開始のクリックの中で）。 */
  private async loadModule(audioWorklet: AudioWorklet): Promise<void> {
    try {
      await audioWorklet.addModule(this.moduleUrl);
    } catch (error) {
      throw new AudioMixerError("worklet_load_failed", error);
    }
  }

  /** Worklet のノードを作り、メッセージ・例外を受け取る準備をして、終端のノードへつなぎ、登録済みのソースをつなぐ。 */
  private openGraph(context: AudioContext): AudioWorkletNode {
    const node = this.createNode(context);
    this.node = node;
    node.addEventListener("processorerror", this.handleProcessorError);
    node.port.onmessage = this.handleWorkletMessage;
    node.connect(context.createMediaStreamDestination());
    for (const [kind, entry] of this.sources) {
      this.connectSource(kind, entry);
    }
    return node;
  }

  /** ブロックの送信を始める（開始のコマンド）。sink があれば、Worklet へ転送する。 */
  private beginBlocks(node: AudioWorkletNode, sink: MessagePort | undefined): void {
    const command: WorkletCommand = { type: "start" };
    node.port.postMessage(command, sink === undefined ? [] : [sink]);
    this.currentStatus = "running";
    this.diagnostic("mixer_started", {});
  }

  private createNode(context: AudioContext): AudioWorkletNode {
    const options: AudioWorkletNodeOptions = {
      numberOfInputs: MIXER_INPUT_KINDS.length,
      numberOfOutputs: 1,
      outputChannelCount: [MIXER_CHANNEL_COUNT],
      channelCount: MIXER_CHANNEL_COUNT,
      // 入力のチャンネル数を 2 に固定し、スピーカーの規則で変換する（モノラルのマイクは、左右へ同じ値。Web Audio が行う）
      channelCountMode: "explicit",
      channelInterpretation: "speakers",
      processorOptions: createProcessorOptions(
        this.parameters,
        MIXER_INPUT_KINDS.map((kind) => this.gains[kind]),
      ),
    };
    try {
      return this.environment.createWorkletNode(context, MIXER_PROCESSOR_NAME, options);
    } catch (error) {
      throw new AudioMixerError("worklet_create_failed", error);
    }
  }

  /** AudioContext が実行状態になるまで、上限の時間だけ待つ（自動再生の制限で止まったままのとき、失敗にする）。 */
  private async waitUntilRunning(context: AudioContext, resumed: Promise<void>): Promise<void> {
    let timer: unknown = null;
    const timeout = new Promise<never>((_resolve, reject) => {
      timer = this.environment.setTimeout(() => {
        reject(new AudioMixerError("context_not_running"));
      }, this.startTimeoutMs);
    });
    try {
      await Promise.race([resumed, timeout]);
    } catch (error) {
      throw error instanceof AudioMixerError ? error : new AudioMixerError("context_not_running", error);
    } finally {
      this.environment.clearTimeout(timer);
    }
    if (context.state !== "running") {
      throw new AudioMixerError("context_not_running");
    }
  }

  private assertCurrent(generation: number): void {
    if (this.generation !== generation) {
      throw new AudioMixerError("aborted");
    }
  }

  private normalize(error: unknown): AudioMixerError {
    return error instanceof AudioMixerError ? error : new AudioMixerError("unexpected", error);
  }

  /** 開始の失敗の後始末。stop が呼ばれていたときは、stop が後始末をしている（重ねて閉じない）。 */
  private async abortStart(generation: number, context: AudioContext | null): Promise<void> {
    if (this.generation !== generation) {
      return;
    }
    this.teardownGraph();
    this.currentStatus = "idle";
    if (context !== null) {
      await this.closeContext(context);
    }
  }

  // ---------------------------------------------------------------------------
  // グラフ
  // ---------------------------------------------------------------------------

  private connectSource(kind: MixerInputKind, entry: SourceEntry): void {
    const { context, node } = this;
    if (context === null || node === null) {
      return;
    }
    const source = context.createMediaStreamSource(this.environment.createMediaStream([entry.track]));
    source.connect(node, 0, mixerInputIndex(kind));
    entry.node = source;
  }

  private disconnectSource(entry: SourceEntry): void {
    entry.node?.disconnect();
    entry.node = null;
  }

  /** ソース・ノードの接続とイベントの購読を外す（AudioContext は、閉じない）。 */
  private teardownGraph(): void {
    for (const entry of this.sources.values()) {
      this.disconnectSource(entry);
    }
    const { context, node } = this;
    if (node !== null) {
      node.removeEventListener("processorerror", this.handleProcessorError);
      node.port.onmessage = null;
      node.disconnect();
    }
    context?.removeEventListener("statechange", this.handleStateChange);
    this.node = null;
    this.context = null;
  }

  private async closeContext(context: AudioContext): Promise<void> {
    try {
      if (context.state !== "closed") {
        await context.close();
      }
    } catch (error) {
      // 閉じられなくても、音声の混合は止まっている。失敗は診断に残す（握りつぶさない。呼び出し元の stop・start の結果は変えない）
      this.diagnostic("mixer_close_failed", { errorName: nameOf(error) });
    }
  }

  // ---------------------------------------------------------------------------
  // イベント
  // ---------------------------------------------------------------------------

  private readonly handleStateChange = (): void => {
    const context = this.context;
    if (context === null || (this.currentStatus !== "running" && this.currentStatus !== "stalled")) {
      return;
    }
    const running = context.state === "running";
    if (running === (this.currentStatus === "running")) {
      return;
    }
    this.currentStatus = running ? "running" : "stalled";
    this.diagnostic("mixer_context_state", { state: context.state });
    this.emitter.notify((listener) => {
      if (running) {
        listener.onResume?.();
      } else {
        listener.onStall?.();
      }
    });
  };

  private readonly handleProcessorError = (): void => {
    if (this.currentStatus !== "running" && this.currentStatus !== "stalled") {
      return;
    }
    const wasRunning = this.currentStatus === "running";
    this.currentStatus = "faulted";
    if (wasRunning) {
      this.emitter.notify((listener) => listener.onStall?.());
    }
    this.emitFault("processor_error", null);
  };

  private readonly handleWorkletMessage = (event: MessageEvent): void => {
    if (this.currentStatus === "idle" || this.currentStatus === "stopped") {
      return;
    }
    let message: WorkletMessage;
    try {
      message = parseWorkletMessage(event.data);
    } catch (error) {
      if (error instanceof WorkletProtocolError) {
        this.emitFault("malformed_message", error.reason);
        return;
      }
      throw error;
    }
    if (message.type === "block") {
      const block: MixedAudioBlock = { firstSample: message.firstSample, frames: message.frames, pcm: message.pcm };
      this.emitter.notify((listener) => listener.onBlock?.(block));
      return;
    }
    this.emitFault("command_rejected", `${message.command ?? "none"}:${message.reason}`);
  };

  private emitFault(code: AudioMixerFaultCode, detail: string | null): void {
    this.diagnostic("mixer_fault", { code, detail });
    const fault: AudioMixerFault = { code, detail };
    this.emitter.notify((listener) => listener.onFault?.(fault));
  }
}
