/**
 * @jest-environment node
 */
import { describeFailure } from "./describe-failure";
import { ApiNetworkError, createApiError, UnexpectedResponse } from "./errors";

// 失敗のログの 1 行。API クライアントのエラーは、メッセージ（符号・ステータス・位置だけ）を出し、ほかは、種類の名前だけ（文面に、値が含まれうるため）。

describe("describeFailure", () => {
  it("API クライアントのエラーは、メッセージ（符号・ステータス・位置だけ）を返す", () => {
    expect(describeFailure(createApiError(429, "rate_limited", { retry_at: "x" }))).toBe("API error 429 rate_limited");
    expect(describeFailure(new UnexpectedResponse(404, "response is not JSON"))).toBe("unexpected response (status 404): response is not JSON");
    expect(describeFailure(new ApiNetworkError(new TypeError("fetch failed for https://x.invalid/?token=dummy-secret")))).toBe("network request failed");
  });

  it("ほかの Error は、名前だけを返す（文面に、トークンなどが含まれうるため）", () => {
    class CustomError extends Error {
      constructor(message: string) {
        super(message);
        this.name = "CustomError";
      }
    }

    expect(describeFailure(new CustomError("contains dummy-secret-token"))).toBe("CustomError");
    expect(describeFailure(new TypeError("x"))).toBe("TypeError");
  });

  it("Error でない値は、その型の名前を返す", () => {
    expect(describeFailure("boom")).toBe("string");
    expect(describeFailure(undefined)).toBe("undefined");
    expect(describeFailure(null)).toBe("object");
  });
});
