import { BRAND_NAME } from "@/config/brand";
import { assertWellFormed, flattenMessages } from "@/lib/messages";
import { ja, t } from "./index";

// 文言カタログの構造の検査（中身の文章は、公開用の文章が確定するまで仮置き）。
const flat = flattenMessages(ja);

describe("文言カタログ（ja）の構造", () => {
  it("最上位は、製品名（brand）と、仮置きの文言（provisional）だけ", () => {
    // 公開用の文章が確定した名前空間を provisional の外へ移すときは、この検査を更新する
    expect(Object.keys(ja).sort()).toEqual(["brand", "provisional"]);
  });

  it("キーは、英数字のキャメルケース（ドット・空白・日本語を含まない）", () => {
    const segments = Object.keys(flat).flatMap((key) => key.split("."));

    for (const segment of segments) {
      expect(segment).toMatch(/^[a-z][A-Za-z0-9]*$/);
    }
  });

  it("文言は、空でなく、前後に空白を含まない", () => {
    for (const [key, message] of Object.entries(flat)) {
      expect({ key, empty: message === "" }).toEqual({ key, empty: false });
      expect({ key, trimmed: message.trim() === message }).toEqual({ key, trimmed: true });
    }
  });

  it("文言の中の波括弧は、{name} の形だけ", () => {
    for (const [key, message] of Object.entries(flat)) {
      expect(() => assertWellFormed(key, message)).not.toThrow();
    }
  });
});

describe("製品名（brand）", () => {
  it("brand.name は、config/brand.ts の定数そのもの", () => {
    expect(t("brand.name")).toBe(BRAND_NAME);
  });
});

describe("連絡先・外部リンク", () => {
  it("連絡先は info@rictaworks.jp（個人名を使わない）", () => {
    expect(t("provisional.legal.contact.address.value")).toBe("info@rictaworks.jp");
  });

  it("施行日は「未定」のまま", () => {
    expect(t("provisional.legal.contact.effectiveDate.value")).toBe("未定");
  });

  it.each([
    ["provisional.terms.youtubeTerms.link.href", "www.youtube.com"],
    ["provisional.privacy.youtubeApi.googlePrivacy.href", "policies.google.com"],
    ["provisional.privacy.youtubeApi.permissions.href", "myaccount.google.com"],
  ] as const)("%s は、https の絶対 URL（モックのまま。確認済みではない）", (key, host) => {
    const url = new URL(t(key));

    expect(url.protocol).toBe("https:");
    expect(url.hostname).toBe(host);
  });
});
