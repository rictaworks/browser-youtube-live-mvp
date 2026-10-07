import { render, screen } from "@testing-library/react";
import { Icon } from "./Icon";
import { ICONS, ICON_NAMES, type IconName } from "./icons";

function svgOf(container: HTMLElement): SVGElement {
  const svg = container.querySelector("svg");
  if (svg === null) {
    throw new Error("svg が描画されていません");
  }
  return svg;
}

describe("Icon", () => {
  it("名前で指定した FontAwesome のアイコンを、SVG として描画する", () => {
    const { container } = render(<Icon name="info" />);

    expect(svgOf(container).getAttribute("data-icon")).toBe("circle-info");
  });

  it.each(ICON_NAMES.map((name) => [name] as const))("レジストリの名前（%s）を、描画できる", (name) => {
    const { container } = render(<Icon name={name} />);

    expect(svgOf(container)).toBeInTheDocument();
  });

  it("既定では装飾として扱い、支援技術へ読ませない（意味は、隣の文言が伝える）", () => {
    const { container } = render(<Icon name="warning" />);

    expect(svgOf(container)).toHaveAttribute("aria-hidden", "true");
    expect(screen.queryByRole("img")).toBeNull();
  });

  it("label を渡すと、名前つきの画像として読ませる（文言を伴わない単独の使い方）", () => {
    render(<Icon name="error" label="エラー" />);

    expect(screen.getByRole("img", { name: "エラー" })).toBeInTheDocument();
  });

  it("spin を渡すと、回転のクラス（fa-spin）が付く", () => {
    const { container } = render(<Icon name="busy" spin />);

    expect(svgOf(container)).toHaveClass("fa-spin");
  });

  it("spin を渡さなければ、回転しない", () => {
    const { container } = render(<Icon name="busy" />);

    expect(svgOf(container)).not.toHaveClass("fa-spin");
  });

  it("className を、アイコンの SVG へ付けられる", () => {
    const { container } = render(<Icon name="info" className="custom" />);

    expect(svgOf(container)).toHaveClass("custom");
  });
});

describe("ICONS（レジストリ）", () => {
  it("状態を表す 3 つのアイコン（情報・警告・エラー）は、互いに形が異なる（色だけで区別しない）", () => {
    const shapes = (["info", "warning", "error"] satisfies IconName[]).map((name) => ICONS[name].icon[4]);

    expect(new Set(shapes).size).toBe(3);
  });

  it("処理中のアイコンは、状態を表すアイコンと形が異なる", () => {
    const stateShapes = new Set((["info", "warning", "error"] satisfies IconName[]).map((name) => ICONS[name].icon[4]));

    expect(stateShapes.has(ICONS.busy.icon[4])).toBe(false);
  });

  it("名前の一覧（ICON_NAMES）は、レジストリのキーと一致する", () => {
    expect([...ICON_NAMES].sort()).toEqual(Object.keys(ICONS).sort());
  });
});
