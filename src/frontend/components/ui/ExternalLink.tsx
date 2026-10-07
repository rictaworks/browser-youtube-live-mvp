import type { ReactNode } from "react";
import { classNames } from "@/lib/class-names";
import { t } from "@/messages";
import styles from "./ExternalLink.module.css";
import { Icon } from "./Icon";
import { VisuallyHidden } from "./VisuallyHidden";

export class InvalidExternalUrlError extends Error {
  readonly href: string;

  constructor(href: string) {
    super(`external link must be an absolute https URL: ${JSON.stringify(href)}`);
    this.name = "InvalidExternalUrlError";
    this.href = href;
  }
}

function assertHttpsUrl(href: string): void {
  let url: URL;
  try {
    url = new URL(href);
  } catch {
    throw new InvalidExternalUrlError(href);
  }
  if (url.protocol !== "https:") {
    throw new InvalidExternalUrlError(href);
  }
}

export interface ExternalLinkProps {
  /** 絶対の https の URL。javascript: など、他のスキームは例外にする */
  href: string;
  children: ReactNode;
  className?: string;
}

/**
 * 外部サイトへのリンク。新しいタブで開き（target=_blank）、rel=noopener noreferrer を付ける。
 * 外部へ出ることを、アイコン（装飾）と、支援技術へ読ませる文言（画面には出さない）で伝える。
 */
export function ExternalLink({ href, children, className }: ExternalLinkProps) {
  assertHttpsUrl(href);
  return (
    <a href={href} target="_blank" rel="noopener noreferrer" className={classNames(styles.link, className)}>
      {children} <Icon name="external" />
      <VisuallyHidden>{t("provisional.ui.externalLink.opensInNewTab")}</VisuallyHidden>
    </a>
  );
}
