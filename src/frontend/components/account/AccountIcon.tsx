import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import { disableFontAwesomeAutoCss } from "@/components/ui/font-awesome";
import { ACCOUNT_ICONS, type AccountIconName } from "./icons";

disableFontAwesomeAutoCss();

export interface AccountIconProps {
  name: AccountIconName;
  className?: string;
}

/** アカウント画面の装飾のアイコン（意味は、隣の文言が伝える。支援技術へ読ませない）。 */
export function AccountIcon({ name, className }: AccountIconProps) {
  return <FontAwesomeIcon icon={ACCOUNT_ICONS[name]} className={className} />;
}
