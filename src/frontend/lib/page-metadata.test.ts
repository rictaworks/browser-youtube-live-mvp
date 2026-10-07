import { t } from "@/messages";
import { buildPageMetadata, buildRootMetadata } from "./page-metadata";

describe("buildRootMetadata（全画面の既定の title・description・OGP）", () => {
  const metadata = buildRootMetadata();

  it("title の既定は、製品名。画面ごとの題は「題 | 製品名」の書式で組み立てる", () => {
    expect(metadata.title).toEqual({
      default: t("brand.name"),
      template: `%s | ${t("brand.name")}`,
    });
  });

  it("description は、サービスの概要", () => {
    expect(metadata.description).toBe(t("provisional.meta.siteDescription"));
  });

  it("OGP の最小限（種類・言語・サイト名・題・説明）を持つ", () => {
    expect(metadata.openGraph).toMatchObject({
      type: "website",
      locale: "ja_JP",
      siteName: t("brand.name"),
      title: t("brand.name"),
      description: t("provisional.meta.siteDescription"),
    });
  });
});

describe("buildPageMetadata（画面ごとの title・description・OGP）", () => {
  const metadata = buildPageMetadata({ title: "利用規約", description: "本サービスの利用条件です。" });

  it("title は、画面ごとの題（製品名の付与は、親の template が行う）", () => {
    expect(metadata.title).toBe("利用規約");
  });

  it("description を持つ", () => {
    expect(metadata.description).toBe("本サービスの利用条件です。");
  });

  it("OGP の title は、製品名を付けた完全な題（子の openGraph は親の openGraph を置き換えるため、ここで完結させる）", () => {
    expect(metadata.openGraph).toMatchObject({
      type: "website",
      locale: "ja_JP",
      siteName: t("brand.name"),
      title: `利用規約 | ${t("brand.name")}`,
      description: "本サービスの利用条件です。",
    });
  });

  it("題が違えば、title も OGP の title も違う（画面ごとに異なる）", () => {
    const other = buildPageMetadata({ title: "プライバシーポリシー", description: "取得する情報を示します。" });

    expect(other.title).not.toBe(metadata.title);
    expect(other.openGraph?.title).not.toBe(metadata.openGraph?.title);
  });

  it("題・説明が空なら、例外にする（空の title を出さない）", () => {
    expect(() => buildPageMetadata({ title: "", description: "説明" })).toThrow(RangeError);
    expect(() => buildPageMetadata({ title: "題", description: "" })).toThrow(RangeError);
  });
});
