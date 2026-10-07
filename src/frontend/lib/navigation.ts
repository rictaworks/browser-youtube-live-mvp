/**
 * ナビのリンク（href）が、いま見ている画面（pathname）か。同じパス、またはその配下のとき真。
 * ルート（/）は、ルートだけ（すべての画面の配下になってしまうため）。
 */
export function isCurrentPath(pathname: string, href: string): boolean {
  if (href === "/") {
    return pathname === "/";
  }
  return pathname === href || pathname.startsWith(`${href}/`);
}
