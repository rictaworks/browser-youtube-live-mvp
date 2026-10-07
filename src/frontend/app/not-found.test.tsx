import { render, screen, within } from "@testing-library/react";
import { t } from "@/messages";
import NotFound, { metadata } from "./not-found";

describe("404 の画面（not-found.tsx）", () => {
  it("h1（題と副題）と、エラーの通知（断定と対処）を表示する", () => {
    render(<NotFound />);

    const heading = screen.getByRole("heading", { level: 1 });
    const alert = screen.getByRole("alert");

    expect(heading.textContent).toBe(`${t("provisional.notFound.heading")} ${t("provisional.notFound.subheading")}`);
    expect(alert).toHaveTextContent(t("provisional.notFound.notice.title"));
    expect(alert).toHaveTextContent(t("provisional.notFound.notice.body"));
  });

  it("対処の操作として、トップへ戻るリンクを、通知の中に置く", () => {
    render(<NotFound />);

    const link = within(screen.getByRole("alert")).getByRole("link", { name: t("provisional.notFound.action") });

    expect(link).toHaveAttribute("href", "/");
  });

  it("main 要素を含まない（共通レイアウトの main に 1 つだけ置く）", () => {
    render(<NotFound />);

    expect(screen.queryByRole("main")).toBeNull();
  });

  it("title・description を持つ（Next.js が、404 に noindex を付ける）", () => {
    expect(metadata.title).toBe(t("provisional.notFound.heading"));
    expect(typeof metadata.description).toBe("string");
  });
});
