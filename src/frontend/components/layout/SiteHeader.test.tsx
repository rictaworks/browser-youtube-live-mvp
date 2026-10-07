import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { usePathname } from "next/navigation";
import { BRAND_NAME } from "@/config/brand";
import { splitWordmark } from "@/lib/wordmark";
import { t } from "@/messages";
import { SiteHeader } from "./SiteHeader";

jest.mock("next/navigation", () => ({ usePathname: jest.fn() }));

const mockedUsePathname = usePathname as jest.MockedFunction<typeof usePathname>;

beforeEach(() => {
  mockedUsePathname.mockReturnValue("/terms");
});

describe("SiteHeader（ワードマークとナビ）", () => {
  it("ヘッダー（banner のランドマーク）の中に、ワードマークとナビがある", () => {
    render(<SiteHeader />);

    const banner = screen.getByRole("banner");

    expect(within(banner).getByRole("link", { name: BRAND_NAME })).toBeInTheDocument();
    expect(within(banner).getByRole("navigation")).toBeInTheDocument();
  });

  it("ワードマークは、製品名（config/brand.ts）から作り、最後の語を強調して、トップへのリンクにする", () => {
    render(<SiteHeader />);

    const { lead, accent } = splitWordmark(BRAND_NAME);
    const link = screen.getByRole("link", { name: BRAND_NAME });

    expect(link).toHaveAttribute("href", "/");
    expect(within(link).getByText(lead)).toBeInTheDocument();
    expect(within(link).getByText(accent)).toHaveClass("accent");
  });

  it("ナビに、利用規約とプライバシーポリシーのリンクがある", () => {
    render(<SiteHeader />);

    const nav = screen.getByRole("navigation");

    expect(within(nav).getByRole("link", { name: t("provisional.legal.terms") })).toHaveAttribute("href", "/terms");
    expect(within(nav).getByRole("link", { name: t("provisional.legal.privacy") })).toHaveAttribute("href", "/privacy");
  });

  it("いま見ている画面のリンクに、aria-current=page を付ける（色だけで示さない）", () => {
    mockedUsePathname.mockReturnValue("/privacy");
    render(<SiteHeader />);

    expect(screen.getByRole("link", { name: t("provisional.legal.privacy") })).toHaveAttribute("aria-current", "page");
    expect(screen.getByRole("link", { name: t("provisional.legal.terms") })).not.toHaveAttribute("aria-current");
  });

  it("ほかの画面では、どのリンクにも aria-current を付けない", () => {
    mockedUsePathname.mockReturnValue("/somewhere-else");
    render(<SiteHeader />);

    for (const link of within(screen.getByRole("navigation")).getAllByRole("link")) {
      expect(link).not.toHaveAttribute("aria-current");
    }
  });

  it("すべてのリンクへ、キーボードの Tab で、順に到達できる", async () => {
    const user = userEvent.setup();
    render(<SiteHeader />);

    await user.tab();
    expect(screen.getByRole("link", { name: BRAND_NAME })).toHaveFocus();
    await user.tab();
    expect(screen.getByRole("link", { name: t("provisional.legal.terms") })).toHaveFocus();
    await user.tab();
    expect(screen.getByRole("link", { name: t("provisional.legal.privacy") })).toHaveFocus();
  });
});
