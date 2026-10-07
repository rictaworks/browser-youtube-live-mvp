import { BRAND_NAME } from "./brand";

describe("BRAND_NAME（製品名の定数）", () => {
  it("仮表記は「Browser Live」（CLAUDE.md U11）", () => {
    expect(BRAND_NAME).toBe("Browser Live");
  });

  it("空でなく、前後に空白を含まず、波括弧を含まない（文言の置き換えの記法と衝突させない）", () => {
    expect(BRAND_NAME.trim()).toBe(BRAND_NAME);
    expect(BRAND_NAME).not.toBe("");
    expect(BRAND_NAME).not.toMatch(/[{}]/);
  });
});
