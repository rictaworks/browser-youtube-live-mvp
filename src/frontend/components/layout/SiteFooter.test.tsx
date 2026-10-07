import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { t } from "@/messages";
import { SiteFooter } from "./SiteFooter";

describe("SiteFooter（全画面のフッター。利用規約とプライバシーポリシーへのリンク）", () => {
  it("フッター（contentinfo のランドマーク）の中に、2 つのリンクがある", () => {
    render(<SiteFooter />);

    const footer = screen.getByRole("contentinfo");
    const links = within(footer).getAllByRole("link");

    expect(links.map((link) => link.textContent)).toEqual([t("provisional.legal.terms"), t("provisional.legal.privacy")]);
  });

  it("リンク先は /terms と /privacy（サイト内のリンク。新しいタブで開かない）", () => {
    render(<SiteFooter />);

    const terms = screen.getByRole("link", { name: t("provisional.legal.terms") });
    const privacy = screen.getByRole("link", { name: t("provisional.legal.privacy") });

    expect(terms).toHaveAttribute("href", "/terms");
    expect(privacy).toHaveAttribute("href", "/privacy");
    expect(terms).not.toHaveAttribute("target");
    expect(privacy).not.toHaveAttribute("target");
  });

  it("キーボードの Tab で、順に到達できる", async () => {
    const user = userEvent.setup();
    render(<SiteFooter />);

    await user.tab();
    expect(screen.getByRole("link", { name: t("provisional.legal.terms") })).toHaveFocus();
    await user.tab();
    expect(screen.getByRole("link", { name: t("provisional.legal.privacy") })).toHaveFocus();
  });
});
