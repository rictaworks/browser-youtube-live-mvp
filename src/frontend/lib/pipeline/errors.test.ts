/**
 * @jest-environment node
 */
// 配信パイプライン（合成とエンコード。issue #27）の型付きのエラーと、故障の通知（ワーカー -> メインスレッド）。
//   - エラーの符号は、利用者に表示する文言ではない（画面が、符号から、文言カタログの文言を選ぶ）
//   - 元のエラーの名前だけを残す（元の文面は、デバイス名・URL などを含み得るので、メッセージにも故障の通知にも入れない）
import { PIPELINE_ERROR_CODES, PipelineError, errorFromFault, faultOf, isPipelineErrorCode } from "./errors";

describe("エラーの符号", () => {
  it("符号は重複せず、英小文字と _ だけで書かれている", () => {
    expect(new Set(PIPELINE_ERROR_CODES).size).toBe(PIPELINE_ERROR_CODES.length);
    for (const code of PIPELINE_ERROR_CODES) {
      expect(code).toMatch(/^[a-z][a-z_]*[a-z]$/);
    }
  });

  it("要件が定める失敗を、すべて符号で表せる（黙って止まらない）", () => {
    expect(PIPELINE_ERROR_CODES).toEqual(
      expect.arrayContaining([
        "invalid_message",
        "invalid_state",
        "profile_locked",
        "not_configured",
        "bitrate_out_of_range",
        "video_config_unsupported",
        "audio_config_unsupported",
        "video_encoder_error",
        "audio_encoder_error",
        "decoder_config_missing",
        "decoder_config_unavailable",
        "priming_timeout",
        "compose_failed",
        "source_stream_failed",
        "audio_continuity_lost",
        "worker_crashed",
        "worker_start_timeout",
        "request_timeout",
        "terminated",
        "preview_already_transferred",
        "preview_unavailable",
        "environment_unsupported",
        "unexpected",
      ]),
    );
  });

  it("isPipelineErrorCode は、符号だけを真にする", () => {
    expect(isPipelineErrorCode("video_encoder_error")).toBe(true);
    expect(isPipelineErrorCode("nope")).toBe(false);
    expect(isPipelineErrorCode(42)).toBe(false);
    expect(isPipelineErrorCode(undefined)).toBe(false);
  });
});

describe("PipelineError", () => {
  it("符号と、元のエラーの名前だけを持つ。元のエラーの文面（デバイス名などを含み得る）はメッセージに入れず、cause に残す", () => {
    const original = new DOMException("Fake Camera Device 0 failed at https://example.invalid/x", "EncodingError");

    const error = new PipelineError("video_encoder_error", original);

    expect(error.name).toBe("PipelineError");
    expect(error.code).toBe("video_encoder_error");
    expect(error.detail).toBe("EncodingError");
    expect(error.message).toBe("pipeline error: video_encoder_error (EncodingError)");
    expect(error.message).not.toContain("Fake Camera");
    expect(error.cause).toBe(original);
  });

  it("元のエラーが無ければ、名前を付けない", () => {
    const error = new PipelineError("not_configured");

    expect(error.detail).toBeNull();
    expect(error.message).toBe("pipeline error: not_configured");
    expect(error.cause).toBeUndefined();
  });

  it("Error のサブクラスなので、instanceof で判別できる", () => {
    expect(new PipelineError("invalid_state")).toBeInstanceOf(Error);
    expect(new PipelineError("invalid_state")).toBeInstanceOf(PipelineError);
  });
});

describe("faultOf（故障の通知。符号と、元のエラーの名前だけ）", () => {
  it("PipelineError は、そのまま符号と名前", () => {
    expect(faultOf(new PipelineError("compose_failed", new TypeError("x")))).toEqual({ code: "compose_failed", detail: "TypeError" });
    expect(faultOf(new PipelineError("not_configured"))).toEqual({ code: "not_configured", detail: null });
  });

  it("想定していない値は、unexpected。名前だけを残す（名前の無い値は null）", () => {
    expect(faultOf(new RangeError("boom"))).toEqual({ code: "unexpected", detail: "RangeError" });
    expect(faultOf("text")).toEqual({ code: "unexpected", detail: null });
    expect(faultOf(null)).toEqual({ code: "unexpected", detail: null });
  });

  it("結果は、構造化複製（postMessage）で送れる単純な値", () => {
    const fault = faultOf(new PipelineError("worker_crashed"));

    expect(structuredClone(fault)).toEqual(fault);
    expect(Object.keys(fault).sort()).toEqual(["code", "detail"]);
  });
});

describe("errorFromFault（ワーカーの故障の通知を、エラーにする）", () => {
  it("符号と、元のエラーの名前を引き継ぐ。通知に文面は無い", () => {
    const error = errorFromFault({ code: "video_encoder_error", detail: "EncodingError" });

    expect(error).toBeInstanceOf(PipelineError);
    expect(error.code).toBe("video_encoder_error");
    expect(error.detail).toBe("EncodingError");
    expect(error.message).toBe("pipeline error: video_encoder_error (EncodingError)");
  });

  it("名前が無ければ、名前を付けない", () => {
    const error = errorFromFault({ code: "not_configured", detail: null });

    expect(error.detail).toBeNull();
    expect(error.message).toBe("pipeline error: not_configured");
  });
});
