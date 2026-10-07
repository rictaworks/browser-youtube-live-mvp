// SourceError（型付きのエラー）。コードと種別を持ち、メッセージにデバイス名・ラベル・元のエラーの文面を含めない。
import { SOURCE_ERROR_CODES, SourceError, isSourceError } from "./errors";

describe("SourceError", () => {
  it("符号・種別・元のエラーの名前を持ち、Error として扱える", () => {
    const cause = new DOMException("busy", "NotReadableError");

    const error = new SourceError("not_readable", "camera", cause);

    expect(error).toBeInstanceOf(Error);
    expect(error.name).toBe("SourceError");
    expect(error.code).toBe("not_readable");
    expect(error.kind).toBe("camera");
    expect(error.errorName).toBe("NotReadableError");
    expect(error.cause).toBe(cause);
  });

  it("メッセージは、符号と種別と元のエラーの名前だけ（元のエラーの文面に含まれ得るデバイス名・ラベルを、含めない）", () => {
    const cause = new DOMException("Could not start video source LABEL-SECRET-123", "NotReadableError");

    const error = new SourceError("not_readable", "camera", cause);

    expect(error.message).toBe("source error: not_readable (camera, NotReadableError)");
    expect(error.message).not.toContain("LABEL-SECRET-123");
  });

  it("元のエラーが無いとき（呼び出しの誤りなど）は、名前を持たない", () => {
    const error = new SourceError("shared_audio_requires_screen", "shared_audio");

    expect(error.errorName).toBeNull();
    expect(error.cause).toBeUndefined();
    expect(error.message).toBe("source error: shared_audio_requires_screen (shared_audio)");
  });

  it("元のエラーが Error でない値でも、名前は null（推測しない）", () => {
    expect(new SourceError("unexpected", "screen", "string value").errorName).toBeNull();
    expect(new SourceError("unexpected", "screen", { name: 5 }).errorName).toBeNull();
  });

  it("符号の一覧は、重複がなく、想定の 8 つ", () => {
    expect([...SOURCE_ERROR_CODES].sort()).toEqual(
      ["aborted", "disposed", "invalid_state", "no_track", "not_readable", "shared_audio_requires_screen", "unexpected", "unsupported"].sort(),
    );
    expect(new Set(SOURCE_ERROR_CODES).size).toBe(SOURCE_ERROR_CODES.length);
  });

  it("isSourceError は、SourceError だけを真とする", () => {
    expect(isSourceError(new SourceError("aborted", "camera"))).toBe(true);
    expect(isSourceError(new Error("x"))).toBe(false);
    expect(isSourceError(null)).toBe(false);
    expect(isSourceError({ code: "aborted" })).toBe(false);
  });
});
