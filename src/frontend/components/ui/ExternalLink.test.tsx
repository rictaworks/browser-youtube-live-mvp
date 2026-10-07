import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { t } from "@/messages";
import { ExternalLink, InvalidExternalUrlError } from "./ExternalLink";

describe("ExternalLink（外部リンク）", () => {
  it("target=_blank と rel=noopener noreferrer を付ける", () => {
    render(<ExternalLink href="https://www.youtube.com/t/terms">YouTube 利用規約</ExternalLink>);

    const link = screen.getByRole("link", { name: /YouTube 利用規約/ });

    expect(link).toHaveAttribute("href", "https://www.youtube.com/t/terms");
    expect(link).toHaveAttribute("target", "_blank");
    expect(link).toHaveAttribute("rel", "noopener noreferrer");
  });

  it("外部へ出ることを示すアイコン（装飾）を、文言のあとに表示する", () => {
    render(<ExternalLink href="https://policies.google.com/privacy">Google プライバシーポリシー</ExternalLink>);

    const svg = screen.getByRole("link").querySelector("svg");

    expect(svg).toHaveAttribute("data-icon", "arrow-up-right-from-square");
    expect(svg).toHaveAttribute("aria-hidden", "true");
  });

  it("新しいタブで開くことを、支援技術へ伝える（画面には出さない）", () => {
    render(<ExternalLink href="https://policies.google.com/privacy">Google プライバシーポリシー</ExternalLink>);

    const hint = screen.getByText(t("provisional.ui.externalLink.opensInNewTab"));

    expect(hint).toHaveClass("visuallyHidden");
    expect(screen.getByRole("link")).toContainElement(hint);
  });

  it("リンクの名前は、文言と、新しいタブで開く旨を含む", () => {
    render(<ExternalLink href="https://myaccount.google.com/permissions">権限の管理</ExternalLink>);

    expect(screen.getByRole("link", { name: `権限の管理 ${t("provisional.ui.externalLink.opensInNewTab")}` })).toBeInTheDocument();
  });

  it("Tab で到達できる", async () => {
    const user = userEvent.setup();
    render(<ExternalLink href="https://www.youtube.com/t/terms">YouTube 利用規約</ExternalLink>);

    await user.tab();

    expect(screen.getByRole("link")).toHaveFocus();
  });

  it("className を付けられる", () => {
    render(
      <ExternalLink href="https://www.youtube.com/t/terms" className="wide">
        YouTube 利用規約
      </ExternalLink>,
    );

    expect(screen.getByRole("link")).toHaveClass("link", "wide");
  });
});

describe("ExternalLink: 宛先の検査（既定の宛先を補わず、例外にする）", () => {
  let consoleError: jest.SpyInstance;

  beforeEach(() => {
    consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
  });

  afterEach(() => {
    consoleError.mockRestore();
  });

  it.each([
    ["javascript: スキーム", "javascript:alert(1)"],
    ["data: スキーム", "data:text/html,x"],
    ["http（暗号化されていない）", "http://example.invalid/"],
    ["相対パス", "/terms"],
    ["スキームの無い文字列", "www.youtube.com/t/terms"],
    ["空文字", ""],
    ["URL として解釈できない文字列", "https://"],
  ])("%s（%p）は、InvalidExternalUrlError", (_label, href) => {
    expect(() => render(<ExternalLink href={href}>x</ExternalLink>)).toThrow(InvalidExternalUrlError);
  });

  it("例外は、問題の宛先を持つ", () => {
    try {
      render(<ExternalLink href="javascript:alert(1)">x</ExternalLink>);
      throw new Error("例外が投げられませんでした");
    } catch (error) {
      expect(error).toBeInstanceOf(InvalidExternalUrlError);
      expect((error as InvalidExternalUrlError).href).toBe("javascript:alert(1)");
    }
  });
});
