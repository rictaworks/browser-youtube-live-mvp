import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { t } from "@/messages";
import { MAIN_CONTENT_ID, SkipLink } from "./SkipLink";

describe("SkipLink（本文へ移動するスキップリンク）", () => {
  it("本文（main）の id へのページ内リンクで、文言はカタログから", () => {
    render(<SkipLink />);

    const link = screen.getByRole("link", { name: t("provisional.layout.skipLink") });

    expect(link).toHaveAttribute("href", `#${MAIN_CONTENT_ID}`);
  });

  it("キーボードで最初に到達する（ほかの操作より前に Tab で届く）", async () => {
    const user = userEvent.setup();
    render(
      <>
        <SkipLink />
        <button type="button">別の操作</button>
      </>,
    );

    await user.tab();

    expect(screen.getByRole("link", { name: t("provisional.layout.skipLink") })).toHaveFocus();
  });

  it("本文の id は、空でなく、# を含まない", () => {
    expect(MAIN_CONTENT_ID).toMatch(/^[a-z][a-z0-9-]*$/);
  });
});
