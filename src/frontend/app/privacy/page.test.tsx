import { render, screen, within } from "@testing-library/react";
import { flattenMessages } from "@/lib/messages";
import { ja, t } from "@/messages";
import PrivacyPage, { metadata } from "./page";

// プライバシーポリシー（/privacy）。本文は仮置き（モックの語句）なので、文言そのものではなく、構成と、
// カタログの文言が、すべて画面に出ていることを検査する。

const pageTexts = flattenMessages(ja.provisional.privacy);

describe("プライバシーポリシーの画面: 構成", () => {
  it("h1 は 1 つ（題は英語の見出し、副題は日本語）", () => {
    render(<PrivacyPage />);

    const headings = screen.getAllByRole("heading", { level: 1 });

    expect(headings).toHaveLength(1);
    expect(headings[0].textContent).toBe(`${t("provisional.privacy.heading")} ${t("provisional.legal.privacy")}`);
  });

  it("カードの見出し（h2）を、モックの順に並べる", () => {
    render(<PrivacyPage />);

    const eyebrows = screen.getAllByRole("heading", { level: 2 }).map((heading) => heading.textContent);

    expect(eyebrows).toEqual([
      t("provisional.privacy.collected.eyebrow"),
      t("provisional.privacy.notCollected.eyebrow"),
      t("provisional.privacy.purpose.eyebrow"),
      t("provisional.privacy.retention.eyebrow"),
      t("provisional.privacy.youtubeApi.eyebrow"),
      t("provisional.privacy.deletion.eyebrow"),
      t("provisional.legal.contact.eyebrow"),
    ]);
  });

  it("見出しの階層を飛ばさない（h1 の次は h2。h3 以下を使わない）", () => {
    render(<PrivacyPage />);

    expect(screen.queryAllByRole("heading", { level: 3 })).toHaveLength(0);
  });

  it("項目の行（定義リスト）は、取得 7・非取得 3・用途 3・保持 5・API 0・削除 3・連絡先 3", () => {
    const { container } = render(<PrivacyPage />);

    const counts = Array.from(container.querySelectorAll("section")).map((section) => section.querySelectorAll("dt").length);

    expect(counts).toEqual([7, 3, 3, 5, 0, 3, 3]);
  });

  it("本文の入れ物（main）は、ページの内容に含めない（共通レイアウトの main に 1 つだけ置く）", () => {
    render(<PrivacyPage />);

    expect(screen.queryByRole("main")).toBeNull();
  });
});

describe("プライバシーポリシーの画面: 文言", () => {
  it("カタログの文言（プライバシーポリシー）は、description と URL を除き、すべて画面に出る", () => {
    render(<PrivacyPage />);
    const text = document.body.textContent ?? "";

    for (const [key, message] of Object.entries(pageTexts)) {
      if (key === "metaDescription" || key.endsWith(".href")) {
        continue;
      }
      expect({ key, shown: text.includes(message) }).toEqual({ key, shown: true });
    }
  });

  it("連絡先は info@rictaworks.jp。施行日は「未定」", () => {
    render(<PrivacyPage />);

    const contact = screen.getByRole("heading", { name: t("provisional.legal.contact.eyebrow") }).closest("section") as HTMLElement;

    expect(within(contact).getByText("info@rictaworks.jp")).toBeInTheDocument();
    expect(within(contact).getByText(t("provisional.legal.contact.effectiveDate.value"))).toBeInTheDocument();
  });

  it("メールアドレス・氏名などを「取得しません」と示す（要件 28.2）", () => {
    render(<PrivacyPage />);

    const notCollected = screen
      .getByRole("heading", { name: t("provisional.privacy.notCollected.eyebrow") })
      .closest("section") as HTMLElement;

    expect(within(notCollected).getByText(t("provisional.privacy.notCollected.email.label"))).toBeInTheDocument();
    expect(within(notCollected).getByText(t("provisional.privacy.notCollected.name.label"))).toBeInTheDocument();
  });
});

describe("プライバシーポリシーの画面: 外部リンク（要件 16.1・31）", () => {
  it("Google プライバシーポリシーと、Google アカウントの権限の管理へのリンクを、外部リンクとして置く", () => {
    render(<PrivacyPage />);

    const links = [
      [t("provisional.privacy.youtubeApi.googlePrivacy.label"), t("provisional.privacy.youtubeApi.googlePrivacy.href")],
      [t("provisional.privacy.youtubeApi.permissions.label"), t("provisional.privacy.youtubeApi.permissions.href")],
    ] as const;

    for (const [label, href] of links) {
      const link = screen.getByRole("link", { name: new RegExp(label) });

      expect(link).toHaveAttribute("href", href);
      expect(link).toHaveAttribute("target", "_blank");
      expect(link).toHaveAttribute("rel", "noopener noreferrer");
    }
  });

  it("画面の中のリンクは、この 2 つだけ", () => {
    render(<PrivacyPage />);

    expect(screen.getAllByRole("link")).toHaveLength(2);
  });
});

describe("プライバシーポリシーの画面: metadata", () => {
  it("title は「プライバシーポリシー」、description と OGP を持つ", () => {
    expect(metadata.title).toBe(t("provisional.legal.privacy"));
    expect(metadata.description).toBe(t("provisional.privacy.metaDescription"));
    expect(metadata.openGraph).toMatchObject({ title: `${t("provisional.legal.privacy")} | ${t("brand.name")}` });
  });
});
