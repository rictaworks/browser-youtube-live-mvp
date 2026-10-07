import {
  faArrowUpRightFromSquare,
  faCircleInfo,
  faCircleNotch,
  faCircleXmark,
  faRotateRight,
  faTriangleExclamation,
} from "@fortawesome/free-solid-svg-icons";

/**
 * アイコンのレジストリ（FontAwesome の npm パッケージ。CDN は使わない）。
 * 名前は、用途（意味）で付ける。状態を表すアイコン（info・warning・error）は、互いに形が異なる
 * （要件 17.2: 状態は色だけで区別せず、文言と形の異なる図形を伴う）。
 * 後続の画面が別のアイコンを使うときは、ここへ 1 行足す。
 */
export const ICONS = {
  info: faCircleInfo,
  warning: faTriangleExclamation,
  error: faCircleXmark,
  busy: faCircleNotch,
  external: faArrowUpRightFromSquare,
  retry: faRotateRight,
} as const;

export type IconName = keyof typeof ICONS;

export const ICON_NAMES = Object.keys(ICONS) as IconName[];
