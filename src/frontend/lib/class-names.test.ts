import { classNames } from "./class-names";

describe("classNames", () => {
  it("文字列をスペースでつなぐ", () => {
    expect(classNames("button", "primary")).toBe("button primary");
  });

  it("false・null・undefined・空文字は除く", () => {
    expect(classNames("button", false, null, undefined, "", "small")).toBe("button small");
  });

  it("条件式（&&）の結果をそのまま渡せる", () => {
    const busy = true;
    const disabled = false;

    expect(classNames("button", busy && "busy", disabled && "disabled")).toBe("button busy");
  });

  it("すべて除かれたら、空文字", () => {
    expect(classNames(false, null, undefined)).toBe("");
  });

  it("前後の空白を含む要素は、そのまま 1 つの要素として扱う（分割しない）", () => {
    expect(classNames("a b", "c")).toBe("a b c");
  });
});
