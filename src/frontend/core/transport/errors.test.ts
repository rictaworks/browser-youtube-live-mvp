/**
 * @jest-environment node
 */
// フレームの符号化・復号の失敗（型付きのエラー）。符号は、ws-protocol.md の 4 章（検証の順）の 7 種と、本文の不備・送る内容の不備。
import { FRAME_ERROR_CODES, FrameError, isFrameError } from "./errors";

describe("FRAME_ERROR_CODES", () => {
  test("ws-protocol.md の 4 章の 7 種が、検証の順に並び、続けて、本文の不備と送る内容の不備", () => {
    expect(FRAME_ERROR_CODES).toEqual([
      "truncated_header",
      "invalid_magic",
      "unsupported_version",
      "unknown_type",
      "wrong_direction",
      "too_large",
      "length_mismatch",
      "invalid_body",
      "invalid_message",
    ]);
  });

  test("符号は変更できない（凍結されている）", () => {
    expect(Object.isFrozen(FRAME_ERROR_CODES)).toBe(true);
  });
});

describe("FrameError", () => {
  test("Error であり、符号と詳細を持つ。メッセージに、符号と詳細が入る", () => {
    const error = new FrameError("too_large", "message would be 2097153 bytes");
    expect(error).toBeInstanceOf(Error);
    expect(error).toBeInstanceOf(FrameError);
    expect(error.name).toBe("FrameError");
    expect(error.code).toBe("too_large");
    expect(error.detail).toBe("message would be 2097153 bytes");
    expect(error.message).toBe("frame: too_large: message would be 2097153 bytes");
  });

  test("isFrameError は、FrameError だけを真にする（符号が分かる）", () => {
    expect(isFrameError(new FrameError("invalid_body", "x"))).toBe(true);
    expect(isFrameError(new Error("frame: too_large: x"))).toBe(false);
    expect(isFrameError(new RangeError("x"))).toBe(false);
    expect(isFrameError("too_large")).toBe(false);
    expect(isFrameError(null)).toBe(false);
    expect(isFrameError(undefined)).toBe(false);
  });

  test("投げて、捕まえて、符号で分けられる", () => {
    const attempt = (): void => {
      throw new FrameError("length_mismatch", "body is 3 bytes, the header declares 5");
    };
    expect(attempt).toThrow(FrameError);
    try {
      attempt();
    } catch (error) {
      expect(isFrameError(error) && error.code).toBe("length_mismatch");
    }
  });
});
