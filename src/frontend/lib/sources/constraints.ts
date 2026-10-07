// 取得の制約（requirements.md 11.2）。
//   カメラ  getUserMedia({video: {deviceId, ...}})。解像度・フレームレートは、標準（720p）プロファイルの値を、望ましい値（ideal）として求める
//   マイク  getUserMedia({audio: {deviceId, echoCancellation: true, noiseSuppression: true}})。エコー除去・雑音抑制を適用する
//   画面共有・共有音声  getDisplayMedia({video: true, audio: true})。共有音声は、映像と同じ取得の音声トラック
// 配信者自身への音声の折り返し再生は、行わない（取得した音声を、<audio> や出力先へ接続しない）。ここは制約を作るだけで、再生に関わらない。
// デバイスの識別子は exact で指定する。見つからないとき、黙って別のデバイスへ切り替えず、OverconstrainedError にする（フォールバックしない）。

import { LIMITS } from "@/core/contract";

const CAMERA_PROFILE = LIMITS.profiles["720p"];

/** デバイスの識別子の指定。省略・空文字列（権限の取得前の列挙が返す値）は、指定なし。 */
function exactDevice(deviceId: string | undefined): { deviceId?: { exact: string } } {
  return deviceId === undefined || deviceId === "" ? {} : { deviceId: { exact: deviceId } };
}

export function buildCameraConstraints(deviceId?: string): MediaStreamConstraints {
  return {
    video: {
      ...exactDevice(deviceId),
      width: { ideal: CAMERA_PROFILE.width },
      height: { ideal: CAMERA_PROFILE.height },
      frameRate: { ideal: CAMERA_PROFILE.framerate },
    },
  };
}

export function buildMicrophoneConstraints(deviceId?: string): MediaStreamConstraints {
  return {
    audio: {
      ...exactDevice(deviceId),
      echoCancellation: true,
      noiseSuppression: true,
    },
  };
}

export function buildDisplayConstraints(): DisplayMediaStreamOptions {
  return { video: true, audio: true };
}
