/**
 * @jest-environment node
 */
// エンコーダの設定（requirements.md 11.7。issue #27）。映像: H.264（Main か Constrained Baseline）・低遅延（並べ替えフレームを作らない）・固定ビットレート・
// avc 形式（AVCC）。音声: AAC-LC・44.1 kHz・2 ch・128 kbps・aac 形式（生のフレーム。ADTS なし）。
// 能力検出（core/capability。#24）が問い合わせた設定と、実際に configure する設定が食い違うと、「使えると確かめた設定」と違う設定で動くことになる。
// その一致を、実際の検出（readBrowserCapabilities）に疑似のエンコーダを渡して、確かめる。
import { PROFILE_VALUES, LIMITS } from "@/core/contract";
import { readBrowserCapabilities } from "@/core/capability";
import { PipelineError } from "./errors";
import { buildAudioEncoderConfig, buildVideoEncoderConfig } from "./encoderConfig";

const MAIN = LIMITS.video.codec_main;
const BASELINE = LIMITS.video.codec_constrained_baseline;

describe("buildVideoEncoderConfig", () => {
  it("720p・Main・初期ビットレート: 低遅延・固定ビットレート・AVCC・30 fps", () => {
    expect(buildVideoEncoderConfig("720p", MAIN, 4500)).toEqual({
      codec: "avc1.4D401F",
      width: 1280,
      height: 720,
      bitrate: 4_500_000,
      framerate: 30,
      bitrateMode: "constant",
      latencyMode: "realtime",
      avc: { format: "avc" },
    });
  });

  it("480p・Constrained Baseline: 解像度とコーデックが変わる", () => {
    expect(buildVideoEncoderConfig("480p", BASELINE, 1500)).toEqual({
      codec: "avc1.42E01F",
      width: 854,
      height: 480,
      bitrate: 1_500_000,
      framerate: 30,
      bitrateMode: "constant",
      latencyMode: "realtime",
      avc: { format: "avc" },
    });
  });

  it("ビットレートは kbps で受け取り、bit/s の整数で設定する（プロファイルの下限・上限を含めて受理する）", () => {
    expect(buildVideoEncoderConfig("720p", MAIN, 3000).bitrate).toBe(3_000_000);
    expect(buildVideoEncoderConfig("720p", MAIN, 6000).bitrate).toBe(6_000_000);
    expect(buildVideoEncoderConfig("480p", MAIN, 800).bitrate).toBe(800_000);
    expect(buildVideoEncoderConfig("480p", MAIN, 2500).bitrate).toBe(2_500_000);
  });

  it.each([
    ["720p の下限未満", "720p" as const, 2999],
    ["720p の上限超過", "720p" as const, 6001],
    ["480p の下限未満", "480p" as const, 799],
    ["480p の上限超過", "480p" as const, 2501],
    ["小数", "720p" as const, 4500.5],
    ["NaN", "720p" as const, Number.NaN],
    ["0", "720p" as const, 0],
  ])("ビットレートが範囲外なら bitrate_out_of_range（%s）", (_name, profile, kbps) => {
    expect(() => buildVideoEncoderConfig(profile, MAIN, kbps)).toThrow(PipelineError);
    try {
      buildVideoEncoderConfig(profile, MAIN, kbps);
    } catch (error) {
      expect((error as PipelineError).code).toBe("bitrate_out_of_range");
    }
  });

  it("未知のプロファイル・コーデックは RangeError（推測しない）", () => {
    expect(() => buildVideoEncoderConfig("1080p" as never, MAIN, 4500)).toThrow(RangeError);
    expect(() => buildVideoEncoderConfig("720p", "avc1.640028" as never, 4500)).toThrow(RangeError);
  });

  it("結果は凍結されている（設定を書き換えて、検出した設定と食い違わせない）", () => {
    const config = buildVideoEncoderConfig("720p", MAIN, 4500);

    expect(Object.isFrozen(config)).toBe(true);
    expect(Object.isFrozen(config.avc)).toBe(true);
  });
});

describe("buildAudioEncoderConfig", () => {
  it("AAC-LC・44.1 kHz・2 ch・128 kbps・aac 形式（生のフレーム。ADTS なし）", () => {
    expect(buildAudioEncoderConfig()).toEqual({
      codec: "mp4a.40.2",
      sampleRate: 44_100,
      numberOfChannels: 2,
      bitrate: 128_000,
      aac: { format: "aac" },
    });
  });

  it("結果は凍結されている", () => {
    expect(Object.isFrozen(buildAudioEncoderConfig())).toBe(true);
  });
});

describe("能力検出（#24）が問い合わせた設定と一致する", () => {
  /** isConfigSupported に渡された設定を記録する、疑似のエンコーダ。 */
  function recordingEncoder(): { encoder: { isConfigSupported(config: unknown): Promise<{ supported: boolean }> }; configs: unknown[] } {
    const configs: unknown[] = [];
    return {
      configs,
      encoder: {
        isConfigSupported: (config: unknown) => {
          configs.push(config);
          return Promise.resolve({ supported: true });
        },
      },
    };
  }

  it("映像: 検出が使えると確かめた、全プロファイルの設定（初期ビットレート）と同じ", async () => {
    const video = recordingEncoder();
    const audio = recordingEncoder();

    const report = await readBrowserCapabilities({ VideoEncoder: video.encoder, AudioEncoder: audio.encoder });

    expect(report.videoCodec).toBe(MAIN);
    const expected = PROFILE_VALUES.map((profile) => buildVideoEncoderConfig(profile, MAIN, LIMITS.profiles[profile].video_bitrate_initial_kbps));
    expect(video.configs).toEqual(expected);
  });

  it("音声: 検出が使えると確かめた設定と同じ", async () => {
    const video = recordingEncoder();
    const audio = recordingEncoder();

    await readBrowserCapabilities({ VideoEncoder: video.encoder, AudioEncoder: audio.encoder });

    expect(audio.configs).toEqual([buildAudioEncoderConfig()]);
  });
});
