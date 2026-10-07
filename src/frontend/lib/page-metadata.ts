import type { Metadata } from "next";
import { t } from "@/messages";

// <title>・description・OGP の最小限の設定（QC02）。画面ごとに異なる <title> にする。
// 公開ドメイン・共有用の画像が未決（CLAUDE.md U6）のため、og:url・og:image は設定しない。

function openGraphOf(title: string, description: string): NonNullable<Metadata["openGraph"]> {
  return {
    type: "website",
    locale: "ja_JP",
    siteName: t("brand.name"),
    title,
    description,
  };
}

/** 全画面の既定（app/layout.tsx）。画面ごとの題は「題 | 製品名」の書式で組み立てる。 */
export function buildRootMetadata(): Metadata {
  const brand = t("brand.name");
  const description = t("provisional.meta.siteDescription");
  return {
    title: {
      default: brand,
      template: t("provisional.meta.pageTitle", { title: "%s", brand }),
    },
    description,
    openGraph: openGraphOf(brand, description),
  };
}

/**
 * 画面ごとの title・description・OGP。title には題だけを渡す（製品名は、親の template が付ける）。
 * 子の openGraph は、親の openGraph を置き換えるため、OGP の title は、製品名まで付けた完全な題にする。
 */
export function buildPageMetadata({ title, description }: { title: string; description: string }): Metadata {
  if (title === "" || description === "") {
    throw new RangeError("buildPageMetadata: title and description must not be empty");
  }
  return {
    title,
    description,
    openGraph: openGraphOf(t("provisional.meta.pageTitle", { title, brand: t("brand.name") }), description),
  };
}
