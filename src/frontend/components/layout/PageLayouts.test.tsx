import { render, screen, within } from "@testing-library/react";
import { PageContainer } from "./PageContainer";
import { TwoColumnLayout } from "./TwoColumnLayout";

describe("PageContainer（1 カラムの本文の入れ物）", () => {
  it("内容をそのまま包む。main は包まない（main は、共通レイアウトに 1 つだけ置くため）", () => {
    render(
      <PageContainer>
        <p>内容</p>
      </PageContainer>,
    );

    expect(screen.getByText("内容")).toBeInTheDocument();
    expect(screen.queryByRole("main")).toBeNull();
  });

  it("コンテナのクラスを持つ", () => {
    const { container } = render(
      <PageContainer>
        <p>内容</p>
      </PageContainer>,
    );

    expect(container.firstElementChild).toHaveClass("page");
  });
});

describe("TwoColumnLayout（1,024 px 以上は 2 カラム、未満は 1 カラム。切り替えは CSS）", () => {
  it("主な内容（左）と、補助のパネル（右。complementary のランドマーク）を、この順に置く", () => {
    const { container } = render(<TwoColumnLayout main={<p>プレビュー</p>} aside={<p>ソース</p>} />);

    const aside = screen.getByRole("complementary");
    const main = screen.getByText("プレビュー");
    const first = container.firstElementChild;

    expect(within(aside).getByText("ソース")).toBeInTheDocument();
    expect(first?.children).toHaveLength(2);
    expect(first?.children[0]).toContainElement(main);
    expect(first?.children[1]).toBe(aside);
  });

  it("main は包まない（main は、共通レイアウトに 1 つだけ置くため）", () => {
    render(<TwoColumnLayout main={<p>プレビュー</p>} aside={<p>ソース</p>} />);

    expect(screen.queryByRole("main")).toBeNull();
  });

  it("コンテナのクラスを持つ", () => {
    const { container } = render(<TwoColumnLayout main={<p>プレビュー</p>} aside={<p>ソース</p>} />);

    expect(container.firstElementChild).toHaveClass("layout");
  });
});
