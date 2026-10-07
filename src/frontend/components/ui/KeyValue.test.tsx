import { render, screen, within } from "@testing-library/react";
import { KeyValueList, KeyValueRow } from "./KeyValue";

describe("KeyValueList・KeyValueRow（キー・バリュー行）", () => {
  it("項目名（dt）と値（dd）の組として表示する", () => {
    render(
      <KeyValueList>
        <KeyValueRow label="配信の長さ" value="1 配信 60 分まで" />
      </KeyValueList>,
    );

    expect(screen.getByRole("term")).toHaveTextContent("配信の長さ");
    expect(screen.getByRole("definition")).toHaveTextContent("1 配信 60 分まで");
  });

  it("一覧は、定義リスト（dl）で、複数の行を持てる", () => {
    const { container } = render(
      <KeyValueList>
        <KeyValueRow label="回線" value="1,200 kbps 以上" />
        <KeyValueRow label="年齢" value="16 歳以上" />
      </KeyValueList>,
    );

    const list = container.querySelector("dl");

    expect(list).not.toBeNull();
    expect(within(list as HTMLElement).getAllByRole("term")).toHaveLength(2);
    expect(within(list as HTMLElement).getAllByRole("definition")).toHaveLength(2);
  });

  it("項目名は、その値と同じ行（div）の中にある（項目名と値の対応が崩れない）", () => {
    const { container } = render(
      <KeyValueList>
        <KeyValueRow label="回線" value="1,200 kbps 以上" />
      </KeyValueList>,
    );

    const row = container.querySelector("dl > div");

    expect(row).toHaveClass("row");
    expect(row?.querySelector("dt")).toHaveTextContent("回線");
    expect(row?.querySelector("dd")).toHaveTextContent("1,200 kbps 以上");
  });

  it("値には、文字列だけでなく要素も渡せる（リンクなど）", () => {
    render(
      <KeyValueList>
        <KeyValueRow label="連絡先" value={<a href="mailto:info@example.invalid">info@example.invalid</a>} />
      </KeyValueList>,
    );

    expect(screen.getByRole("link", { name: "info@example.invalid" })).toBeInTheDocument();
  });

  it("compact を指定すると、詰めた表示（スタジオの健全性・利用状況）のクラスを持つ", () => {
    const { container } = render(
      <KeyValueList>
        <KeyValueRow label="残り" value="1 / 1" compact />
      </KeyValueList>,
    );

    expect(container.querySelector("dl > div")).toHaveClass("row", "compact");
  });

  it("既定では、詰めた表示にしない", () => {
    const { container } = render(
      <KeyValueList>
        <KeyValueRow label="残り" value="1 / 1" />
      </KeyValueList>,
    );

    expect(container.querySelector("dl > div")).not.toHaveClass("compact");
  });

  it("className を、一覧へ付けられる", () => {
    const { container } = render(
      <KeyValueList className="wide">
        <KeyValueRow label="残り" value="1 / 1" />
      </KeyValueList>,
    );

    expect(container.querySelector("dl")).toHaveClass("list", "wide");
  });
});
