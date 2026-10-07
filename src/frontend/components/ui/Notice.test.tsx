import { render, screen, within } from "@testing-library/react";
import { t } from "@/messages";
import { Button } from "./Button";
import { Notice } from "./Notice";

describe("Notice（通知: 情報・警告・エラー）", () => {
  it("題（何が起きたか）と、本文（次に何をすればよいか）を表示する", () => {
    render(
      <Notice tone="warning" title="YouTube が未接続です。">
        接続すると、配信できます。
      </Notice>,
    );

    const notice = screen.getByRole("status");

    expect(within(notice).getByText("YouTube が未接続です。").tagName).toBe("STRONG");
    expect(notice).toHaveTextContent("接続すると、配信できます。");
  });

  it("本文は省略できる", () => {
    render(<Notice tone="info" title="進行中の配信があります。" />);

    expect(screen.getByRole("status")).toHaveTextContent("進行中の配信があります。");
  });

  it.each([
    ["info", "status"],
    ["warning", "status"],
    ["error", "alert"],
  ] as const)("tone=%s は、role=%s（エラーは、すぐに読み上げる）", (tone, role) => {
    render(<Notice tone={tone} title="題" />);

    expect(screen.getByRole(role)).toBeInTheDocument();
  });

  it.each([
    ["info", "circle-info"],
    ["warning", "triangle-exclamation"],
    ["error", "circle-xmark"],
  ] as const)("tone=%s は、形の異なる図形（%s）を伴う（色だけで区別しない）", (tone, iconName) => {
    render(<Notice tone={tone} title="題" />);

    const svg = screen.getByRole(tone === "error" ? "alert" : "status").querySelector("svg");

    expect(svg).toHaveAttribute("data-icon", iconName);
    expect(svg).toHaveAttribute("aria-hidden", "true");
  });

  it.each([
    ["info", "provisional.ui.notice.severity.info"],
    ["warning", "provisional.ui.notice.severity.warning"],
    ["error", "provisional.ui.notice.severity.error"],
  ] as const)("tone=%s は、種類を文言でも伝える（画面には出さず、支援技術へ読ませる）", (tone, key) => {
    render(<Notice tone={tone} title="題" />);

    const label = screen.getByText(t(key));

    expect(label).toHaveClass("visuallyHidden");
  });

  it("icon で、図形を差し替えられる（状態ごとの別の図形）", () => {
    render(<Notice tone="info" title="題" icon="retry" />);

    expect(screen.getByRole("status").querySelector("svg")).toHaveAttribute("data-icon", "rotate-right");
  });

  it("対処の操作を、action の欄へ置ける（エラーの通知）", () => {
    render(
      <Notice tone="error" title="処理を完了できませんでした。" action={<Button variant="primary">再試行</Button>}>
        時間を置いて、再試行してください。
      </Notice>,
    );

    const alert = screen.getByRole("alert");

    expect(within(alert).getByRole("button", { name: "再試行" })).toBeInTheDocument();
  });

  it("action が無ければ、操作の欄を作らない", () => {
    render(<Notice tone="error" title="題" />);

    expect(within(screen.getByRole("alert")).queryByRole("button")).toBeNull();
  });

  it("className を付けられる", () => {
    render(<Notice tone="info" title="題" className="wide" />);

    expect(screen.getByRole("status")).toHaveClass("notice", "info", "wide");
  });
});
