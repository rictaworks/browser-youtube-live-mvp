// 文言カタログの仕組み（カタログの中身は messages/）。
//   - キーは、名前空間をドットでつないだ文字列（例: "terms.service.body"）。型でも実行時でも、存在しないキーを弾く
//   - 文言の中の {name} を、値で置き換える。値が足りなければ、既定の文言を補わず例外にする
//   - 日本語版のみ。多言語の切り替えの仕組みは持たない

/** 文言の木。葉は文字列、枝は名前空間（キーにドットを含めない）。 */
export interface MessageTree {
  readonly [key: string]: string | MessageTree;
}

type Join<Prefix extends string, Key extends string> = Prefix extends "" ? Key : `${Prefix}.${Key}`;

/** 木の葉のキーの和集合（例: "terms.service.body"）。 */
export type MessageKeys<Tree, Prefix extends string = ""> = Tree extends string
  ? Prefix
  : { [Key in keyof Tree & string]: MessageKeys<Tree[Key], Join<Prefix, Key>> }[keyof Tree & string];

type MessageAt<Tree, Key extends string> = Key extends `${infer Head}.${infer Rest}`
  ? Head extends keyof Tree
    ? MessageAt<Tree[Head], Rest>
    : never
  : Key extends keyof Tree
    ? Tree[Key]
    : never;

type PlaceholderNames<Message extends string> = Message extends `${string}{${infer Name}}${infer Rest}`
  ? Name | PlaceholderNames<Rest>
  : never;

/** 文言のプレースホルダー名の和集合。 */
export type MessagePlaceholders<Message extends string> = PlaceholderNames<Message>;

/** プレースホルダーが無い文言は引数なし、あれば、すべての名前を持つ値の組が必須。 */
export type TranslateArgs<Message extends string> = [PlaceholderNames<Message>] extends [never]
  ? []
  : [params: { readonly [Name in PlaceholderNames<Message>]: string | number }];

export type Translate<Tree> = <Key extends MessageKeys<Tree>>(
  key: Key,
  ...args: TranslateArgs<MessageAt<Tree, Key> & string>
) => string;

export type MessageParamValues = Readonly<Record<string, string | number>>;

export class UnknownMessageKeyError extends Error {
  readonly key: string;

  constructor(key: string, reason = "no such message") {
    super(`message key ${JSON.stringify(key)}: ${reason}`);
    this.name = "UnknownMessageKeyError";
    this.key = key;
  }
}

export class MissingMessageParamError extends Error {
  readonly key: string;
  readonly paramName: string;

  constructor(key: string, paramName: string) {
    super(`message ${JSON.stringify(key)} needs param ${JSON.stringify(paramName)}`);
    this.name = "MissingMessageParamError";
    this.key = key;
    this.paramName = paramName;
  }
}

export class MalformedMessageError extends Error {
  readonly key: string;

  constructor(key: string, template: string) {
    super(`message ${JSON.stringify(key)} has a stray brace (use {name} with letters, digits and underscores only): ${JSON.stringify(template)}`);
    this.name = "MalformedMessageError";
    this.key = key;
  }
}

const PLACEHOLDER_PATTERN = /\{([A-Za-z][A-Za-z0-9_]*)\}/g;

/** 文言の中のプレースホルダー名を、出現順に（重複なしで）返す。 */
export function extractPlaceholders(template: string): string[] {
  const names: string[] = [];
  for (const match of template.matchAll(PLACEHOLDER_PATTERN)) {
    if (!names.includes(match[1])) {
      names.push(match[1]);
    }
  }
  return names;
}

/** プレースホルダー以外の波括弧が無いことを確かめる。あれば MalformedMessageError。 */
export function assertWellFormed(key: string, template: string): void {
  if (/[{}]/.test(template.replace(PLACEHOLDER_PATTERN, ""))) {
    throw new MalformedMessageError(key, template);
  }
}

/** {name} を値へ置き換える。置き換えた値は、再び置き換えない。値が足りなければ MissingMessageParamError。 */
export function interpolate(template: string, params: MessageParamValues | undefined, key: string): string {
  assertWellFormed(key, template);
  return template.replace(PLACEHOLDER_PATTERN, (_match, name: string) => {
    if (params === undefined || !Object.hasOwn(params, name)) {
      throw new MissingMessageParamError(key, name);
    }
    return String(params[name]);
  });
}

function lookup(catalog: MessageTree, key: string): string {
  let node: string | MessageTree = catalog;
  for (const segment of key.split(".")) {
    if (typeof node === "string" || !Object.hasOwn(node, segment)) {
      throw new UnknownMessageKeyError(key);
    }
    node = node[segment];
  }
  if (typeof node !== "string") {
    throw new UnknownMessageKeyError(key, "is a namespace, not a message");
  }
  return node;
}

/** 文言の木から、翻訳関数 t(key, params?) を作る。 */
export function createTranslator<Tree extends MessageTree>(catalog: Tree): Translate<Tree> {
  const translate = (key: string, params?: MessageParamValues): string =>
    interpolate(lookup(catalog, key), params, key);
  // 型の引数（Tree）が総称のままだと、型の照合が深くなりすぎるため、unknown を経由する
  return translate as unknown as Translate<Tree>;
}

/** すべての葉を、ドット区切りのキーと文言の組として返す（検査・ツール用）。 */
export function flattenMessages(catalog: MessageTree, prefix = ""): Record<string, string> {
  const flat: Record<string, string> = {};
  for (const [segment, node] of Object.entries(catalog)) {
    const key = prefix === "" ? segment : `${prefix}.${segment}`;
    if (typeof node === "string") {
      flat[key] = node;
    } else {
      Object.assign(flat, flattenMessages(node, key));
    }
  }
  return flat;
}
