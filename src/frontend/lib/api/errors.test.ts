/**
 * @jest-environment node
 */
import {
  ApiAbortedError,
  ApiClientError,
  ApiError,
  ApiNetworkError,
  ApiRejected,
  ApiTimeoutError,
  createApiError,
  CsrfInvalidError,
  MissingCsrfTokenError,
  NotLoggedInError,
  UnexpectedResponse,
} from "./errors";

describe("createApiError: 符号に応じた型付きのエラー", () => {
  it("not_logged_in は NotLoggedInError、csrf_invalid は CsrfInvalidError、ほかは ApiError", () => {
    expect(createApiError(401, "not_logged_in", {})).toBeInstanceOf(NotLoggedInError);
    expect(createApiError(403, "csrf_invalid", {})).toBeInstanceOf(CsrfInvalidError);
    const plain = createApiError(403, "forbidden", {});
    expect(plain).toBeInstanceOf(ApiError);
    expect(plain).not.toBeInstanceOf(NotLoggedInError);
    expect(plain).not.toBeInstanceOf(CsrfInvalidError);
  });

  it("すべてのエラーは、ApiClientError（共通の親）でもある", () => {
    const errors = [
      createApiError(401, "not_logged_in", {}),
      createApiError(500, "internal_error", {}),
      new ApiRejected({ status: 409, reason: "capacity_full", resolution: "wait", retryAt: null, fields: null }),
      new UnexpectedResponse(500, "x"),
      new ApiNetworkError(new TypeError("x")),
      new ApiTimeoutError(100),
      new ApiAbortedError(),
      new MissingCsrfTokenError("logout"),
    ];

    for (const error of errors) {
      expect(error).toBeInstanceOf(ApiClientError);
      expect(error).toBeInstanceOf(Error);
    }
  });
});

describe("ApiError", () => {
  it("HTTP ステータス・符号・details を持ち、メッセージは、符号とステータスだけ（details を含めない）", () => {
    const error = createApiError(429, "rate_limited", { retry_at: "2026-10-07T13:31:00+09:00", note: "dummy-secret" });

    expect(error.status).toBe(429);
    expect(error.code).toBe("rate_limited");
    expect(error.details).toEqual({ retry_at: "2026-10-07T13:31:00+09:00", note: "dummy-secret" });
    expect(error.message).toBe("API error 429 rate_limited");
    expect(error.name).toBe("ApiError");
  });

  it("retryAt: details.retry_at が文字列ならその値、そうでなければ null", () => {
    expect(createApiError(429, "rate_limited", { retry_at: "2026-10-07T13:31:00+09:00" }).retryAt).toBe("2026-10-07T13:31:00+09:00");
    expect(createApiError(429, "rate_limited", {}).retryAt).toBeNull();
    expect(createApiError(429, "rate_limited", { retry_at: 1 }).retryAt).toBeNull();
  });

  it("endReason: details.end_reason が列挙の値ならその値、そうでなければ null", () => {
    expect(createApiError(409, "broadcast_ended", { end_reason: "time_limit" }).endReason).toBe("time_limit");
    expect(createApiError(409, "broadcast_ended", { end_reason: "made_up" }).endReason).toBeNull();
    expect(createApiError(409, "broadcast_ended", {}).endReason).toBeNull();
  });

  it("fields: details.fields が文字列の配列ならその値、そうでなければ null", () => {
    expect(createApiError(422, "invalid_input", { fields: ["title", "made_for_kids"] }).fields).toEqual(["title", "made_for_kids"]);
    expect(createApiError(422, "invalid_input", { fields: "title" }).fields).toBeNull();
    expect(createApiError(422, "invalid_input", { fields: [1] }).fields).toBeNull();
    expect(createApiError(422, "invalid_input", {}).fields).toBeNull();
  });

  it("サブクラスの名前を持つ（ログ・デバッグで区別できる）", () => {
    expect(createApiError(401, "not_logged_in", {}).name).toBe("NotLoggedInError");
    expect(createApiError(403, "csrf_invalid", {}).name).toBe("CsrfInvalidError");
  });
});

describe("ApiRejected（受付の拒否）", () => {
  it("理由・区分・再試行の目安時刻・fields・HTTP ステータスを持ち、メッセージは理由とステータスだけ", () => {
    const rejected = new ApiRejected({
      status: 409,
      reason: "allowance_consumed",
      resolution: "next_usage_day",
      retryAt: "2026-10-08T03:00:00+09:00",
      fields: null,
    });

    expect(rejected.reason).toBe("allowance_consumed");
    expect(rejected.resolution).toBe("next_usage_day");
    expect(rejected.retryAt).toBe("2026-10-08T03:00:00+09:00");
    expect(rejected.fields).toBeNull();
    expect(rejected.status).toBe(409);
    expect(rejected.message).toBe("request rejected 409 allowance_consumed");
    expect(rejected.name).toBe("ApiRejected");
  });

  it("ApiError ではない（受付の拒否と、通常のエラーを、型で区別できる）", () => {
    const rejected = new ApiRejected({ status: 503, reason: "capacity_full", resolution: "wait", retryAt: null, fields: null });

    expect(rejected).not.toBeInstanceOf(ApiError);
  });
});

describe("UnexpectedResponse・通信のエラー", () => {
  it("UnexpectedResponse は、ステータス（無ければ null）と理由の符号を持つ", () => {
    const error = new UnexpectedResponse(404, "error body is not JSON");

    expect(error.status).toBe(404);
    expect(error.detail).toBe("error body is not JSON");
    expect(error.message).toBe("unexpected response (status 404): error body is not JSON");
    expect(new UnexpectedResponse(null, "x").message).toBe("unexpected response: x");
  });

  it("ApiNetworkError は原因を保持し、メッセージに原因の文面を含めない", () => {
    const cause = new TypeError("fetch failed for https://example.invalid/?token=dummy-secret");
    const error = new ApiNetworkError(cause);

    expect(error.cause).toBe(cause);
    expect(error.message).toBe("network request failed");
  });

  it("ApiTimeoutError は待った時間を持つ", () => {
    const error = new ApiTimeoutError(35_000);

    expect(error.timeoutMs).toBe(35_000);
    expect(error.message).toBe("request timed out after 35000 ms");
  });

  it("MissingCsrfTokenError は、操作の名前だけを持つ", () => {
    expect(new MissingCsrfTokenError("logout").message).toBe("CSRF token is not available for logout (call getState first)");
  });
});
