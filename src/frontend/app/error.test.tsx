import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { t } from "@/messages";
import ErrorPage from "./error";

describe("エラーの画面（error.tsx）", () => {
  let consoleError: jest.SpyInstance;

  beforeEach(() => {
    consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
  });

  afterEach(() => {
    consoleError.mockRestore();
  });

  function renderError(error: Error & { digest?: string }, retry: () => void = jest.fn()) {
    return render(<ErrorPage error={error} retry={retry} />);
  }

  it("h1（題と副題）と、エラーの通知（断定と対処）を表示する", () => {
    renderError(new Error("内部の詳細"));

    const heading = screen.getByRole("heading", { level: 1 });
    const alert = screen.getByRole("alert");

    expect(heading.textContent).toBe(`${t("provisional.error.heading")} ${t("provisional.error.subheading")}`);
    expect(alert).toHaveTextContent(t("provisional.error.notice.title"));
    expect(alert).toHaveTextContent(t("provisional.error.notice.body"));
  });

  it("対処の操作として、再試行のボタンを、通知の中に置く。押すと retry を 1 回呼ぶ", async () => {
    const user = userEvent.setup();
    const retry = jest.fn();
    renderError(new Error("x"), retry);

    await user.click(within(screen.getByRole("alert")).getByRole("button", { name: t("provisional.error.action") }));

    expect(retry).toHaveBeenCalledTimes(1);
  });

  it("再試行のボタンは、キーボード（Tab → Enter）で操作できる", async () => {
    const user = userEvent.setup();
    const retry = jest.fn();
    renderError(new Error("x"), retry);

    await user.tab();
    expect(screen.getByRole("button", { name: t("provisional.error.action") })).toHaveFocus();
    await user.keyboard("{Enter}");

    expect(retry).toHaveBeenCalledTimes(1);
  });

  it("エラーの内容（message）を、利用者へ表示しない（内部の詳細を出さない）", () => {
    renderError(new Error("内部の詳細: db のパスワード"));

    expect(screen.queryByText(/内部の詳細/)).toBeNull();
    expect(document.body.textContent).not.toContain("db のパスワード");
  });

  it("デバッグで追えるよう、エラーを console.error へ出す（digest を添える）", () => {
    const error = Object.assign(new Error("boom"), { digest: "digest-1234" });

    renderError(error);

    expect(consoleError).toHaveBeenCalledWith(expect.stringContaining("digest-1234"), error);
  });

  it("digest が無いエラーでも、出力できる", () => {
    const error = new Error("client side");

    renderError(error);

    expect(consoleError).toHaveBeenCalledTimes(1);
    expect(consoleError).toHaveBeenCalledWith(expect.stringContaining("none"), error);
  });

  it("main 要素を含まない（共通レイアウトの main に 1 つだけ置く）", () => {
    renderError(new Error("x"));

    expect(screen.queryByRole("main")).toBeNull();
  });
});
