import { faCheck, faCircleXmark, faRightFromBracket, faTrashCan, faTriangleExclamation } from "@fortawesome/free-solid-svg-icons";
import { faCircle } from "@fortawesome/free-regular-svg-icons";
import { faYoutube } from "@fortawesome/free-brands-svg-icons";

/**
 * アカウント画面が使うアイコン（FontAwesome の npm パッケージ。出どころ: app-ui/Account.dc.html）。
 * 接続状態のチップは、4 状態で、形の異なる図形（check・circle・warning・error）にする（要件 17.2: 色だけで状態を区別しない）。
 * 共通部品のレジストリ（components/ui/icons.ts）には、まだ無い。共通へ移すかは、別の判断（この issue の範囲外）。
 */
export const ACCOUNT_ICONS = {
  check: faCheck,
  circle: faCircle,
  warning: faTriangleExclamation,
  error: faCircleXmark,
  youtube: faYoutube,
  trash: faTrashCan,
  logout: faRightFromBracket,
} as const;

export type AccountIconName = keyof typeof ACCOUNT_ICONS;
