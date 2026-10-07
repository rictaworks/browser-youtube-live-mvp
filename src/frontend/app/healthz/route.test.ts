/**
 * @jest-environment node
 */
import { GET } from "./route";

describe("GET /healthz", () => {
  it("200 を返す", async () => {
    const response = await GET();

    expect(response.status).toBe(200);
  });

  it("JSON で { status: 'ok' } を返す", async () => {
    const response = await GET();

    expect(response.headers.get("content-type")).toContain("application/json");
    await expect(response.json()).resolves.toEqual({ status: "ok" });
  });

  it("キャッシュさせない", async () => {
    const response = await GET();

    expect(response.headers.get("cache-control")).toBe("no-store");
  });
});
