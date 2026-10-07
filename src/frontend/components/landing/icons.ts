import { faAnglesRight, faCloud, faKey, faPowerOff, faSquare, faWindowMaximize } from "@fortawesome/free-solid-svg-icons";

/**
 * ランディングが使うアイコン（FontAwesome の npm パッケージ。出どころ: app-ui/Landing.dc.html）。
 * 共通部品のレジストリ（components/ui/icons.ts）には、まだ無い。共通へ移すかは、別の判断（この issue の範囲外）。
 */
export const LANDING_ICONS = {
  next: faAnglesRight,
  noInstall: faCloud,
  noStreamKey: faKey,
  oneScreen: faWindowMaximize,
  autoClose: faPowerOff,
  bullet: faSquare,
} as const;

export type LandingIconName = keyof typeof LANDING_ICONS;
