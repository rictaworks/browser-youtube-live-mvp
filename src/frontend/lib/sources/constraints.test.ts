// 取得の制約（requirements.md 11.2）。
//   - カメラ: getUserMedia({video: {deviceId, ...}})
//   - マイク: getUserMedia({audio: {deviceId, echoCancellation: true, noiseSuppression: true, ...}})（エコー除去・雑音抑制を適用する）
//   - 画面共有と共有音声: getDisplayMedia({video: true, audio: true})（共有音声は、映像と同じ取得の音声トラック）
// デバイスの識別子は exact で指定する（見つからないとき、黙って別のデバイスへ切り替えず、OverconstrainedError にする）。
import { LIMITS } from "@/core/contract";
import { buildCameraConstraints, buildDisplayConstraints, buildMicrophoneConstraints } from "./constraints";

describe("buildCameraConstraints", () => {
  it("デバイスを指定しないとき、video に deviceId を含めない。音声は要求しない（audio を含めない）", () => {
    const constraints = buildCameraConstraints();

    expect(constraints.video).toBeDefined();
    expect(constraints).not.toHaveProperty("audio");
    expect(constraints.video).not.toHaveProperty("deviceId");
  });

  it("デバイスを指定すると、exact で指定する（見つからないとき、別のデバイスへ黙って切り替えない）", () => {
    expect(buildCameraConstraints("camera-id-1").video).toMatchObject({ deviceId: { exact: "camera-id-1" } });
  });

  it("空文字列の識別子は、指定なし（権限の取得前の列挙が返す値。特定のデバイスではない）", () => {
    expect(buildCameraConstraints("").video).not.toHaveProperty("deviceId");
  });

  it("解像度とフレームレートは、標準（720p）プロファイルの値を、望ましい値（ideal）として求める（必須にしない）", () => {
    const profile = LIMITS.profiles["720p"];

    expect(buildCameraConstraints().video).toMatchObject({
      width: { ideal: profile.width },
      height: { ideal: profile.height },
      frameRate: { ideal: profile.framerate },
    });
  });
});

describe("buildMicrophoneConstraints", () => {
  it("エコー除去と雑音抑制を適用する。映像は要求しない（video を含めない）", () => {
    const constraints = buildMicrophoneConstraints();

    expect(constraints.audio).toMatchObject({ echoCancellation: true, noiseSuppression: true });
    expect(constraints).not.toHaveProperty("video");
    expect(constraints.audio).not.toHaveProperty("deviceId");
  });

  it("デバイスを指定すると、exact で指定する。エコー除去・雑音抑制は、そのまま", () => {
    expect(buildMicrophoneConstraints("mic-id-1").audio).toMatchObject({
      deviceId: { exact: "mic-id-1" },
      echoCancellation: true,
      noiseSuppression: true,
    });
  });

  it("空文字列の識別子は、指定なし", () => {
    expect(buildMicrophoneConstraints("").audio).not.toHaveProperty("deviceId");
  });
});

describe("buildDisplayConstraints", () => {
  it("映像と音声を求める（共有音声は、映像と同じ取得の音声トラック）", () => {
    expect(buildDisplayConstraints()).toEqual({ video: true, audio: true });
  });

  it("呼ぶたびに、新しいオブジェクト（呼び出し側が書き換えても、次の呼び出しに影響しない）", () => {
    expect(buildDisplayConstraints()).not.toBe(buildDisplayConstraints());
  });
});
