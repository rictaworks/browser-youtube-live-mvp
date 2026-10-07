// タイトルの規則（requirements.md 9.1・16.3。http-api.md の POST /api/broadcasts の title）。
//   - 1〜100 文字。文字数は Unicode のコードポイントの数（UTF-16 の長さではない。サーバー側と数え方をそろえる）
//   - 山括弧（< と >）を含まない（YouTube のタイトルに使えない）
//   - 空白のみは不可（空白は、ECMAScript の trim が取り除くもの。全角の空白を含む）

/** タイトルの最大の文字数（コードポイント）。 */
export const TITLE_MAX_CODE_POINTS = 100;

/** タイトルの不備の種類。blank = 空・空白のみ、too_long = 100 文字を超える、angle_bracket = 山括弧を含む。 */
export type TitleViolation = "blank" | "too_long" | "angle_bracket";

const BLANK_ONLY: readonly TitleViolation[] = Object.freeze(["blank"] as const);
const ANGLE_BRACKETS = ["<", ">"] as const;

/** 文字列のコードポイントの数。BMP の外の文字（サロゲートペア）は 1 つ。孤立したサロゲートも 1 つ。 */
export function countCodePoints(text: string): number {
  let count = 0;
  let index = 0;
  while (index < text.length) {
    const codePoint = text.codePointAt(index);
    index += codePoint !== undefined && codePoint > 0xffff ? 2 : 1;
    count += 1;
  }
  return count;
}

/**
 * タイトルの不備を、すべて返す（無ければ空）。blank のときは、blank だけ。
 * 順は too_long、angle_bracket。文字列でない入力は、空と同じ（有効なタイトルになり得ない）。
 */
export function titleViolations(title: string): readonly TitleViolation[] {
  if (typeof title !== "string" || title.trim().length === 0) {
    return BLANK_ONLY;
  }
  const violations: TitleViolation[] = [];
  if (countCodePoints(title) > TITLE_MAX_CODE_POINTS) {
    violations.push("too_long");
  }
  if (ANGLE_BRACKETS.some((bracket) => title.includes(bracket))) {
    violations.push("angle_bracket");
  }
  return Object.freeze(violations);
}

/**
 * 文字数の残り（100 - 現在のコードポイント数。16.3 の「文字数の残りを表示する」）。
 * 超過したときは負の数（超過した文字数）。文字列でない入力は、数を答えられないため RangeError。
 */
export function remainingChars(title: string): number {
  if (typeof title !== "string") {
    throw new RangeError(`title must be a string: ${String(title)}`);
  }
  return TITLE_MAX_CODE_POINTS - countCodePoints(title);
}
