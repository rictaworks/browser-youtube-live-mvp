import { isCurrentPath } from "./navigation";

describe("isCurrentPath: ナビのリンクが、いま見ている画面か", () => {
  it.each([
    ["同じパス", "/terms", "/terms", true],
    ["配下のパス", "/terms/sub", "/terms", true],
    ["別のパス", "/privacy", "/terms", false],
    ["前方一致だけの別のパス（語の途中）", "/termsx", "/terms", false],
    ["上位のパス", "/", "/terms", false],
    ["ルートのリンクは、ルートだけ", "/", "/", true],
    ["ルートのリンクは、配下では現在としない", "/terms", "/", false],
  ])("%s（%p・%p）", (_label, pathname, href, expected) => {
    expect(isCurrentPath(pathname, href)).toBe(expected);
  });
});
