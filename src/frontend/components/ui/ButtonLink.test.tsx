import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { ButtonLink } from "./ButtonLink";

describe("ButtonLink（ボタンの見た目のリンク）", () => {
  it("リンク（a 要素）として描画し、ボタンと同じクラスを持つ", () => {
    render(<ButtonLink href="/">トップへ戻る</ButtonLink>);

    const link = screen.getByRole("link", { name: "トップへ戻る" });

    expect(link).toHaveAttribute("href", "/");
    expect(link).toHaveClass("button");
  });

  it.each([
    ["primary", "primary"],
    ["stop", "stop"],
  ] as const)("variant=%s は、%s のクラスを持つ", (variant, className) => {
    render(
      <ButtonLink href="/" variant={variant}>
        操作
      </ButtonLink>,
    );

    expect(screen.getByRole("link")).toHaveClass("button", className);
  });

  it("size=small は、小さいボタンのクラスを持つ", () => {
    render(
      <ButtonLink href="/" size="small">
        操作
      </ButtonLink>,
    );

    expect(screen.getByRole("link")).toHaveClass("small");
  });

  it("icon を渡すと、装飾のアイコンを描画する", () => {
    render(
      <ButtonLink href="/" icon="retry">
        やり直す
      </ButtonLink>,
    );

    expect(screen.getByRole("link").querySelector("svg")).toHaveAttribute("aria-hidden", "true");
  });

  it("Tab で到達できる", async () => {
    const user = userEvent.setup();
    render(<ButtonLink href="/">トップへ戻る</ButtonLink>);

    await user.tab();

    expect(screen.getByRole("link")).toHaveFocus();
  });
});
