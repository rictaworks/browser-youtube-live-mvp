// エンコーダの設定（requirements.md 11.7。issue #27）。値は、契約（core/contract の LIMITS）から取る。
//
//   映像  H.264（Main の avc1.4D401F、または Main が使えない環境の Constrained Baseline の avc1.42E01F。どちらかは、能力検出（#24）の結果に従う）・
//         プロファイルの解像度・30 fps・固定ビットレート（bitrateMode: constant）・低遅延（latencyMode: realtime = 並べ替えフレームを作らない）・
//         avc 形式（AVCC。各 NAL の前に 4 バイトの長さ。SPS・PPS は復号器設定 description で伝える）
//   音声  AAC-LC（mp4a.40.2）・44.1 kHz・2 ch・128 kbps・aac 形式（生のフレーム。ADTS なし。復号器設定 description は AudioSpecificConfig）
//
// 能力検出（core/capability の readBrowserCapabilities）が isConfigSupported で確かめた設定と、実際に configure する設定は、同じにする
// （使えると確かめた設定と違う設定で動かさない）。その一致は、encoderConfig.test.ts が、実際の検出を実行して保証する。

import { LIMITS, isProfile } from "@/core/contract";
import type { Profile } from "@/core/contract";
import type { AudioCodec, VideoCodec } from "@/core/transport";
import { PipelineError } from "./errors";

export interface VideoEncoderSettings {
  readonly codec: VideoCodec;
  readonly width: number;
  readonly height: number;
  /** bit/s */
  readonly bitrate: number;
  readonly framerate: number;
  readonly bitrateMode: "constant";
  readonly latencyMode: "realtime";
  readonly avc: { readonly format: "avc" };
}

export interface AudioEncoderSettings {
  readonly codec: AudioCodec;
  readonly sampleRate: number;
  readonly numberOfChannels: number;
  /** bit/s */
  readonly bitrate: number;
  readonly aac: { readonly format: "aac" };
}

const BITS_PER_KILOBIT = 1_000;

function isVideoCodec(value: unknown): value is VideoCodec {
  return value === LIMITS.video.codec_main || value === LIMITS.video.codec_constrained_baseline;
}

/**
 * 映像エンコーダの設定。videoBitrateKbps は kbps の整数で、プロファイルの下限から上限の範囲（範囲外・小数は bitrate_out_of_range）。
 * 未知のプロファイル・コーデックは RangeError。
 */
export function buildVideoEncoderConfig(profile: Profile, codec: VideoCodec, videoBitrateKbps: number): VideoEncoderSettings {
  if (!isProfile(profile)) {
    throw new RangeError(`unknown profile: ${String(profile)}`);
  }
  if (!isVideoCodec(codec)) {
    throw new RangeError(`unknown video codec: ${String(codec)}`);
  }
  const limits = LIMITS.profiles[profile];
  if (!Number.isInteger(videoBitrateKbps) || videoBitrateKbps < limits.video_bitrate_min_kbps || videoBitrateKbps > limits.video_bitrate_max_kbps) {
    throw new PipelineError("bitrate_out_of_range");
  }
  return Object.freeze({
    codec,
    width: limits.width,
    height: limits.height,
    bitrate: videoBitrateKbps * BITS_PER_KILOBIT,
    framerate: limits.framerate,
    bitrateMode: "constant",
    latencyMode: "realtime",
    avc: Object.freeze({ format: "avc" }),
  });
}

/** 音声エンコーダの設定（AAC-LC・44.1 kHz・2 ch・128 kbps・aac 形式）。 */
export function buildAudioEncoderConfig(): AudioEncoderSettings {
  return Object.freeze({
    codec: LIMITS.audio.codec,
    sampleRate: LIMITS.audio.sample_rate_hz,
    numberOfChannels: LIMITS.audio.channels,
    bitrate: LIMITS.audio.bitrate_kbps * BITS_PER_KILOBIT,
    aac: Object.freeze({ format: "aac" }),
  });
}
