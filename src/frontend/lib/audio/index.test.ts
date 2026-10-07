// 公開 API（lib/audio と lib/sources の index.ts）。後続の issue（#27・#28・#29）が import する入口が、そろっていること。
import * as audio from "./index";
import * as sources from "@/lib/sources";

describe("lib/audio の公開 API", () => {
  it("クラス・関数・定数が、入口から取り出せる", () => {
    for (const name of ["AudioMixer", "AudioClockDriver", "bindSourcesToMixer", "createBrowserAudioEnvironment", "createMixerParameters", "createMixerState", "mixBlock", "setTargetGain", "interleave", "deinterleave", "isMixerInputKind"] as const) {
      expect(typeof audio[name]).toBe("function");
    }
    expect(audio.MIXER_INPUT_KINDS).toEqual(["microphone", "shared_audio"]);
    expect(audio.DEFAULT_MIXER_GAINS.shared_audio).toBe(0.6);
    expect(audio.MIXER_SAMPLE_RATE_HZ).toBe(44_100);
    expect(audio.AUDIO_MIXER_ERROR_CODES.length).toBeGreaterThan(0);
  });

  it("テストの道具は、公開しない", () => {
    expect(Object.keys(audio).some((name) => name.startsWith("Fake") || name === "loadStreamMixerWorklet")).toBe(false);
  });
});

describe("lib/sources の公開 API", () => {
  it("クラス・関数・定数が、入口から取り出せる", () => {
    expect(typeof sources.SourceManager).toBe("function");
    expect(typeof sources.DeviceCatalog).toBe("function");
    expect(typeof sources.SourceError).toBe("function");
    expect(typeof sources.isSourceError).toBe("function");
    expect(typeof sources.createConsoleDiagnosticSink).toBe("function");
    expect(sources.MANAGED_SOURCE_KINDS).toEqual(["camera", "screen", "microphone", "shared_audio"]);
    expect(sources.ATTACHABLE_SOURCE_KINDS).toEqual(["camera", "screen", "microphone"]);
    expect(sources.SOURCE_REASON_VALUES).toContain("no_audio_track");
  });

  it("テストの道具は、公開しない", () => {
    expect(Object.keys(sources).some((name) => name.startsWith("Fake") || name === "flushPromises" || name === "domError")).toBe(false);
  });
});
