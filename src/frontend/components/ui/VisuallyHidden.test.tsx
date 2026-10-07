import { render, screen } from "@testing-library/react";
import { VisuallyHidden } from "./VisuallyHidden";

describe("VisuallyHidden", () => {
  it("文字を DOM に残す（支援技術は読める）", () => {
    render(<p>前の文<VisuallyHidden>隠れた文</VisuallyHidden></p>);

    expect(screen.getByText("隠れた文")).toBeInTheDocument();
  });

  it("画面から隠すクラスを持つ（display: none や hidden 属性では、支援技術にも読まれなくなるため使わない）", () => {
    render(<VisuallyHidden>隠れた文</VisuallyHidden>);

    const element = screen.getByText("隠れた文");

    expect(element).toHaveClass("visuallyHidden");
    expect(element).not.toHaveAttribute("hidden");
    expect(element).not.toHaveAttribute("aria-hidden");
  });
});
