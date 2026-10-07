/**
 * @jest-environment node
 */
// 開始通知の本文の組み立て（ws-protocol.md の 5.3）。プロファイルを決めると、映像の幅・高さ・フレームレートと、音声の設定は、契約の値で決まる。
// 呼び出し側が渡すのは、プロファイル・映像のコーデックとビットレート・復号器設定（バイト列。base64 にするのはここ）だけ。
import { LIMITS } from "../contract";
import { decodeBase64, encodeBase64 } from "./base64";
import { isFrameError } from "./errors";
import { buildStartBody } from "./startBody";

// 契約の共有テストベクタ（start_720p・start_480p_constrained_baseline）の、復号器設定
const VIDEO_720P_DESCRIPTION = decodeBase64("AU1AH//hAA9nTUAfllQFAe2AoEA8IhEBAARo7jyA");
const VIDEO_480P_DESCRIPTION = decodeBase64("AU1AH//hABBnTUAfllQDAf6AoEA8IhGoAQAEaO48gA==");
const AUDIO_DESCRIPTION = Uint8Array.from([0x12, 0x10]);

describe("buildStartBody", () => {
  test("720p：契約のベクタ（start_720p）と、同じ本文（キーの順まで）", () => {
    const body = buildStartBody({
      profile: "720p",
      videoCodec: LIMITS.video.codec_main,
      videoBitrateKbps: 4500,
      videoDescription: VIDEO_720P_DESCRIPTION,
      audioDescription: AUDIO_DESCRIPTION,
    });
    expect(JSON.stringify(body)).toBe(
      '{"profile":"720p","video":{"codec":"avc1.4D401F","width":1280,"height":720,"framerate":30,"bitrate_kbps":4500,"description_b64":"AU1AH//hAA9nTUAfllQFAe2AoEA8IhEBAARo7jyA"},"audio":{"codec":"mp4a.40.2","sample_rate":44100,"channels":2,"bitrate_kbps":128,"description_b64":"EhA="}}',
    );
  });

  test("480p・Constrained Baseline：契約のベクタ（start_480p_constrained_baseline）と同じ本文", () => {
    const body = buildStartBody({
      profile: "480p",
      videoCodec: LIMITS.video.codec_constrained_baseline,
      videoBitrateKbps: 1500,
      videoDescription: VIDEO_480P_DESCRIPTION,
      audioDescription: AUDIO_DESCRIPTION,
    });
    expect(JSON.stringify(body)).toBe(
      '{"profile":"480p","video":{"codec":"avc1.42E01F","width":854,"height":480,"framerate":30,"bitrate_kbps":1500,"description_b64":"AU1AH//hABBnTUAfllQDAf6AoEA8IhGoAQAEaO48gA=="},"audio":{"codec":"mp4a.40.2","sample_rate":44100,"channels":2,"bitrate_kbps":128,"description_b64":"EhA="}}',
    );
  });

  test("復号器設定は、base64 にする（往復で同じバイト列）", () => {
    const body = buildStartBody({ profile: "720p", videoCodec: LIMITS.video.codec_main, videoBitrateKbps: 3000, videoDescription: VIDEO_720P_DESCRIPTION, audioDescription: AUDIO_DESCRIPTION });
    expect(body.video.description_b64).toBe(encodeBase64(VIDEO_720P_DESCRIPTION));
    expect(Array.from(decodeBase64(body.audio.description_b64))).toEqual([0x12, 0x10]);
  });

  test("映像ビットレートは、プロファイルの下限から上限まで（720p は 3,000 から 6,000）。範囲外は invalid_body", () => {
    const build = (videoBitrateKbps: number) =>
      buildStartBody({ profile: "720p", videoCodec: LIMITS.video.codec_main, videoBitrateKbps, videoDescription: VIDEO_720P_DESCRIPTION, audioDescription: AUDIO_DESCRIPTION });
    expect(build(3000).video.bitrate_kbps).toBe(3000);
    expect(build(6000).video.bitrate_kbps).toBe(6000);
    for (const outOfRange of [2999, 6001, 0, -1, 4500.5]) {
      let thrown: unknown;
      try {
        build(outOfRange);
      } catch (error) {
        thrown = error;
      }
      expect(isFrameError(thrown) && thrown.code).toBe("invalid_body");
    }
  });

  test("復号器設定が空なら invalid_body（最初のメディアフレームより前に、復号器設定が要る）", () => {
    let thrown: unknown;
    try {
      buildStartBody({ profile: "720p", videoCodec: LIMITS.video.codec_main, videoBitrateKbps: 4500, videoDescription: new Uint8Array(0), audioDescription: AUDIO_DESCRIPTION });
    } catch (error) {
      thrown = error;
    }
    expect(isFrameError(thrown) && thrown.code).toBe("invalid_body");
  });

  test("未知のプロファイル・映像のコーデックは invalid_body", () => {
    for (const override of [{ profile: "1080p" }, { videoCodec: "avc1.640028" }]) {
      let thrown: unknown;
      try {
        buildStartBody({ profile: "720p", videoCodec: LIMITS.video.codec_main, videoBitrateKbps: 4500, videoDescription: VIDEO_720P_DESCRIPTION, audioDescription: AUDIO_DESCRIPTION, ...override } as never);
      } catch (error) {
        thrown = error;
      }
      expect(isFrameError(thrown) && thrown.code).toBe("invalid_body");
    }
  });

  test("復号器設定が Uint8Array でなければ invalid_body", () => {
    let thrown: unknown;
    try {
      buildStartBody({ profile: "720p", videoCodec: LIMITS.video.codec_main, videoBitrateKbps: 4500, videoDescription: "abc" as unknown as Uint8Array, audioDescription: AUDIO_DESCRIPTION });
    } catch (error) {
      thrown = error;
    }
    expect(isFrameError(thrown) && thrown.code).toBe("invalid_body");
  });
});
