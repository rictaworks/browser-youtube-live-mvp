import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { Button } from "./Button";

describe("Button: 表示", () => {
  it("既定は、type=button の通常のボタン（フォームの中でも、誤って送信しない）", () => {
    render(<Button>配信を開始</Button>);

    const button = screen.getByRole("button", { name: "配信を開始" });

    expect(button).toHaveAttribute("type", "button");
    expect(button).toHaveClass("button");
    expect(button).not.toHaveClass("primary");
    expect(button).not.toHaveClass("stop");
  });

  it.each([
    ["primary", "primary"],
    ["stop", "stop"],
  ] as const)("variant=%s は、%s のクラスを持つ", (variant, className) => {
    render(<Button variant={variant}>操作</Button>);

    expect(screen.getByRole("button")).toHaveClass("button", className);
  });

  it("size=small は、小さいボタンのクラスを持つ", () => {
    render(<Button size="small">複製</Button>);

    expect(screen.getByRole("button")).toHaveClass("small");
  });

  it("icon を渡すと、文言の前に、装飾のアイコンを描画する", () => {
    render(<Button icon="retry">再試行</Button>);

    const button = screen.getByRole("button", { name: "再試行" });
    const svg = button.querySelector("svg");

    expect(svg).not.toBeNull();
    expect(svg).toHaveAttribute("aria-hidden", "true");
    expect(svg).toHaveAttribute("data-icon", "rotate-right");
  });

  it("type=submit を指定できる", () => {
    render(<Button type="submit">送信</Button>);

    expect(screen.getByRole("button")).toHaveAttribute("type", "submit");
  });

  it("className と、aria 属性・data 属性を、そのまま付けられる", () => {
    render(
      <Button className="grow" aria-describedby="help" data-testid="start">
        操作
      </Button>,
    );

    const button = screen.getByTestId("start");

    expect(button).toHaveClass("button", "grow");
    expect(button).toHaveAttribute("aria-describedby", "help");
  });
});

describe("Button: 操作（マウス・キーボード）", () => {
  it("クリックで、onClick を 1 回呼ぶ", async () => {
    const user = userEvent.setup();
    const onClick = jest.fn();
    render(<Button onClick={onClick}>操作</Button>);

    await user.click(screen.getByRole("button"));

    expect(onClick).toHaveBeenCalledTimes(1);
  });

  it("Tab で到達でき（フォーカスできる）、Enter で操作できる", async () => {
    const user = userEvent.setup();
    const onClick = jest.fn();
    render(<Button onClick={onClick}>操作</Button>);

    await user.tab();
    expect(screen.getByRole("button")).toHaveFocus();
    await user.keyboard("{Enter}");

    expect(onClick).toHaveBeenCalledTimes(1);
  });

  it("Space でも操作できる", async () => {
    const user = userEvent.setup();
    const onClick = jest.fn();
    render(<Button onClick={onClick}>操作</Button>);

    await user.tab();
    await user.keyboard(" ");

    expect(onClick).toHaveBeenCalledTimes(1);
  });

  it("フォームの中の type=submit は、送信する", async () => {
    const user = userEvent.setup();
    const onSubmit = jest.fn((event: React.FormEvent) => event.preventDefault());
    render(
      <form onSubmit={onSubmit}>
        <Button type="submit">送信</Button>
      </form>,
    );

    await user.click(screen.getByRole("button"));

    expect(onSubmit).toHaveBeenCalledTimes(1);
  });

  it("フォームの中の既定のボタン（type=button）は、送信しない", async () => {
    const user = userEvent.setup();
    const onSubmit = jest.fn((event: React.FormEvent) => event.preventDefault());
    render(
      <form onSubmit={onSubmit}>
        <Button>送信しない</Button>
      </form>,
    );

    await user.click(screen.getByRole("button"));

    expect(onSubmit).not.toHaveBeenCalled();
  });
});

describe("Button: 無効", () => {
  it("disabled のとき、無効（disabled 属性）になり、クリックしても onClick を呼ばない", async () => {
    const user = userEvent.setup();
    const onClick = jest.fn();
    render(
      <Button disabled onClick={onClick}>
        配信を開始
      </Button>,
    );

    const button = screen.getByRole("button", { name: "配信を開始" });
    await user.click(button);

    expect(button).toBeDisabled();
    expect(onClick).not.toHaveBeenCalled();
  });

  it("無効のボタンは、Tab で到達しない（隣のボタンへ進む）", async () => {
    const user = userEvent.setup();
    render(
      <>
        <Button disabled>無効</Button>
        <Button>有効</Button>
      </>,
    );

    await user.tab();

    expect(screen.getByRole("button", { name: "有効" })).toHaveFocus();
  });

  it("無効のボタンは、Enter・Space でも操作できない", async () => {
    const user = userEvent.setup();
    const onClick = jest.fn();
    render(
      <Button disabled onClick={onClick}>
        無効
      </Button>,
    );

    await user.keyboard("{Enter}");
    await user.keyboard(" ");

    expect(onClick).not.toHaveBeenCalled();
  });

  it("無効のとき、処理中の表示（aria-busy）にはしない", () => {
    render(<Button disabled>無効</Button>);

    expect(screen.getByRole("button")).not.toHaveAttribute("aria-busy");
  });
});

describe("Button: 処理中（文言を進行形に替え、二重操作を受け付けない）", () => {
  it("文言を busyLabel に替え、回転するアイコンを出し、aria-busy・aria-disabled にする", () => {
    render(
      <Button busy busyLabel="受付中…">
        配信を開始
      </Button>,
    );

    const button = screen.getByRole("button", { name: "受付中…" });
    const svg = button.querySelector("svg");

    expect(screen.queryByText("配信を開始")).toBeNull();
    expect(button).toHaveAttribute("aria-busy", "true");
    expect(button).toHaveAttribute("aria-disabled", "true");
    expect(svg).toHaveClass("fa-spin");
    expect(svg).toHaveAttribute("aria-hidden", "true");
  });

  it("処理中でなければ、元の文言のまま（busyLabel は出さない）", () => {
    render(<Button busyLabel="受付中…">配信を開始</Button>);

    expect(screen.getByRole("button", { name: "配信を開始" })).not.toHaveAttribute("aria-busy");
    expect(screen.queryByText("受付中…")).toBeNull();
  });

  it("処理中は、icon を渡していても、回転するアイコンだけを出す", () => {
    render(
      <Button busy busyLabel="再試行中…" icon="retry">
        再試行
      </Button>,
    );

    const icons = screen.getByRole("button").querySelectorAll("svg");

    expect(icons).toHaveLength(1);
    expect(icons[0]).toHaveAttribute("data-icon", "circle-notch");
  });

  it("処理中に、クリックしても onClick を呼ばない（二重送信の防止）", async () => {
    const user = userEvent.setup();
    const onClick = jest.fn();
    render(
      <Button busy busyLabel="受付中…" onClick={onClick}>
        配信を開始
      </Button>,
    );

    const button = screen.getByRole("button");
    await user.click(button);
    await user.dblClick(button);

    expect(onClick).not.toHaveBeenCalled();
  });

  it("処理中に、Enter・Space を押しても onClick を呼ばない", async () => {
    const user = userEvent.setup();
    const onClick = jest.fn();
    render(
      <Button busy busyLabel="受付中…" onClick={onClick}>
        配信を開始
      </Button>,
    );

    await user.tab();
    await user.keyboard("{Enter}");
    await user.keyboard(" ");

    expect(onClick).not.toHaveBeenCalled();
  });

  it("処理中でも、キーボードのフォーカスは失わない（無効にしないため、Tab で到達できる）", async () => {
    const user = userEvent.setup();
    render(
      <Button busy busyLabel="受付中…">
        配信を開始
      </Button>,
    );

    await user.tab();

    expect(screen.getByRole("button")).toHaveFocus();
    expect(screen.getByRole("button")).not.toBeDisabled();
  });

  it("処理中の type=submit は、フォームを送信しない（二重送信の防止）", async () => {
    const user = userEvent.setup();
    const onSubmit = jest.fn((event: React.FormEvent) => event.preventDefault());
    render(
      <form onSubmit={onSubmit}>
        <Button type="submit" busy busyLabel="送信中…">
          送信
        </Button>
      </form>,
    );

    await user.click(screen.getByRole("button"));
    await user.keyboard("{Enter}");

    expect(onSubmit).not.toHaveBeenCalled();
  });

  it("処理中が終われば（busy=false）、再び操作できる", async () => {
    const user = userEvent.setup();
    const onClick = jest.fn();
    const { rerender } = render(
      <Button busy busyLabel="受付中…" onClick={onClick}>
        配信を開始
      </Button>,
    );
    await user.click(screen.getByRole("button"));
    expect(onClick).not.toHaveBeenCalled();

    rerender(<Button onClick={onClick}>配信を開始</Button>);
    await user.click(screen.getByRole("button", { name: "配信を開始" }));

    expect(onClick).toHaveBeenCalledTimes(1);
  });

  it("busyLabel なしで busy にすると、例外にする（文言を替えられない状態を許さない）", () => {
    const spy = jest.spyOn(console, "error").mockImplementation(() => undefined);

    // @ts-expect-error busy のときは busyLabel が必須（型の検査でも弾く）
    expect(() => render(<Button busy>配信を開始</Button>)).toThrow("busyLabel");

    spy.mockRestore();
  });
});
