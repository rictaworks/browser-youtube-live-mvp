import { render, screen } from "@testing-library/react";
import { Chip } from "./Chip";

describe("Chip（状態の文言と図形）", () => {
  it("文言と、装飾のアイコンを表示する", () => {
    render(
      <Chip icon="info" tone="ok">
        取得済み
      </Chip>,
    );

    const chip = screen.getByText("取得済み");
    const svg = chip.querySelector("svg");

    expect(chip).toBeInTheDocument();
    expect(svg).toHaveAttribute("aria-hidden", "true");
    expect(svg).toHaveAttribute("data-icon", "circle-info");
  });

  it("既定の tone は neutral", () => {
    render(<Chip icon="info">未取得</Chip>);

    expect(screen.getByText("未取得")).toHaveClass("chip", "neutral");
  });

  it.each([
    ["neutral", "neutral"],
    ["ok", "ok"],
    ["warn", "warn"],
    ["bad", "bad"],
  ] as const)("tone=%s は、%s のクラスを持つ", (tone, className) => {
    render(
      <Chip icon="info" tone={tone}>
        状態
      </Chip>,
    );

    expect(screen.getByText("状態")).toHaveClass("chip", className);
  });

  it("文言と図形は、必ず対で渡す（icon を省略すると、型の検査で弾く）", () => {
    // @ts-expect-error icon は必須（色だけで状態を伝えないため）
    const chip = <Chip>状態</Chip>;

    expect(chip).toBeDefined();
  });

  it("className を付けられる", () => {
    render(
      <Chip icon="info" className="end">
        状態
      </Chip>,
    );

    expect(screen.getByText("状態")).toHaveClass("chip", "end");
  });
});
