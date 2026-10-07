import { render, screen } from "@testing-library/react";
import { Card } from "./Card";

describe("Card（見出しのアイブロウ付きのカード）", () => {
  it("アイブロウを見出し（h2）として、内容をその下に表示する", () => {
    render(
      <Card eyebrow="Service">
        <p>内容</p>
      </Card>,
    );

    const heading = screen.getByRole("heading", { level: 2, name: "Service" });

    expect(heading).toBeInTheDocument();
    expect(screen.getByText("内容")).toBeInTheDocument();
  });

  it("見出しは、内容より前に置く（読み上げの順序）", () => {
    render(
      <Card eyebrow="Limits">
        <p>内容</p>
      </Card>,
    );

    const heading = screen.getByRole("heading", { name: "Limits" });
    const content = screen.getByText("内容");

    expect(heading.compareDocumentPosition(content) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });

  it("アイブロウは英語の見出し（デザインシステムの流儀）なので、既定で lang=en を付ける", () => {
    render(<Card eyebrow="Service">内容</Card>);

    expect(screen.getByRole("heading", { name: "Service" })).toHaveAttribute("lang", "en");
  });

  it("eyebrowLang で、アイブロウの言語を替えられる", () => {
    render(
      <Card eyebrow="概要" eyebrowLang="ja">
        内容
      </Card>,
    );

    expect(screen.getByRole("heading", { name: "概要" })).toHaveAttribute("lang", "ja");
  });

  it("section 要素で、カードのクラスを持つ（名前の無いランドマークを増やさない）", () => {
    const { container } = render(<Card eyebrow="Service">内容</Card>);
    const section = container.querySelector("section");

    expect(section).toHaveClass("card");
    expect(section).not.toHaveAttribute("aria-labelledby");
    expect(section).not.toHaveAttribute("aria-label");
  });

  it("className を付けられる", () => {
    const { container } = render(
      <Card eyebrow="Service" className="wide">
        内容
      </Card>,
    );

    expect(container.querySelector("section")).toHaveClass("card", "wide");
  });
});
