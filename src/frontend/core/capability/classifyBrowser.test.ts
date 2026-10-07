/**
 * @jest-environment node
 */
// 測定用のブラウザの分類（requirements.md 18.2：ブラウザの種別は、分類（系統と対応の可否）のみを記録する。http-api.md の browser_class）。
// 系統は chromium・firefox・webkit・other。ユーザーエージェントの文字列そのものを返さない・保持しない
// （呼び出し側が、系統の符号だけを渡す。長い文字列を渡されても、系統の符号に当てはまらなければ other で、その文字列は結果に残らない）。
import { BROWSER_FAMILIES, classifyBrowser } from "./classifyBrowser";

const REAL_USER_AGENTS = [
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0",
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
];

describe("classifyBrowser: 系統と対応の可否", () => {
  test.each<[string, boolean]>([
    ["chromium", true],
    ["chromium", false],
    ["firefox", true],
    ["firefox", false],
    ["webkit", true],
    ["webkit", false],
    ["other", true],
    ["other", false],
  ])("系統 %s・対応 %s", (family, canStart) => {
    expect(classifyBrowser(family, canStart)).toEqual({ family, supported: canStart });
  });

  test("系統は 4 種で、凍結されている", () => {
    expect([...BROWSER_FAMILIES]).toEqual(["chromium", "firefox", "webkit", "other"]);
    expect(Object.isFrozen(BROWSER_FAMILIES)).toBe(true);
  });

  test("系統の符号は、大文字小文字・前後の空白の違いを許す（符号に正規化する）", () => {
    expect(classifyBrowser("Chromium", true)).toEqual({ family: "chromium", supported: true });
    expect(classifyBrowser(" FIREFOX ", false)).toEqual({ family: "firefox", supported: false });
  });

  test.each([
    ["未知の系統", "gecko"],
    ["空文字", ""],
    ["undefined", undefined],
    ["null", null],
    ["数値", 1],
  ])("系統に当てはまらない（%s）ものは other（未知を、別の系統へ推測しない）", (_label, family) => {
    expect(classifyBrowser(family as never, true)).toEqual({ family: "other", supported: true });
  });

  test("対応の可否が真偽値でなければ RangeError（能力検出の結果を、推測で補わない）", () => {
    expect(() => classifyBrowser("chromium", undefined as never)).toThrow(RangeError);
    expect(() => classifyBrowser("chromium", "true" as never)).toThrow(RangeError);
    expect(() => classifyBrowser("chromium", 1 as never)).toThrow(RangeError);
  });
});

describe("classifyBrowser: ユーザーエージェントの文字列を、返さない・保持しない", () => {
  test.each(REAL_USER_AGENTS)("実際のユーザーエージェントの文字列を渡されても、系統の符号ではないので other。結果に、その文字列の断片が無い: %s", (userAgent) => {
    const result = classifyBrowser(userAgent, true);
    expect(result.family).toBe("other");
    const serialized = JSON.stringify(result);
    for (const fragment of ["Mozilla", "AppleWebKit", "Chrome", "Firefox", "Safari", "Linux", "Windows", "Macintosh", "153", "x86_64"]) {
      expect(serialized).not.toContain(fragment);
    }
  });

  test("結果のキーは family と supported だけ。family は 4 つの符号のどれか。変更できない（凍結）", () => {
    const result = classifyBrowser("chromium", true);
    expect(Object.keys(result).sort()).toEqual(["family", "supported"]);
    expect(BROWSER_FAMILIES).toContain(result.family);
    expect(Object.isFrozen(result)).toBe(true);
  });

  test("状態を保持しない（呼び出しの間で、前の入力が残らない）", () => {
    classifyBrowser(REAL_USER_AGENTS[0], true);
    expect(classifyBrowser("firefox", false)).toEqual({ family: "firefox", supported: false });
    expect(classifyBrowser("chromium", true)).toEqual({ family: "chromium", supported: true });
  });

  test("文字列を返さず、同じ系統は同じオブジェクトの内容を返す（入力のオブジェクトへの参照を持たない）", () => {
    const first = classifyBrowser("webkit", true);
    const second = classifyBrowser("webkit", true);
    expect(first).toEqual(second);
    expect(first).not.toBe(second);
  });
});
