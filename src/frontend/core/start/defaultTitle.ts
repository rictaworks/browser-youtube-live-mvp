// 既定のタイトル（requirements.md 9.1・16.3）：「ライブ配信」に、日時を付した文字列。
// 「ライブ配信」は、文言カタログ由来のラベルとして、引数で受け取る（Domain Core は、利用者に表示する文字列を持たない）。
// 日時は JST の「YYYY-MM-DD HH:mm」で、ラベルとの間は半角の空白 1 つ。時刻は引数で受け取る（現在時刻を参照しない）。

import { formatJstMinute } from "./jstFormat";
import { titleViolations } from "./title";

/**
 * 既定のタイトル「<ラベル> <YYYY-MM-DD HH:mm>」を返す（例：「ライブ配信 2026-10-07 13:30」）。
 * nowEpochMilliseconds は、エポックからのミリ秒（呼び出し側が現在時刻を渡す）。
 * ラベルが文字列でない・空白のみ、または、できあがったタイトルが 9.1 の検証を満たさない（山括弧・100 文字超）ときは RangeError
 * （文言カタログの誤りを、利用者の画面に出す前に見つける）。
 */
export function defaultTitle(nowEpochMilliseconds: number, label: string): string {
  if (typeof label !== "string" || label.trim().length === 0) {
    throw new RangeError("label must be a non-blank string");
  }
  const title = `${label} ${formatJstMinute(nowEpochMilliseconds)}`;
  const violations = titleViolations(title);
  if (violations.length > 0) {
    throw new RangeError(`the default title does not satisfy the title rules (${violations.join(", ")}): the label is not usable`);
  }
  return title;
}
