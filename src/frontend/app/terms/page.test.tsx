import { render, screen, within } from "@testing-library/react";
import { flattenMessages } from "@/lib/messages";
import { ja, t } from "@/messages";
import TermsPage, { metadata } from "./page";

// 利用規約（/terms）。本文は仮置き（モックの語句）なので、文言そのものではなく、構成（見出しの階層・行・リンク）と、
// カタログの文言が、すべて画面に出ていることを検査する。

const pageTexts = flattenMessages(ja.provisional.terms);

describe("利用規約の画面: 構成", () => {
  it("h1 は 1 つ（題は英語の見出し、副題は日本語）", () => {
    render(<TermsPage />);

    const headings = screen.getAllByRole("heading", { level: 1 });

    expect(headings).toHaveLength(1);
    expect(headings[0].textContent).toBe(`${t("provisional.terms.heading")} ${t("provisional.legal.terms")}`);
  });

  it("カードの見出し（h2）を、モックの順に並べる", () => {
    render(<TermsPage />);

    const eyebrows = screen.getAllByRole("heading", { level: 2 }).map((heading) => heading.textContent);

    expect(eyebrows).toEqual([
      t("provisional.terms.service.eyebrow"),
      t("provisional.terms.eligibility.eyebrow"),
      t("provisional.terms.limits.eyebrow"),
      t("provisional.terms.youtubeTerms.eyebrow"),
      t("provisional.terms.provision.eyebrow"),
      t("provisional.legal.contact.eyebrow"),
    ]);
  });

  it("見出しの階層を飛ばさない（h1 の次は h2。h3 以下を使わない）", () => {
    render(<TermsPage />);

    expect(screen.queryAllByRole("heading", { level: 3 })).toHaveLength(0);
  });

  it("項目の行（定義リスト）は、資格 3・制限 6・提供 3・連絡先 3", () => {
    const { container } = render(<TermsPage />);

    const counts = Array.from(container.querySelectorAll("section")).map((section) => section.querySelectorAll("dt").length);

    expect(counts).toEqual([0, 3, 6, 0, 3, 3]);
  });

  it("本文の入れ物（main）は、ページの内容に含めない（共通レイアウトの main に 1 つだけ置く）", () => {
    render(<TermsPage />);

    expect(screen.queryByRole("main")).toBeNull();
  });
});

describe("利用規約の画面: 文言", () => {
  it("カタログの文言（利用規約）は、description と URL を除き、すべて画面に出る", () => {
    render(<TermsPage />);
    const text = document.body.textContent ?? "";

    for (const [key, message] of Object.entries(pageTexts)) {
      if (key === "metaDescription" || key.endsWith(".href")) {
        continue;
      }
      expect({ key, shown: text.includes(message) }).toEqual({ key, shown: true });
    }
  });

  it("連絡先は info@rictaworks.jp。施行日は「未定」", () => {
    render(<TermsPage />);

    const contact = screen.getByRole("heading", { name: t("provisional.legal.contact.eyebrow") }).closest("section") as HTMLElement;

    expect(within(contact).getByText("info@rictaworks.jp")).toBeInTheDocument();
    expect(within(contact).getByText(t("provisional.legal.contact.effectiveDate.value"))).toBeInTheDocument();
  });
});

describe("利用規約の画面: YouTube 利用規約へのリンク（要件 16.1・31）", () => {
  it("外部リンクとして、target=_blank・rel=noopener noreferrer を付ける", () => {
    render(<TermsPage />);

    const link = screen.getByRole("link", { name: new RegExp(t("provisional.terms.youtubeTerms.link.label")) });

    expect(link).toHaveAttribute("href", t("provisional.terms.youtubeTerms.link.href"));
    expect(link).toHaveAttribute("target", "_blank");
    expect(link).toHaveAttribute("rel", "noopener noreferrer");
  });

  it("画面の中のリンクは、YouTube 利用規約の 1 つだけ（フッターのリンクは、共通レイアウト）", () => {
    render(<TermsPage />);

    expect(screen.getAllByRole("link")).toHaveLength(1);
  });
});

describe("利用規約の画面: metadata", () => {
  it("title は「利用規約」、description と OGP を持つ", () => {
    expect(metadata.title).toBe(t("provisional.legal.terms"));
    expect(metadata.description).toBe(t("provisional.terms.metaDescription"));
    expect(metadata.openGraph).toMatchObject({ title: `${t("provisional.legal.terms")} | ${t("brand.name")}` });
  });
});
