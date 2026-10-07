import { render, screen } from "@testing-library/react";
import { Note } from "./Note";

describe("Note（カードなどの中の段落）", () => {
  it("段落（p）として、内容を表示する", () => {
    render(<Note>説明の文</Note>);

    expect(screen.getByText("説明の文").tagName).toBe("P");
  });

  it("既定は、本文の大きさ（note のクラスだけ）", () => {
    render(<Note>説明の文</Note>);

    const paragraph = screen.getByText("説明の文");

    expect(paragraph).toHaveClass("note");
    expect(paragraph).not.toHaveClass("fine");
  });

  it("size=fine は、補足の大きさ（fine のクラスを加える）", () => {
    render(<Note size="fine">制限値は変更することがあります。</Note>);

    expect(screen.getByText("制限値は変更することがあります。")).toHaveClass("note", "fine");
  });

  it("内容には、リンクなどの要素も渡せる", () => {
    render(
      <Note>
        <a href="#x">リンク</a>
      </Note>,
    );

    expect(screen.getByRole("link", { name: "リンク" })).toBeInTheDocument();
  });

  it("className を付けられる", () => {
    render(<Note className="wide">説明の文</Note>);

    expect(screen.getByText("説明の文")).toHaveClass("note", "wide");
  });
});
