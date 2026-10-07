import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import { disableFontAwesomeAutoCss } from "@/components/ui/font-awesome";
import { LANDING_ICONS, type LandingIconName } from "./icons";

disableFontAwesomeAutoCss();

export interface LandingIconProps {
  name: LandingIconName;
  className?: string;
}

/** ランディングの装飾のアイコン（文言は、隣のテキストが伝える。支援技術へ読ませない）。 */
export function LandingIcon({ name, className }: LandingIconProps) {
  return <FontAwesomeIcon icon={LANDING_ICONS[name]} className={className} />;
}
