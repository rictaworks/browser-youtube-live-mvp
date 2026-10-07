// 開始入力の検証（requirements.md 9.1・16.3）。開始ダイアログの入力が、受付要求（POST /api/broadcasts）に出せる形かを確かめる。
//   - タイトル：1〜100 文字（コードポイント）・山括弧を含まない・空白のみは不可（title.ts）
//   - 公開範囲：公開（public）・限定公開（unlisted）・非公開（private）の 3 値。既定は限定公開
//   - 子ども向けの申告：はい（true）・いいえ（false）。未選択（null・undefined）は不可。利用者の明示的な選択を必須とする
// 不備のある項目の名前は、サーバーの拒否（rejected.fields）と同じ（title・privacy_status・made_for_kids）。
// 不備は、最初の 1 件で止めず、すべて返す（開始ダイアログが、該当する項目をすべて示せるように）。

import { titleViolations } from "./title";
import type { TitleViolation } from "./title";

/** 公開範囲の符号（http-api.md の privacy_status）。 */
export const PRIVACY_STATUS_VALUES = Object.freeze(["public", "unlisted", "private"] as const);
export type PrivacyStatus = (typeof PRIVACY_STATUS_VALUES)[number];

/** 公開範囲の既定値：限定公開（9.1・16.3）。 */
export const DEFAULT_PRIVACY_STATUS: PrivacyStatus = "unlisted";

/** 不備のある項目の名前（サーバーの rejected.fields と同じ）。 */
export type StartInputField = "title" | "privacy_status" | "made_for_kids";

export type StartInputErrorCode =
  | "title_blank"
  | "title_too_long"
  | "title_has_angle_bracket"
  | "privacy_status_invalid"
  | "made_for_kids_unselected";

export interface StartInputError {
  readonly field: StartInputField;
  readonly code: StartInputErrorCode;
}

/** 開始ダイアログの入力（検証前）。madeForKids の null・undefined は、未選択。 */
export interface StartInputDraft {
  readonly title: string;
  readonly privacyStatus: string;
  readonly madeForKids: boolean | null | undefined;
}

/** 検証を通った入力。 */
export interface StartInput {
  readonly title: string;
  readonly privacyStatus: PrivacyStatus;
  readonly madeForKids: boolean;
}

export type StartInputValidation =
  | { readonly valid: true; readonly value: StartInput }
  | { readonly valid: false; readonly errors: readonly StartInputError[] };

const TITLE_ERROR_CODES: Readonly<Record<TitleViolation, StartInputErrorCode>> = Object.freeze({
  blank: "title_blank",
  too_long: "title_too_long",
  angle_bracket: "title_has_angle_bracket",
});

function isPrivacyStatus(value: unknown): value is PrivacyStatus {
  return typeof value === "string" && (PRIVACY_STATUS_VALUES as readonly string[]).includes(value);
}

/**
 * 開始入力を検証する。不備が無ければ { valid: true, value }（値は入力の写し。タイトルは変更しない）、
 * あれば { valid: false, errors }（項目の順 title・privacy_status・made_for_kids に、すべての不備）。
 * 入力は変更しない。結果は凍結される。
 */
export function validateStartInput(draft: StartInputDraft): StartInputValidation {
  const errors: StartInputError[] = titleViolations(draft.title).map((violation) =>
    Object.freeze({ field: "title", code: TITLE_ERROR_CODES[violation] } as const),
  );
  if (!isPrivacyStatus(draft.privacyStatus)) {
    errors.push(Object.freeze({ field: "privacy_status", code: "privacy_status_invalid" } as const));
  }
  if (typeof draft.madeForKids !== "boolean") {
    errors.push(Object.freeze({ field: "made_for_kids", code: "made_for_kids_unselected" } as const));
  }

  if (errors.length > 0) {
    return Object.freeze({ valid: false, errors: Object.freeze(errors) });
  }
  return Object.freeze({
    valid: true,
    value: Object.freeze({
      title: draft.title,
      privacyStatus: draft.privacyStatus as PrivacyStatus,
      madeForKids: draft.madeForKids as boolean,
    }),
  });
}
