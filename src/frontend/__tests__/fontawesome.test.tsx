import { render } from "@testing-library/react";
import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import { faVideo } from "@fortawesome/free-solid-svg-icons";
import { faCircle } from "@fortawesome/free-regular-svg-icons";
import { faYoutube } from "@fortawesome/free-brands-svg-icons";

// アイコンは FontAwesome の npm パッケージで使う（CDN を使わない）。
// パッケージが読み込めて、SVG として描画できること（Jest の変換を含む）を確かめる。
describe("FontAwesome（npm パッケージ）", () => {
  it.each([
    ["free-solid-svg-icons", faVideo, "video"],
    ["free-regular-svg-icons", faCircle, "circle"],
    ["free-brands-svg-icons", faYoutube, "youtube"],
  ])("%s のアイコンを SVG として描画できる", (_pack, icon, iconName) => {
    const { container } = render(<FontAwesomeIcon icon={icon} />);

    const svg = container.querySelector("svg");
    expect(svg).not.toBeNull();
    expect(svg?.getAttribute("data-icon")).toBe(iconName);
  });
});
