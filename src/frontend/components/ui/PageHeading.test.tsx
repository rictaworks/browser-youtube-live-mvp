import { render, screen } from "@testing-library/react";
import { PageHeading } from "./PageHeading";

describe("PageHeading（ページ題。英語の見出しと、日本語の副題）", () => {
  it("h1 として、題と副題を表示する", () => {
    render(<PageHeading title="Terms" subtitle="利用規約" />);

    const heading = screen.getByRole("heading", { level: 1 });

    expect(heading).toHaveTextContent("Terms");
    expect(heading).toHaveTextContent("利用規約");
  });

  it("題と副題は、空白で区切る（読み上げ・コピーで、1 語につながらない）", () => {
    render(<PageHeading title="Terms" subtitle="利用規約" />);

    expect(screen.getByRole("heading", { level: 1 }).textContent).toBe("Terms 利用規約");
  });

  it("題は英語の見出しなので、既定で lang=en を付ける。副題には付けない", () => {
    render(<PageHeading title="Terms" subtitle="利用規約" />);

    expect(screen.getByText("Terms")).toHaveAttribute("lang", "en");
    expect(screen.getByText("利用規約")).not.toHaveAttribute("lang");
  });

  it("titleLang で、題の言語を替えられる", () => {
    render(<PageHeading title="利用規約" titleLang="ja" />);

    expect(screen.getByText("利用規約")).toHaveAttribute("lang", "ja");
  });

  it("副題は省略できる（その場合、末尾に余分な空白を出さない）", () => {
    render(<PageHeading title="Studio" />);

    expect(screen.getByRole("heading", { level: 1 }).textContent).toBe("Studio");
  });

  it("画面に h1 は 1 つ", () => {
    render(<PageHeading title="Terms" subtitle="利用規約" />);

    expect(screen.getAllByRole("heading", { level: 1 })).toHaveLength(1);
  });
});
