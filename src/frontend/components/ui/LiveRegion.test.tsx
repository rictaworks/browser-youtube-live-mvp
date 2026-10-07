import { render, screen } from "@testing-library/react";
import { LiveRegion } from "./LiveRegion";

describe("LiveRegion（支援技術へ状態の変化を伝える領域）", () => {
  it("既定は、控えめな通知（role=status・aria-live=polite・aria-atomic）", () => {
    render(<LiveRegion>配信中</LiveRegion>);

    const region = screen.getByRole("status");

    expect(region).toHaveTextContent("配信中");
    expect(region).toHaveAttribute("aria-live", "polite");
    expect(region).toHaveAttribute("aria-atomic", "true");
  });

  it("assertive を指定すると、すぐに読み上げる通知（role=alert・aria-live=assertive）", () => {
    render(<LiveRegion politeness="assertive">接続が切れました</LiveRegion>);

    const region = screen.getByRole("alert");

    expect(region).toHaveTextContent("接続が切れました");
    expect(region).toHaveAttribute("aria-live", "assertive");
  });

  it("中身が空でも、領域は DOM に存在する（領域が先にあり、あとから中身が変わる形でないと、読み上げられないため）", () => {
    render(<LiveRegion />);

    expect(screen.getByRole("status")).toBeEmptyDOMElement();
  });

  it("中身が変わっても、同じ DOM 要素のまま更新する", () => {
    const { rerender } = render(<LiveRegion>待機</LiveRegion>);
    const before = screen.getByRole("status");

    rerender(<LiveRegion>受付中</LiveRegion>);
    const after = screen.getByRole("status");

    expect(after).toBe(before);
    expect(after).toHaveTextContent("受付中");
  });

  it("visuallyHidden を指定すると、画面から隠す（支援技術だけへ伝える）", () => {
    render(<LiveRegion visuallyHidden>配信中</LiveRegion>);

    expect(screen.getByRole("status")).toHaveClass("visuallyHidden");
  });

  it("既定では、画面に表示する（隠すクラスを付けない）", () => {
    render(<LiveRegion>配信中</LiveRegion>);

    expect(screen.getByRole("status")).not.toHaveClass("visuallyHidden");
  });

  it("className を付けられる", () => {
    render(<LiveRegion className="badge">配信中</LiveRegion>);

    expect(screen.getByRole("status")).toHaveClass("badge");
  });
});
