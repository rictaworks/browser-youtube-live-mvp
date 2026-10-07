/**
 * @jest-environment node
 */
// JST の「YYYY-MM-DD HH:mm」（requirements.md 9.1 の既定タイトル）。時刻は引数（エポックからのミリ秒）で受け取り、現在時刻を参照しない。
// JST は夏時間が無く、UTC との差は常に +9 時間。実行環境のタイムゾーンに依らない（整数の演算だけで日付を求める）。
import { Problems, seededRandom } from "../testing/helpers";
import { formatJstMinute } from "./jstFormat";

describe("formatJstMinute: 表のケース", () => {
  test.each<[number, string, string]>([
    [0, "1970-01-01 09:00", "エポック"],
    [1_791_347_400_000, "2026-10-07 13:30", "2026-10-07T04:30:00Z（既定タイトルの例）"],
    [1_791_347_459_999, "2026-10-07 13:30", "秒以下は切り捨てる（04:30:59.999Z）"],
    [1_791_298_799_999, "2026-10-06 23:59", "日付が変わる直前（14:59:59.999Z）"],
    [1_791_298_800_000, "2026-10-07 00:00", "日付が変わる瞬間（15:00:00Z）"],
    [1_798_729_140_000, "2026-12-31 23:59", "年末の 1 分前"],
    [1_798_729_200_000, "2027-01-01 00:00", "年が変わる（2026-12-31T15:00:00Z）"],
    [1_835_362_800_000, "2028-02-29 00:00", "うるう日の始まり（2028-02-28T15:00:00Z）"],
    [1_835_449_140_000, "2028-02-29 23:59", "うるう日の終わりの 1 分前"],
    [1_835_449_200_000, "2028-03-01 00:00", "うるう日の翌日"],
    [951_825_600_000, "2000-02-29 21:00", "400 で割り切れる年はうるう年（2000）"],
    [4_107_510_000_000, "2100-03-01 00:00", "100 で割り切れて 400 で割り切れない年はうるう年でない（2100-02-28T15:00:00Z）"],
    [-32_400_000, "1970-01-01 00:00", "エポックより前（1969-12-31T15:00:00Z）"],
    [-32_400_001, "1969-12-31 23:59", "エポックの 1 ミリ秒前の 9 時間後"],
    [-2_208_988_800_000, "1900-01-01 09:00", "1900-01-01T00:00:00Z"],
    [253_402_268_340_000, "9999-12-31 23:59", "表せる最後の分（9999-12-31T14:59:00Z）"],
    [-62_135_629_200_000, "0001-01-01 00:00", "表せる最初の分（JST の 0001-01-01 00:00）"],
    [1_767_225_600_000, "2026-01-01 09:00", "2026-01-01T00:00:00Z"],
    [1_772_323_200_000, "2026-03-01 09:00", "2026-03-01T00:00:00Z（2 月の末日の翌日）"],
    [1_790_798_400_000, "2026-10-01 05:00", "月が変わる（2026-09-30T20:00:00Z）"],
  ])("%i -> %s（%s）", (epochMilliseconds, expected) => {
    expect(formatJstMinute(epochMilliseconds)).toBe(expected);
  });

  test("小数のミリ秒は、切り捨てる", () => {
    expect(formatJstMinute(1_791_347_400_000.9)).toBe("2026-10-07 13:30");
  });
});

describe("formatJstMinute: 独立した基準との照合", () => {
  test("エポックの 1900 年から 2200 年までの疑似乱数 20,000 点が、UTC の getter で +9 時間した値と一致する", () => {
    const random = seededRandom(9);
    const problems = new Problems();
    const NINE_HOURS = 9 * 60 * 60 * 1000;
    const pad = (value: number, width: number): string => String(value).padStart(width, "0");
    for (let i = 0; i < 20_000; i += 1) {
      const epochMilliseconds = Math.floor(-2_208_988_800_000 + random() * 12_000_000_000_000);
      const shifted = new Date(epochMilliseconds + NINE_HOURS);
      const expected = `${pad(shifted.getUTCFullYear(), 4)}-${pad(shifted.getUTCMonth() + 1, 2)}-${pad(shifted.getUTCDate(), 2)} ${pad(shifted.getUTCHours(), 2)}:${pad(shifted.getUTCMinutes(), 2)}`;
      if (formatJstMinute(epochMilliseconds) !== expected) {
        problems.report(`${epochMilliseconds}: ${formatJstMinute(epochMilliseconds)} vs ${expected}`);
      }
    }
    expect(problems.list()).toEqual([]);
  });

  test("1 日（1,440 分）を 1 分ずつ進めると、日付と時刻が連続して進む（2028 年のうるう日をまたぐ）", () => {
    const start = 1_835_362_800_000; // 2028-02-29 00:00 JST
    const seen = new Set<string>();
    for (let minute = 0; minute < 1_440 * 2; minute += 1) {
      seen.add(formatJstMinute(start + minute * 60_000));
    }
    expect(seen.size).toBe(1_440 * 2);
    expect(formatJstMinute(start + 1_439 * 60_000)).toBe("2028-02-29 23:59");
    expect(formatJstMinute(start + 1_440 * 60_000)).toBe("2028-03-01 00:00");
  });
});

describe("formatJstMinute: 不正な入力", () => {
  test.each([
    ["NaN", Number.NaN],
    ["無限大", Number.POSITIVE_INFINITY],
    ["負の無限大", Number.NEGATIVE_INFINITY],
    ["表せる年（1〜9999）の外：JST の 10000-01-01 00:00", 253_402_268_400_000],
    ["表せる年の外：表せる最初の分の 1 ミリ秒前（JST の 0000 年）", -62_135_629_200_001],
  ])("%s は RangeError", (_label, value) => {
    expect(() => formatJstMinute(value)).toThrow(RangeError);
  });

  test("数値でない入力は RangeError", () => {
    expect(() => formatJstMinute("2026-10-07" as never)).toThrow(RangeError);
    expect(() => formatJstMinute(undefined as never)).toThrow(RangeError);
  });
});
