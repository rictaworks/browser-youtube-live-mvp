import nextConfig from "./next.config";

describe("next.config", () => {
  it("X-Powered-By を返さない（使っている技術を、応答から知らせない）", () => {
    expect(nextConfig.poweredByHeader).toBe(false);
  });
});
