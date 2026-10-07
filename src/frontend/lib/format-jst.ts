// 時刻の表示は JST（日本標準時）。JST は夏時間を持たず、UTC との差は常に +9 時間のため、
// 実行環境のタイムゾーンや ICU の時刻データに依らず、固定のオフセットで算出する。
const JST_OFFSET_MILLISECONDS = 9 * 60 * 60 * 1000;

function pad(value: number, width: number): string {
  return String(value).padStart(width, "0");
}

/**
 * 時刻を JST の「YYYY-MM-DD HH:mm」形式で表示する（24 時間制・秒以下は切り捨て）。
 * 例: 2026-10-06T12:30:00Z -> 「2026-10-06 21:30」。
 * 現在時刻は呼び出さない（引数の Date だけで決まる）。無効な Date は RangeError。
 */
export function formatJst(date: Date): string {
  const epochMilliseconds = date.getTime();
  if (Number.isNaN(epochMilliseconds)) {
    throw new RangeError("formatJst: invalid Date");
  }
  // UTC の getter で読むため、先に +9 時間ずらす（ローカル時刻の getter は使わない）
  const jst = new Date(epochMilliseconds + JST_OFFSET_MILLISECONDS);
  const datePart = `${pad(jst.getUTCFullYear(), 4)}-${pad(jst.getUTCMonth() + 1, 2)}-${pad(jst.getUTCDate(), 2)}`;
  const timePart = `${pad(jst.getUTCHours(), 2)}:${pad(jst.getUTCMinutes(), 2)}`;
  return `${datePart} ${timePart}`;
}
