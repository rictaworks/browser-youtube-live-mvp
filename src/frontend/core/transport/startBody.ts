// 開始通知の本文の組み立て（ws-protocol.md の 5.3）。
// プロファイルを決めると、映像の幅・高さ・フレームレートと、音声の設定（AAC-LC・44.1 kHz・2 ch・128 kbps）は、契約（LIMITS）の値で決まる。
// 呼び出し側（エンコーダの配線）が渡すのは、プロファイル・映像のコーデックとビットレートの開始値・復号器設定（バイト列）だけ。
// 復号器設定は、ここで base64 にする。組み立てた本文は、parseStartBody で検証する（ビットレートがプロファイルの範囲外・復号器設定が空、などは invalid_body）。

import { LIMITS, PROFILE_VALUES, isProfile } from "../contract";
import type { Profile } from "../contract";
import { encodeBase64 } from "./base64";
import { parseStartBody } from "./bodies";
import { isUint8Array } from "./bytes";
import { FrameError } from "./errors";
import type { StartBody, VideoCodec } from "./messages";

export interface StartBodyInput {
  /** 開始時に確定したプロファイル。復帰では、確定済みのプロファイル */
  readonly profile: Profile;
  /** 映像のコーデック：Main（avc1.4D401F）、または、Main が使えない環境の Constrained Baseline（avc1.42E01F） */
  readonly videoCodec: VideoCodec;
  /** 映像ビットレートの開始値（kbps。プロファイルの下限から上限の範囲） */
  readonly videoBitrateKbps: number;
  /** 映像の復号器設定（AVCDecoderConfigurationRecord） */
  readonly videoDescription: Uint8Array;
  /** 音声の復号器設定（AudioSpecificConfig。AAC-LC・44.1 kHz・2 ch は 0x12 0x10） */
  readonly audioDescription: Uint8Array;
}

function requireBytes(value: unknown, path: string): Uint8Array {
  if (!isUint8Array(value)) {
    throw new FrameError("invalid_body", `${path}: the decoder configuration must be a Uint8Array`);
  }
  return value;
}

/** 開始通知の本文を組み立てる。不備は FrameError（invalid_body）。 */
export function buildStartBody(input: StartBodyInput): StartBody {
  if (!isProfile(input.profile)) {
    throw new FrameError("invalid_body", `start.profile: must be one of ${PROFILE_VALUES.join(", ")}`);
  }
  const limits = LIMITS.profiles[input.profile];
  return parseStartBody({
    profile: input.profile,
    video: {
      codec: input.videoCodec,
      width: limits.width,
      height: limits.height,
      framerate: limits.framerate,
      bitrate_kbps: input.videoBitrateKbps,
      description_b64: encodeBase64(requireBytes(input.videoDescription, "start.video.description_b64")),
    },
    audio: {
      codec: LIMITS.audio.codec,
      sample_rate: LIMITS.audio.sample_rate_hz,
      channels: LIMITS.audio.channels,
      bitrate_kbps: LIMITS.audio.bitrate_kbps,
      description_b64: encodeBase64(requireBytes(input.audioDescription, "start.audio.description_b64")),
    },
  });
}
