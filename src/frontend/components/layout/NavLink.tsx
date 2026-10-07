"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import type { ReactNode } from "react";
import { isCurrentPath } from "@/lib/navigation";

export interface NavLinkProps {
  href: string;
  className?: string;
  children: ReactNode;
}

/**
 * ナビのリンク。いま見ている画面のリンクには、aria-current="page" を付ける。
 * 現在位置の見た目は、呼び出し側の CSS が [aria-current="page"] で決める（色だけで示さないため、下線も付ける）。
 */
export function NavLink({ href, className, children }: NavLinkProps) {
  const pathname = usePathname();
  return (
    <Link href={href} className={className} aria-current={isCurrentPath(pathname, href) ? "page" : undefined}>
      {children}
    </Link>
  );
}
