/**
 * @jest-environment node
 */
import { formatApiTimestamp } from "./format-time";

// API の時刻（ISO 8601。JST の +09:00 が基本）を、画面へ出す JST の「YYYY-MM-DD HH:mm」にする。

describe("formatApiTimestamp", () => {
  it.each([
    ["2026-10-07T14:30:00+09:00", "2026-10-07 14:30"],
    ["2026-10-07T05:30:00Z", "2026-10-07 14:30"],
    ["2026-10-08T03:00:00+09:00", "2026-10-08 03:00"],
    ["2026-10-07T23:59:59+09:00", "2026-10-07 23:59"],
  ])("%s は %s（JST）", (value, expected) => {
    expect(formatApiTimestamp(value)).toBe(expected);
  });

  it.each([[null], [""], ["garbage"], ["2026-13-45T99:99:99+09:00"]])("%j は、表示できないため null（別の値で補わない）", (value) => {
    expect(formatApiTimestamp(value)).toBeNull();
  });
});
