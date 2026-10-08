// VideoEncoderPipeline（requirements.md 11.7・12。issue #27）。H.264 の映像エンコード（WebCodecs の VideoEncoder）。ワーカーの上で動く。
//
//   設定        コーデックは能力検出（#24）の結果に従い、呼び出し側が渡す（Main か、Main が使えない環境の Constrained Baseline）。
//               プロファイルの解像度・30 fps・固定ビットレート・低遅延（並べ替えフレームを作らない）・avc 形式（AVCC）。
//               設定の前に isConfigSupported で確かめ、使えなければ video_config_unsupported（別のコーデックへ黙って切り替えない）
//   プロファイル 配信の開始時に確定し、配信中に変更しない。2 回目の configure は invalid_state。再設定できるのはビットレートだけ（setBitrate）
//   キーフレーム 2 秒（メディア時刻）ごとに keyFrame: true（60 フレームごと）。forceKeyframe で、次に符号化するフレームを、キーフレームにする。
//               キーフレームの要否は、前のキーフレーム（要求したもの・エンコーダが実際に出したもの）からの、メディア時刻の経過で判定する
//   入力待ち    encodeQueueSize が 2 を超えるとき、当該フレームを符号化せず捨てる（実時間性を優先）。符号化の前に捨てるので、参照の連鎖を壊さない
//               （差分フレームは、符号化した最後のフレームを参照する）。捨てた数を数える。要求したキーフレームの番だったフレームを捨てたときは、
//               要求を残し、次に符号化するフレームで満たす
//   再設定      setBitrate は、同じ設定でビットレートだけを変えて configure し直す。パイプラインは、キーフレームを強制しない。
//               エンコーダが再設定でキーフレーム（IDR）を出したときは、チャンクをそのまま渡し、定期のキーフレームの起点にする（実際に出た時刻から 2 秒後）。
//               再設定の最初の出力に付く decoderConfig の内容が変わったら、onDecoderConfigChanged で通知する（中継へ設定を再送するのは #28）
//   復号器設定  decoderConfig.description（AVCDecoderConfigurationRecord）を、最初の出力で得て保持する。configChunk で返す（コピー）。
//               形が正しくなければ decoder_config_missing の故障（黙って空の設定を送らない）
//   時刻        出力チャンクの時刻は、入力フレームの timestamp（videoTime(フレーム番号)）のまま。実時計で採番しない。
//               latencyMode: realtime のエンコーダは、内部でフレームを間引き得るので、入力 1 フレーム = 出力 1 チャンクを前提にしない
//               （破棄の数は、入力の側で数える。出力の不足を、破棄と見なさない）
//   エラー      error コールバック・例外を、型付きの故障として onFault へ通知する（1 回だけ。黙って止まらない）。以後のフレームは符号化せず、閉じる
//   解放        encode に渡されたフレームは、符号化に渡した直後（捨てたときも、失敗したときも）に close する。close でエンコーダを閉じる
//
// 実時計（Date・performance）を使わない。VideoEncoder のコンストラクタは注入される。

import type { VideoCodec } from "@/core/transport";
import type { Profile } from "@/core/contract";
import { createEncodedChunk } from "@/lib/pipeline/chunks";
import type { DecoderConfigChunk, EncodedChunk } from "@/lib/pipeline/chunks";
import { ENCODER_QUEUE_MAX_FRAMES, KEYFRAME_INTERVAL_US } from "@/lib/pipeline/config";
import { buildVideoEncoderConfig } from "@/lib/pipeline/encoderConfig";
import { PipelineError, faultOf } from "@/lib/pipeline/errors";
import type { PipelineFault } from "@/lib/pipeline/errors";
import { DecoderConfigHolder } from "./DecoderConfigHolder";

export interface VideoEncoderPipelineOptions {
  /** WebCodecs の VideoEncoder（ワーカーの大域のものを、環境から渡す） */
  readonly VideoEncoder: typeof VideoEncoder;
  /** 符号化結果。ゲート（ChunkGate）を通すかどうかは、呼び出し側が決める */
  readonly onChunk: (chunk: EncodedChunk) => void;
  /** 故障（エンコーダのエラー・設定の失敗・復号器設定の不備）。1 回だけ通知する */
  readonly onFault: (fault: PipelineFault) => void;
  /** 復号器設定の内容が、最初に得たものから変わった（再設定のあと）。中継へ設定を再送する必要がある */
  readonly onDecoderConfigChanged?: (config: DecoderConfigChunk) => void;
}

/**
 *   encoded              符号化に渡した
 *   dropped_queue_full   入力待ちが 2 フレームを超えていたので、符号化せず捨てた（破棄フレーム数に数える）
 *   skipped_faulted      故障のあとなので、符号化しなかった
 */
export type VideoEncodeOutcome = "encoded" | "dropped_queue_full" | "skipped_faulted";

type State = "idle" | "configuring" | "configured" | "faulted" | "closed";

export class VideoEncoderPipeline {
  private readonly options: VideoEncoderPipelineOptions;
  private state: State = "idle";
  private encoder: VideoEncoder | null = null;
  private currentProfile: Profile | null = null;
  private currentCodec: VideoCodec | null = null;
  private currentBitrateKbps: number | null = null;

  private readonly decoderConfigs: DecoderConfigHolder;

  /** 前のキーフレーム（要求したもの・エンコーダが出したもの）の時刻。まだ無ければ null */
  private lastKeyTimeUs: number | null = null;
  private forcePending = false;

  private encoded = 0;
  private dropped = 0;

  constructor(options: VideoEncoderPipelineOptions) {
    this.options = options;
    this.decoderConfigs = new DecoderConfigHolder("video", (config) => options.onDecoderConfigChanged?.(config));
  }

  get isConfigured(): boolean {
    return this.state === "configured";
  }

  get isFaulted(): boolean {
    return this.state === "faulted";
  }

  get profile(): Profile | null {
    return this.currentProfile;
  }

  get codec(): VideoCodec | null {
    return this.currentCodec;
  }

  /** 現在の映像ビットレート（kbps）。 */
  get bitrateKbps(): number | null {
    return this.currentBitrateKbps;
  }

  get hasDecoderConfig(): boolean {
    return this.decoderConfigs.has;
  }

  /** 符号化に渡したフレームの数（累計）。 */
  get encodedFrameCount(): number {
    return this.encoded;
  }

  /** 入力待ちが 2 フレームを超えたため、符号化せず捨てたフレームの数（累計）。健全性の「破棄フレーム数」へ渡す。 */
  get droppedBeforeEncodeCount(): number {
    return this.dropped;
  }

  /** エンコーダの入力待ちのフレーム数（設定の前は 0）。 */
  get encodeQueueSize(): number {
    return this.encoder?.encodeQueueSize ?? 0;
  }

  /**
   * エンコーダを設定する。配信の開始時に 1 回だけ（プロファイルは、配信中に変更しない）。
   * 設定が使えなければ video_config_unsupported（エンコーダは作らない。呼び出し側が、別のコーデックで configure し直してよい）。
   */
  async configure(profile: Profile, codec: VideoCodec, videoBitrateKbps: number): Promise<void> {
    if (this.state !== "idle") {
      throw new PipelineError("invalid_state");
    }
    const config = buildVideoEncoderConfig(profile, codec, videoBitrateKbps);
    this.state = "configuring";
    try {
      await this.requireSupported(config);
      if (this.state !== "configuring") {
        // 確かめている間に、close された
        throw new PipelineError("invalid_state");
      }
      const encoder = new this.options.VideoEncoder({
        output: (chunk, metadata) => this.handleOutput(chunk, metadata),
        error: (error) => this.fail(error),
      });
      try {
        encoder.configure(config);
      } catch (error) {
        if (encoder.state !== "closed") {
          encoder.close();
        }
        throw new PipelineError("video_config_unsupported", error);
      }
      this.encoder = encoder;
      this.currentProfile = profile;
      this.currentCodec = codec;
      this.currentBitrateKbps = videoBitrateKbps;
      this.state = "configured";
    } catch (error) {
      if (this.state === "configuring") {
        this.state = "idle";
      }
      throw error;
    }
  }

  /**
   * 1 枚のフレームを符号化に渡す。フレームの時刻（timestamp。マイクロ秒）が、出力チャンクの時刻になる。
   * フレームは、この呼び出しの中で、必ず close する（符号化に渡したあと・捨てたとき・失敗したとき）。
   * 設定の前・close のあとは not_configured（フレームは閉じる）。
   */
  encode(frame: VideoFrame): VideoEncodeOutcome {
    try {
      if (this.state === "faulted") {
        return "skipped_faulted";
      }
      const encoder = this.encoder;
      if (this.state !== "configured" || encoder === null) {
        throw new PipelineError("not_configured");
      }
      if (encoder.encodeQueueSize > ENCODER_QUEUE_MAX_FRAMES) {
        this.dropped += 1;
        return "dropped_queue_full";
      }
      const timestampUs = frame.timestamp;
      const keyFrame = this.keyframeDue(timestampUs);
      try {
        encoder.encode(frame, { keyFrame });
      } catch (error) {
        this.fail(error);
        return "skipped_faulted";
      }
      this.encoded += 1;
      if (keyFrame) {
        this.forcePending = false;
        this.noteKeyframe(timestampUs);
      }
      return "encoded";
    } finally {
      frame.close();
    }
  }

  /** 次に符号化するフレームを、キーフレームにする（滞留 4 秒超・復帰時のキーフレーム要求）。そのフレームが符号化されるまで、要求は残る。 */
  forceKeyframe(): void {
    this.forcePending = true;
  }

  /**
   * 映像ビットレートの目標を変える（kbps の整数で、プロファイルの下限から上限の範囲。範囲外は bitrate_out_of_range）。
   * 同じコーデック・解像度・低遅延・固定のまま、ビットレートだけを変えて、エンコーダを configure し直す。キーフレームは強制しない
   * （エンコーダが再設定でキーフレームを出したときは、そのまま渡す）。設定の前は not_configured、故障のあとは invalid_state。
   */
  setBitrate(kbps: number): void {
    const encoder = this.encoder;
    if (this.state === "faulted") {
      throw new PipelineError("invalid_state");
    }
    if (this.state !== "configured" || encoder === null || this.currentProfile === null || this.currentCodec === null) {
      throw new PipelineError("not_configured");
    }
    const config = buildVideoEncoderConfig(this.currentProfile, this.currentCodec, kbps);
    try {
      encoder.configure(config);
    } catch (error) {
      this.fail(error);
      return;
    }
    this.currentBitrateKbps = kbps;
  }

  /** 復号器設定（映像: AVCDecoderConfigurationRecord）。コピーを返す。まだ得ていなければ decoder_config_unavailable。 */
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

  private async requireSupported(config: ReturnType<typeof buildVideoEncoderConfig>): Promise<void> {
    let supported: boolean;
    try {
      const support = await this.options.VideoEncoder.isConfigSupported(config);
      supported = support.supported === true;
    } catch (error) {
      throw new PipelineError("video_config_unsupported", error);
    }
    if (!supported) {
      throw new PipelineError("video_config_unsupported");
    }
  }

  /** キーフレームを出すべきか。要求がある・まだキーフレームを出していない・前のキーフレームから 2 秒（メディア時刻）が経った。 */
  private keyframeDue(timestampUs: number): boolean {
    return this.forcePending || this.lastKeyTimeUs === null || timestampUs - this.lastKeyTimeUs >= KEYFRAME_INTERVAL_US;
  }

  private noteKeyframe(timestampUs: number): void {
    this.lastKeyTimeUs = this.lastKeyTimeUs === null ? timestampUs : Math.max(this.lastKeyTimeUs, timestampUs);
  }

  private handleOutput(chunk: EncodedVideoChunk, metadata?: EncodedVideoChunkMetadata): void {
    if (this.state === "faulted" || this.state === "closed") {
      return;
    }
    try {
      const data = new Uint8Array(chunk.byteLength);
      chunk.copyTo(data);
      const keyframe = chunk.type === "key";
      if (metadata?.decoderConfig !== undefined) {
        this.decoderConfigs.accept(metadata.decoderConfig);
      }
      if (keyframe) {
        this.noteKeyframe(chunk.timestamp);
      }
      this.options.onChunk(createEncodedChunk({ kind: "video", timestampUs: chunk.timestamp, keyframe, data }));
    } catch (error) {
      this.fail(error);
    }
  }

  /** 故障を 1 回だけ通知する。以後のフレームは符号化しない。エンコーダは、close で閉じる。 */
  private fail(error: unknown): void {
    if (this.state === "faulted" || this.state === "closed") {
      return;
    }
    const failure = error instanceof PipelineError ? error : new PipelineError("video_encoder_error", error);
    this.state = "faulted";
    this.decoderConfigs.rejectAll(failure);
    this.options.onFault(faultOf(failure));
  }
}
