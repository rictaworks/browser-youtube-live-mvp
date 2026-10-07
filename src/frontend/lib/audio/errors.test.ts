// 音声の混合の型付きのエラー。符号を持ち、メッセージに、元のエラーの文面（デバイス名などを含み得る）を入れない。
import { AUDIO_MIXER_ERROR_CODES, AudioContinuityError, AudioMixerError, WorkletProtocolError } from "./errors";

describe("AudioMixerError", () => {
  it("符号と元のエラーを持つ。メッセージは、符号と元のエラーの名前だけ", () => {
    const cause = new DOMException("Unable to load LABEL-SECRET-1", "NetworkError");

    const error = new AudioMixerError("worklet_load_failed", cause);

    expect(error).toBeInstanceOf(Error);
    expect(error.name).toBe("AudioMixerError");
    expect(error.code).toBe("worklet_load_failed");
    expect(error.cause).toBe(cause);
    expect(error.message).toBe("audio mixer error: worklet_load_failed (NetworkError)");
    expect(error.message).not.toContain("LABEL-SECRET-1");
  });

  it("元のエラーが無ければ、符号だけ", () => {
    const error = new AudioMixerError("invalid_state");

    expect(error.message).toBe("audio mixer error: invalid_state");
    expect(error.cause).toBeUndefined();
  });

  it("符号の一覧は、重複がない", () => {
    expect(new Set(AUDIO_MIXER_ERROR_CODES).size).toBe(AUDIO_MIXER_ERROR_CODES.length);
    expect([...AUDIO_MIXER_ERROR_CODES].sort()).toEqual(
      [
        "aborted",
        "context_not_running",
        "invalid_state",
        "invalid_track",
        "sample_rate_unsupported",
        "unexpected",
        "unsupported",
        "worklet_create_failed",
        "worklet_load_failed",
      ].sort(),
    );
  });
});

describe("AudioContinuityError", () => {
  it("期待した累積サンプル数と、実際の値を持つ（メディアクロックの基準が食い違った）", () => {
    const error = new AudioContinuityError(1470, 1598);

    expect(error).toBeInstanceOf(Error);
    expect(error.name).toBe("AudioContinuityError");
    expect(error.expectedSample).toBe(1470);
    expect(error.actualSample).toBe(1598);
    expect(error.message).toBe("audio continuity error: expected sample 1470, got 1598");
  });
});

describe("WorkletProtocolError", () => {
  it("どの検査に違反したかの符号を持つ（受け取った値は、メッセージに入れない）", () => {
    const error = new WorkletProtocolError("invalid_pcm");

    expect(error).toBeInstanceOf(Error);
    expect(error.name).toBe("WorkletProtocolError");
    expect(error.reason).toBe("invalid_pcm");
    expect(error.message).toBe("worklet protocol error: invalid_pcm");
  });
});
