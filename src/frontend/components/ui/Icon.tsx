import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import { disableFontAwesomeAutoCss } from "./font-awesome";
import { ICONS, type IconName } from "./icons";

disableFontAwesomeAutoCss();

export interface IconProps {
  name: IconName;
  /** 回転させる（処理中）。動きの低減の設定では、FontAwesome の CSS が止める */
  spin?: boolean;
  /**
   * 文言を伴わず、アイコンだけで意味を伝えるときの名前（支援技術が読む）。
   * 既定は装飾（読ませない）。状態は、アイコンの隣の文言が伝える。
   */
  label?: string;
  className?: string;
}

/** FontAwesome のアイコン。名前は icons.ts のレジストリ。 */
export function Icon({ name, spin = false, label, className }: IconProps) {
  return <FontAwesomeIcon icon={ICONS[name]} spin={spin} className={className} aria-label={label} />;
}
