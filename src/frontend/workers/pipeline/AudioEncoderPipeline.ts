// AudioEncoderPipeline（requirements.md 11.5〜11.7。issue #27）。AAC-LC の音声エンコード（WebCodecs の AudioEncoder）。ワーカーの上で動く。
//
//   設定        AAC-LC（mp4a.40.2）・44.1 kHz・2 ch・128 kbps・aac 形式（生のフレーム。ADTS なし）。設定の前に isConfigSupported で確かめ、
//               使えなければ audio_config_unsupported（別の形式へ黙って切り替えない）。Chrome の AAC エンコードは、Windows（N エディションを除く）・
//               macOS・Android のみで、Linux・ChromeOS では使えない（30.1 の能力検出で、配信の開始が提供されない）
//   入力        #26 の PCM のブロック（インターリーブの 32 ビット浮動小数点）を、AudioData（format: f32）にする。AudioData の時刻は、
//               ブロックの累積サンプル数から算出する（audioTime）。AudioData は、符号化に渡した直後に close する
//   出力の時刻  AAC-LC の 1 フレームは 1,024 サンプル。n 番目の出力チャンクの時刻は、audioTime(最初のブロックの累積サンプル数 + n × 1,024)。
//               エンコーダが返す時刻・実時計に頼らず、差分も積み上げない（毎回、累積値から算出する。11.6）
//   連続性      ブロックの累積サンプル数が、前のブロックの続きでなければ（欠落・重複・順序の入れ替わり）、時刻の基準が崩れたので、
//               続けず、audio_continuity_lost の故障として通知する。音声のクロックは止めない（encode は例外にしない）
//   復号器設定  decoderConfig.description（AudioSpecificConfig。AAC-LC・44.1 kHz・2 ch は 0x12 0x10）を、最初の出力で得て保持する
//   エラー      error コールバック・例外を、型付きの故障として onFault へ通知する（1 回だけ）。以後の入力は符号化しない
//   音声は破棄しない（11.5・12 章）。ここには、入力待ちで捨てる仕組みが無い（映像とは違う）。close でエンコーダを閉じる
//
// 実時計（Date・performance）を使わない。AudioEncoder・AudioData のコンストラクタは注入される。

import { audioTimeUs } from "@/core/clock";
import { LIMITS } from "@/core/contract";
import type { MixedAudioBlock } from "@/lib/audio/workletProtocol";
import { createEncodedChunk } from "@/lib/pipeline/chunks";
import type { DecoderConfigChunk, EncodedChunk } from "@/lib/pipeline/chunks";
import { AAC_SAMPLES_PER_FRAME } from "@/lib/pipeline/config";
import { buildAudioEncoderConfig } from "@/lib/pipeline/encoderConfig";
import { PipelineError, faultOf } from "@/lib/pipeline/errors";
import type { PipelineFault } from "@/lib/pipeline/errors";
import { DecoderConfigHolder } from "./DecoderConfigHolder";

export interface AudioEncoderPipelineOptions {
  /** WebCodecs の AudioEncoder（ワーカーの大域のものを、環境から渡す） */
  readonly AudioEncoder: typeof AudioEncoder;
  /** WebCodecs の AudioData（同上） */
  readonly AudioData: typeof AudioData;
  /** 符号化結果。ゲート（ChunkGate）を通すかどうかは、呼び出し側が決める */
  readonly onChunk: (chunk: EncodedChunk) => void;
  /** 故障（エンコーダのエラー・設定の失敗・ブロックの不連続）。1 回だけ通知する */
  readonly onFault: (fault: PipelineFault) => void;
}

type State = "idle" | "configuring" | "configured" | "faulted" | "closed";

const CHANNELS = LIMITS.audio.channels;

function isFloat32Array(value: unknown): value is Float32Array {
  return Object.prototype.toString.call(value) === "[object Float32Array]";
}

function assertBlock(block: MixedAudioBlock): void {
  if (!Number.isSafeInteger(block.firstSample) || block.firstSample < 0) {
    throw new RangeError(`block.firstSample must be a non-negative safe integer: ${String(block.firstSample)}`);
  }
  if (!Number.isSafeInteger(block.frames) || block.frames < 1) {
    throw new RangeError(`block.frames must be a positive safe integer: ${String(block.frames)}`);
  }
  if (!isFloat32Array(block.pcm) || block.pcm.length !== block.frames * CHANNELS) {
    throw new RangeError(`block.pcm must be a Float32Array of frames x ${CHANNELS} samples (interleaved)`);
  }
}

export class AudioEncoderPipeline {
  private readonly options: AudioEncoderPipelineOptions;
  private readonly decoderConfigs = new DecoderConfigHolder("audio");
  private state: State = "idle";
  private encoder: AudioEncoder | null = null;

  /** 次に期待するブロックの累積サンプル数（前のブロックの続き）。まだ入力が無ければ null */
  private nextInputSample: number | null = null;
  /** 次の出力チャンクが始まる累積サンプル数。最初のブロックの累積サンプル数から始まる。まだ入力が無ければ null */
  private outputCursorSample: number | null = null;
  private encodedSamples = 0;

  constructor(options: AudioEncoderPipelineOptions) {
    this.options = options;
  }

  get isConfigured(): boolean {
    return this.state === "configured";
  }

  get isFaulted(): boolean {
    return this.state === "faulted";
  }

  get hasDecoderConfig(): boolean {
    return this.decoderConfigs.has;
  }

  /** 符号化に渡したサンプル数（累計。チャンネルあたり）。 */
  get encodedSampleCount(): number {
    return this.encodedSamples;
  }

  /**
   * エンコーダを設定する。配信の開始時に 1 回だけ。使えなければ audio_config_unsupported（エンコーダは作らない）。
   * 設定済みなら invalid_state。
   */
  async configure(): Promise<void> {
    if (this.state !== "idle") {
      throw new PipelineError("invalid_state");
    }
    const config = buildAudioEncoderConfig();
    this.state = "configuring";
    try {
      await this.requireSupported(config);
      if (this.state !== "configuring") {
        // 確かめている間に、close された
        throw new PipelineError("invalid_state");
      }
      const encoder = new this.options.AudioEncoder({
        output: (chunk, metadata) => this.handleOutput(chunk, metadata),
        error: (error) => this.fail(error),
      });
      try {
        encoder.configure(config);
      } catch (error) {
        if (encoder.state !== "closed") {
          encoder.close();
        }
        throw new PipelineError("audio_config_unsupported", error);
      }
      this.encoder = encoder;
      this.state = "configured";
    } catch (error) {
      if (this.state === "configuring") {
        this.state = "idle";
      }
      throw error;
    }
  }

  /**
   * #26 のブロック（インターリーブの f32）を符号化に渡す。AudioData の時刻は audioTime(ブロックの累積サンプル数)。
   * ブロックが前のブロックの続きでなければ audio_continuity_lost の故障（以後は符号化しない）。故障・エンコーダの失敗は例外にしない
   * （音声のクロックを止めない）。ブロックの形の不備は RangeError、設定の前・close のあとは not_configured。
   */
  encode(block: MixedAudioBlock): void {
    assertBlock(block);
    if (this.state === "faulted") {
      return;
    }
    const encoder = this.encoder;
    if (this.state !== "configured" || encoder === null) {
      throw new PipelineError("not_configured");
    }
    if (this.nextInputSample !== null && block.firstSample !== this.nextInputSample) {
      this.fail(new PipelineError("audio_continuity_lost"));
      return;
    }
    if (this.outputCursorSample === null) {
      this.outputCursorSample = block.firstSample;
    }
    let data: AudioData | null = null;
    try {
      data = new this.options.AudioData({
        format: "f32",
        sampleRate: LIMITS.audio.sample_rate_hz,
        numberOfChannels: CHANNELS,
        numberOfFrames: block.frames,
        timestamp: audioTimeUs(block.firstSample),
        // Worklet が転送した通常の ArrayBuffer（共有メモリではない）。AudioData は、作成時にコピーを持つ
        data: block.pcm as Float32Array<ArrayBuffer>,
      });
      encoder.encode(data);
      this.nextInputSample = block.firstSample + block.frames;
      this.encodedSamples += block.frames;
    } catch (error) {
      this.fail(error);
    } finally {
      data?.close();
    }
  }

  /** 復号器設定（音声: AudioSpecificConfig）。コピーを返す。まだ得ていなければ decoder_config_unavailable。 */
  configChunk(): DecoderConfigChunk {
    return this.decoderConfigs.current();
  }

  /** 復号器設定を得るまで待つ（最初の出力）。得たあとなら、すぐ解決する。故障・close で拒否される。 */
  whenDecoderConfig(): Promise<DecoderConfigChunk> {
    return this.decoderConfigs.wait();
  }

  /** エンコーダの出力を出し切る。故障したら、故障として通知する。 */
  async flush(): Promise<void> {
    const encoder = this.encoder;
    if (this.state !== "configured" || encoder === null) {
      return;
    }
    try {
      await encoder.flush();
    } catch (error) {
      this.fail(error);
    }
  }

  /** エンコーダを閉じて、資源を解放する。待っている呼び出しは、terminated で拒否される。何度呼んでもよい。 */
  close(): void {
    if (this.state === "closed") {
      return;
    }
    const encoder = this.encoder;
    this.state = "closed";
    this.encoder = null;
    this.decoderConfigs.rejectAll(new PipelineError("terminated"));
    if (encoder !== null && encoder.state !== "closed") {
      encoder.close();
    }
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  private async requireSupported(config: ReturnType<typeof buildAudioEncoderConfig>): Promise<void> {
    let supported: boolean;
    try {
      const support = await this.options.AudioEncoder.isConfigSupported(config);
      supported = support.supported === true;
    } catch (error) {
      throw new PipelineError("audio_config_unsupported", error);
    }
    if (!supported) {
      throw new PipelineError("audio_config_unsupported");
    }
  }

  private handleOutput(chunk: EncodedAudioChunk, metadata?: EncodedAudioChunkMetadata): void {
    if (this.state === "faulted" || this.state === "closed") {
      return;
    }
    try {
      const data = new Uint8Array(chunk.byteLength);
      chunk.copyTo(data);
      if (metadata?.decoderConfig !== undefined) {
        this.decoderConfigs.accept(metadata.decoderConfig);
      }
      const cursor = this.outputCursorSample;
      if (cursor === null) {
        // 入力より先に出力が来ることは無い。時刻の起点が無いので、推測せず失敗にする
        throw new PipelineError("invalid_state");
      }
      this.outputCursorSample = cursor + AAC_SAMPLES_PER_FRAME;
      this.options.onChunk(createEncodedChunk({ kind: "audio", timestampUs: audioTimeUs(cursor), keyframe: false, data }));
    } catch (error) {
      this.fail(error);
    }
  }

  /** 故障を 1 回だけ通知する。以後の入力は符号化しない。エンコーダは、close で閉じる。 */
  private fail(error: unknown): void {
    if (this.state === "faulted" || this.state === "closed") {
      return;
    }
    const failure = error instanceof PipelineError ? error : new PipelineError("audio_encoder_error", error);
    this.state = "faulted";
    this.decoderConfigs.rejectAll(failure);
    this.options.onFault(faultOf(failure));
  }
}
