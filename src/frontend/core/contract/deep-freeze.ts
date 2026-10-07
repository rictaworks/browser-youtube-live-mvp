// 定数を、実行時にも変更できなくするための、深い凍結。契約の定数モジュールが使う。
// 配列・オブジェクトを再帰的に凍結し、同じ値を返す。
export function deepFreeze<T>(value: T): T {
  if (value !== null && typeof value === "object") {
    for (const child of Object.values(value)) {
      deepFreeze(child);
    }
    Object.freeze(value);
  }
  return value;
}
