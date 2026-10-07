// 能力検出の内部の道具。注入された環境オブジェクトの値は信用せず、実行時に確かめながら読み・呼ぶ。
// 項目の読み取りが例外を投げる（アクセスできない環境）ときは、その機能は使えないものとして扱う（拒否側）。

type Callable = (...args: never[]) => unknown;

/** オブジェクトまたは関数（プロパティを持てるもの）。 */
export function isObjectLike(value: unknown): value is object {
  return (typeof value === "object" && value !== null) || typeof value === "function";
}

export function isFunction(value: unknown): value is Callable {
  return typeof value === "function";
}

/** owner の項目を読む。owner がオブジェクトでない・読み取りが例外を投げる（アクセスできない環境）ときは undefined（その機能は無いものとする）。 */
export function readMember(owner: unknown, name: string): unknown {
  if (!isObjectLike(owner)) {
    return undefined;
  }
  try {
    return Reflect.get(owner, name);
  } catch {
    return undefined;
  }
}

/** owner の項目を、名前の連なりでたどる（例：navigator -> locks -> request）。途中が無ければ undefined。 */
export function readPath(owner: unknown, names: readonly string[]): unknown {
  return names.reduce<unknown>((current, name) => readMember(current, name), owner);
}

/** owner のメソッドを、owner を this にして呼ぶ（window のメソッドは、this が window でなければ呼べない）。関数でなければ TypeError。 */
export function callMember(owner: unknown, name: string, args: readonly unknown[]): unknown {
  const member = readMember(owner, name);
  if (!isFunction(member)) {
    throw new TypeError(`${name} is not a function`);
  }
  return Reflect.apply(member, owner, args);
}

/** コンストラクタとして呼ぶ。関数でなければ TypeError。 */
export function construct(constructor: unknown, args: readonly unknown[]): unknown {
  if (!isFunction(constructor)) {
    throw new TypeError("not a constructor");
  }
  return Reflect.construct(constructor, args);
}

const ERROR_NAME_PATTERN = /^[A-Za-z][A-Za-z0-9_]{0,63}$/;

/**
 * 投げられた値から、失敗の記録に残す名前だけを取り出す。メッセージ・スタック・値そのものは残さない（URL・利用者の情報が混じり得るため）。
 * エラーでない値は NonErrorThrown、名前が識別子の形でないものは UnnamedError。
 */
export function errorNameOf(thrown: unknown): string {
  if (!isObjectLike(thrown)) {
    return "NonErrorThrown";
  }
  const name = readMember(thrown, "name");
  return typeof name === "string" && ERROR_NAME_PATTERN.test(name) ? name : "UnnamedError";
}
