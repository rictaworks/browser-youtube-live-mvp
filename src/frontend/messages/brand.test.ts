/**
 * @jest-environment node
 */

// 製品名は、config/brand.ts の定数 1 か所（CLAUDE.md U11）。定数を差し替えたとき、文言カタログ・ワードマーク・
// ページの title の書式が、他のファイルを触らずに、すべて替わることを確かめる。
// 製品名の文字列が、ほかのファイルに書かれていないこと（走査）は、usage.test.ts。

jest.mock("next/navigation", () => ({ usePathname: () => "/terms" }));

describe("製品名の差し替え（config/brand.ts の 1 か所）", () => {
  const REPLACEMENT = "Alpha Beta";

  it("brand.name が、差し替えた値になる", async () => {
    await jest.isolateModulesAsync(async () => {
      jest.doMock("@/config/brand", () => ({ BRAND_NAME: REPLACEMENT }));

      const { t } = await import("@/messages");

      expect(t("brand.name")).toBe(REPLACEMENT);
    });
  });

  it("ページの title の書式（%s | 製品名）と、OGP のサイト名が、差し替えた値になる", async () => {
    await jest.isolateModulesAsync(async () => {
      jest.doMock("@/config/brand", () => ({ BRAND_NAME: REPLACEMENT }));

      const { buildPageMetadata, buildRootMetadata } = await import("@/lib/page-metadata");

      expect(buildRootMetadata().title).toEqual({ default: REPLACEMENT, template: `%s | ${REPLACEMENT}` });
      expect(buildPageMetadata({ title: "題", description: "説明" }).openGraph).toMatchObject({
        siteName: REPLACEMENT,
        title: `題 | ${REPLACEMENT}`,
      });
    });
  });

  it("ヘッダーのワードマークが、差し替えた値（前の語と、強調する最後の語）になる", async () => {
    await jest.isolateModulesAsync(async () => {
      jest.doMock("@/config/brand", () => ({ BRAND_NAME: REPLACEMENT }));

      const React = await import("react");
      const { renderToStaticMarkup } = await import("react-dom/server");
      const { SiteHeader } = await import("@/components/layout");

      const html = renderToStaticMarkup(React.createElement(SiteHeader));

      expect(html).toContain("Alpha");
      expect(html).toMatch(/>Beta<\/span>/);
      expect(html).not.toContain("Browser");
    });
  });
});
