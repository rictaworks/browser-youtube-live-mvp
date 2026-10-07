import Link from "next/link";
import type { ComponentPropsWithoutRef, ReactNode } from "react";
import { classNames } from "@/lib/class-names";
import styles from "./Button.module.css";
import type { ButtonSize, ButtonVariant } from "./Button";
import { Icon } from "./Icon";
import type { IconName } from "./icons";

export type ButtonLinkProps = Omit<ComponentPropsWithoutRef<typeof Link>, "href" | "children"> & {
  /** サイト内の宛先（外部へは ExternalLink を使う） */
  href: string;
  variant?: ButtonVariant;
  size?: ButtonSize;
  icon?: IconName;
  children: ReactNode;
};

/** ボタンの見た目のリンク（ページ遷移の操作。エラーの通知の対処など）。見た目は Button と同じ。 */
export function ButtonLink({
  href,
  variant = "default",
  size = "medium",
  icon,
  children,
  className,
  ...rest
}: ButtonLinkProps) {
  return (
    <Link
      {...rest}
      href={href}
      className={classNames(
        styles.button,
        variant !== "default" && styles[variant],
        size === "small" && styles.small,
        className,
      )}
    >
      {icon && <Icon name={icon} />}
      {children}
    </Link>
  );
}
