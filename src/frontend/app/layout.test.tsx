/**
 * @jest-environment node
 */
import { renderToStaticMarkup } from "react-dom/server";
import { BRAND_NAME } from "@/config/brand";
import { t } from "@/messages";
import RootLayout, { metadata, viewport } from "./layout";

// next/font は、next/jest が模擬（className・variable を返すだけ）にする。実際の書体の取得は、next build で確認する。
jest.mock("next/navigation", () => ({ usePathname: () => "/terms" }));

function renderLayout(): string {
  return renderToStaticMarkup(
    <RootLayout>
      <p data-testid="page-content">ページの内容</p>
    </RootLayout>,
  );
}

describe("RootLayout（共通レイアウト）", () => {
  const html = renderLayout();

  it("<html lang=ja>（日本語版のみ）", () => {
    expect(html).toMatch(/^<html[^>]* lang="ja"/);
  });

  it("滑らかなスクロール（tokens/base.css の scroll-behavior: smooth）を、ページ遷移では止める（Next.js 16 の data-scroll-behavior）", () => {
    expect(html).toMatch(/^<html[^>]* data-scroll-behavior="smooth"/);
  });

  it("書体の変数（next/font）を html 要素へ付ける（トークンの --font-sans・--font-display へつなぐため）", () => {
    // 模擬の variable は、書体ごとに「variable」を返す（3 書体 = 3 つ）
    expect(html).toMatch(/^<html[^>]* class="variable variable variable"/);
  });

  it("先頭にスキップリンク、続けてヘッダー・本文・フッターを、この順に置く", () => {
    const skip = html.indexOf(`href="#main-content"`);
    const header = html.indexOf("<header");
    const main = html.indexOf("<main");
    const footer = html.indexOf("<footer");

    expect(skip).toBeGreaterThan(-1);
    expect(header).toBeGreaterThan(skip);
    expect(main).toBeGreaterThan(header);
    expect(footer).toBeGreaterThan(main);
  });

  it("main 要素は 1 つで、スキップリンクの宛先（id）と、プログラムでのフォーカス（tabindex=-1）を持つ", () => {
    expect(html.match(/<main/g)).toHaveLength(1);
    expect(html).toMatch(/<main[^>]* id="main-content"/);
    expect(html).toMatch(/<main[^>]* tabindex="-1"/);
  });

  it("ページの内容は、main の中に置く", () => {
    const main = html.slice(html.indexOf("<main"), html.indexOf("</main>"));

    expect(main).toContain("ページの内容");
  });

  it("フッターに、利用規約とプライバシーポリシーへのリンクがある（全画面から到達できる）", () => {
    const footer = html.slice(html.indexOf("<footer"), html.indexOf("</footer>"));

    expect(footer).toContain(`href="/terms"`);
    expect(footer).toContain(`href="/privacy"`);
    expect(footer).toContain(t("provisional.legal.terms"));
    expect(footer).toContain(t("provisional.legal.privacy"));
  });

  it("ヘッダーに、製品名のワードマークがある", () => {
    const header = html.slice(html.indexOf("<header"), html.indexOf("</header>"));

    expect(header.replace(/<[^>]*>/g, "")).toContain(BRAND_NAME);
  });

  it("ページの内容のあとに、フッターが続く（フッターが先に出ない）", () => {
    expect(html.indexOf("ページの内容")).toBeLessThan(html.indexOf("<footer"));
  });
});

describe("RootLayout: metadata・viewport", () => {
  it("title の既定と書式・description・OGP を持つ（QC02）", () => {
    expect(metadata.title).toEqual({ default: BRAND_NAME, template: `%s | ${BRAND_NAME}` });
    expect(metadata.description).toBe(t("provisional.meta.siteDescription"));
    expect(metadata.openGraph).toMatchObject({ type: "website", locale: "ja_JP", siteName: BRAND_NAME });
  });

  it("viewport は、device-width・拡大縮小を妨げない（userScalable を無効にしない）・暗色の配色", () => {
    expect(viewport).toMatchObject({ width: "device-width", initialScale: 1, colorScheme: "dark" });
    expect(viewport).not.toHaveProperty("userScalable");
    expect(viewport).not.toHaveProperty("maximumScale");
  });
});
