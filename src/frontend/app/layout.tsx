import type { Metadata, Viewport } from "next";
import { Inter, Noto_Sans_JP, Playfair_Display } from "next/font/google";
import type { ReactNode } from "react";
import { MAIN_CONTENT_ID, SiteFooter, SiteHeader, SkipLink } from "@/components/layout";
import { classNames } from "@/lib/class-names";
import { buildRootMetadata } from "@/lib/page-metadata";
import "./globals.css";

// 書体（デザインシステムの Inter・Noto Sans JP・Playfair Display）。ビルド時に Google Fonts から取得し、自己ホストする
// （実行時に、ブラウザは Google へ接続しない）。ビルド時に取得できなければ、ビルドを失敗させる（黙って別の書体にしない）。
// 変数（--font-inter など）は、styles/app-tokens.css が、デザインシステムの --font-sans・--font-display へつなぐ。
// next/font の引数は、ビルド時に静的に解析されるため、値をそのまま書く（変数・展開を使えない）。
const inter = Inter({ subsets: ["latin"], variable: "--font-inter", display: "swap" });
// 日本語の字形は、番号付きの unicode-range の分割で配られ、必要な分だけをブラウザが取得する。欧文は Inter なので、preload しない
const notoSansJp = Noto_Sans_JP({ preload: false, variable: "--font-noto-sans-jp", display: "swap" });
// 見出しの強調（em）に、イタリックを使う（app-ui/ の見出し）
const playfairDisplay = Playfair_Display({
  subsets: ["latin"],
  style: ["normal", "italic"],
  variable: "--font-playfair-display",
  display: "swap",
});

export const metadata: Metadata = buildRootMetadata();

// ビューポートは device-width・初期倍率 1。拡大縮小は妨げない。暗色基調（要件 17.1）なので、ブラウザの既定の配色も暗色にする
export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  colorScheme: "dark",
};

/** 全画面の共通レイアウト: スキップリンク・ヘッダー・本文（main）・フッター。利用規約・プライバシーポリシーへのリンクは、フッターにある。 */
export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    // data-scroll-behavior: tokens/base.css の html は scroll-behavior: smooth。Next.js 16 は、この属性があるとき、
    // ページ遷移の間だけ滑らかなスクロールを止める（遷移がもたつかない）。無いと、開発時に警告が出る
    <html
      lang="ja"
      data-scroll-behavior="smooth"
      className={classNames(inter.variable, notoSansJp.variable, playfairDisplay.variable)}
    >
      <body>
        <SkipLink />
        <SiteHeader />
        <main id={MAIN_CONTENT_ID} tabIndex={-1}>
          {children}
        </main>
        <SiteFooter />
      </body>
    </html>
  );
}
