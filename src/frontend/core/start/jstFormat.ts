// JST の「YYYY-MM-DD HH:mm」（既定のタイトルの日時。requirements.md 9.1）。
// 時刻は引数（エポックからのミリ秒）で受け取り、現在時刻を参照しない。JST は夏時間が無く、UTC との差は常に +9 時間のため、
// 実行環境のタイムゾーンや ICU の時刻データに依らず、固定のオフセットと、整数の演算だけで求める（暦の計算は Howard Hinnant の civil_from_days）。

const JST_OFFSET_MILLISECONDS = 9 * 60 * 60 * 1000;
const MILLISECONDS_PER_MINUTE = 60 * 1000;
const MINUTES_PER_DAY = 24 * 60;
const MIN_YEAR = 1;
const MAX_YEAR = 9999;

/** 床の除算（負の数でも、商は小さい側へ丸める）。剰余で数えるため、浮動小数点の除算の切り捨てに頼らない。 */
function floorDivide(value: number, divisor: number): { readonly quotient: number; readonly remainder: number } {
  const remainder = ((value % divisor) + divisor) % divisor;
  return { quotient: (value - remainder) / divisor, remainder };
}

/** 1970-01-01 からの日数（負なら前）から、暦の年月日（プロレプティック・グレゴリオ暦）を求める。 */
function civilFromDays(days: number): { readonly year: number; readonly month: number; readonly day: number } {
  const shifted = days + 719_468; // 0000-03-01 からの日数
  const { quotient: era, remainder: dayOfEra } = floorDivide(shifted, 146_097); // 400 年を 1 周期とする
  const yearOfEra = Math.floor(
    (dayOfEra - Math.floor(dayOfEra / 1_460) + Math.floor(dayOfEra / 36_524) - Math.floor(dayOfEra / 146_096)) / 365,
  );
  const dayOfYear = dayOfEra - (365 * yearOfEra + Math.floor(yearOfEra / 4) - Math.floor(yearOfEra / 100)); // 3 月 1 日起点
  const monthIndex = Math.floor((5 * dayOfYear + 2) / 153); // 0 = 3 月 ... 11 = 2 月
  const day = dayOfYear - Math.floor((153 * monthIndex + 2) / 5) + 1;
  const month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9;
  const year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0);
  return { year, month, day };
}

function pad(value: number, width: number): string {
  return String(value).padStart(width, "0");
}

/**
 * エポック（1970-01-01T00:00:00Z）からのミリ秒を、JST の「YYYY-MM-DD HH:mm」（24 時間制・秒以下は切り捨て）にする。
 * 例：1791347400000（2026-10-07T04:30:00Z）-> 「2026-10-07 13:30」。
 * 数値でない・有限でない・年が 1〜9999 の外になる値は RangeError。
 */
export function formatJstMinute(epochMilliseconds: number): string {
  if (typeof epochMilliseconds !== "number" || !Number.isFinite(epochMilliseconds)) {
    throw new RangeError(`epochMilliseconds must be a finite number: ${String(epochMilliseconds)}`);
  }
  const jstMilliseconds = Math.floor(epochMilliseconds) + JST_OFFSET_MILLISECONDS;
  const { quotient: totalMinutes } = floorDivide(jstMilliseconds, MILLISECONDS_PER_MINUTE);
  const { quotient: days, remainder: minuteOfDay } = floorDivide(totalMinutes, MINUTES_PER_DAY);
  const { year, month, day } = civilFromDays(days);
  if (year < MIN_YEAR || year > MAX_YEAR) {
    throw new RangeError(`the year must be from ${MIN_YEAR} to ${MAX_YEAR}: ${String(epochMilliseconds)}`);
  }
  const { quotient: hour, remainder: minute } = floorDivide(minuteOfDay, 60);
  return `${pad(year, 4)}-${pad(month, 2)}-${pad(day, 2)} ${pad(hour, 2)}:${pad(minute, 2)}`;
}
