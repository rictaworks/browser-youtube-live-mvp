import {
  MalformedMessageError,
  MissingMessageParamError,
  UnknownMessageKeyError,
  assertWellFormed,
  createTranslator,
  extractPlaceholders,
  flattenMessages,
  interpolate,
} from "./messages";

// 文言カタログの仕組みの単体テスト。実際のカタログ（messages/）ではなく、小さなカタログで確かめる。
const catalog = {
  greeting: {
    hello: "こんにちは",
    withName: "{name} さん、こんにちは",
    twice: "{name} と {name}",
  },
  count: {
    remaining: "残り {count} 文字",
  },
  nested: {
    deeper: {
      leaf: "葉",
    },
  },
} as const;

const t = createTranslator(catalog);

describe("createTranslator: 文言の取得", () => {
  it("ドット区切りのキーで、文言を返す", () => {
    expect(t("greeting.hello")).toBe("こんにちは");
    expect(t("nested.deeper.leaf")).toBe("葉");
  });

  it("{name} を、渡した値へ置き換える", () => {
    expect(t("greeting.withName", { name: "山田" })).toBe("山田 さん、こんにちは");
  });

  it("数値も渡せる", () => {
    expect(t("count.remaining", { count: 78 })).toBe("残り 78 文字");
    expect(t("count.remaining", { count: 0 })).toBe("残り 0 文字");
  });

  it("同じ名前が複数回あれば、すべて置き換える", () => {
    expect(t("greeting.twice", { name: "A" })).toBe("A と A");
  });

  it("渡した値に含まれる {…} を、置き換え直さない", () => {
    expect(t("greeting.withName", { name: "{count}" })).toBe("{count} さん、こんにちは");
  });

  it("渡した値の中の特殊な文字列（$&・$1）を、そのまま出力する", () => {
    expect(t("greeting.withName", { name: "$& $1 $$" })).toBe("$& $1 $$ さん、こんにちは");
  });
});

describe("createTranslator: 異常系（既定の文言を補わず、例外にする）", () => {
  it("存在しないキーは UnknownMessageKeyError", () => {
    // @ts-expect-error 存在しないキーは、型の検査でも弾く
    expect(() => t("greeting.missing")).toThrow(UnknownMessageKeyError);
  });

  it("名前空間（葉でないキー）は UnknownMessageKeyError", () => {
    // @ts-expect-error 葉でないキーは、型の検査でも弾く
    expect(() => t("greeting")).toThrow(UnknownMessageKeyError);
  });

  it("Object のプロパティ名（継承されたもの）を、キーとして受け付けない", () => {
    for (const key of ["constructor", "toString", "__proto__", "greeting.constructor", "greeting.__proto__"]) {
      // @ts-expect-error 型の検査でも弾く
      expect(() => t(key)).toThrow(UnknownMessageKeyError);
    }
  });

  it("空のキーは UnknownMessageKeyError", () => {
    // @ts-expect-error 型の検査でも弾く
    expect(() => t("")).toThrow(UnknownMessageKeyError);
  });

  it("値が足りなければ MissingMessageParamError。キーと名前を持つ", () => {
    try {
      // @ts-expect-error 必要な値を渡さないと、型の検査でも弾く
      t("greeting.withName");
      throw new Error("例外が投げられませんでした");
    } catch (error) {
      expect(error).toBeInstanceOf(MissingMessageParamError);
      expect((error as MissingMessageParamError).key).toBe("greeting.withName");
      expect((error as MissingMessageParamError).paramName).toBe("name");
    }
  });

  it("別の名前の値だけを渡しても、足りないので MissingMessageParamError", () => {
    // @ts-expect-error 名前の誤りは、型の検査でも弾く
    expect(() => t("greeting.withName", { nmae: "山田" })).toThrow(MissingMessageParamError);
  });

  it("不要な値を渡すと、型の検査で弾く（実行時は無視する）", () => {
    // @ts-expect-error プレースホルダーの無い文言へ、値を渡せない
    expect(t("greeting.hello", { name: "山田" })).toBe("こんにちは");
  });

  it("UnknownMessageKeyError は、キーを持つ", () => {
    try {
      // @ts-expect-error 存在しないキー
      t("nope.nothing");
      throw new Error("例外が投げられませんでした");
    } catch (error) {
      expect(error).toBeInstanceOf(UnknownMessageKeyError);
      expect((error as UnknownMessageKeyError).key).toBe("nope.nothing");
    }
  });
});

describe("extractPlaceholders", () => {
  it.each([
    ["無し", "こんにちは", []],
    ["1 つ", "{name} さん", ["name"]],
    ["複数（出現順）", "{b} と {a}", ["b", "a"]],
    ["重複は 1 つにまとめる", "{a} {b} {a}", ["a", "b"]],
    ["英数字とアンダースコア", "{item_2}", ["item_2"]],
  ])("%s", (_label, template, expected) => {
    expect(extractPlaceholders(template)).toEqual(expected);
  });
});

describe("assertWellFormed: 文言の中の波括弧", () => {
  it.each([
    ["プレースホルダーのみ", "{name}"],
    ["波括弧が無い", "波括弧なし"],
  ])("%s は正しい", (_label, template) => {
    expect(() => assertWellFormed("key", template)).not.toThrow();
  });

  it.each([
    ["閉じていない", "{name"],
    ["開いていない", "name}"],
    ["空", "{}"],
    ["空白を含む", "{ name }"],
    ["数字で始まる名前", "{1abc}"],
    ["入れ子", "{{name}}"],
    ["単独の開き", "{"],
  ])("%s は MalformedMessageError", (_label, template) => {
    expect(() => assertWellFormed("key", template)).toThrow(MalformedMessageError);
  });
});

describe("interpolate", () => {
  it("値が不足していれば、キーを添えて例外にする", () => {
    expect(() => interpolate("{a} {b}", { a: "x" }, "some.key")).toThrow(MissingMessageParamError);
  });

  it("壊れた文言は、置き換えの前に例外にする", () => {
    expect(() => interpolate("{a", { a: "x" }, "some.key")).toThrow(MalformedMessageError);
  });
});

describe("flattenMessages", () => {
  it("すべての葉を、ドット区切りのキーとして返す", () => {
    expect(flattenMessages(catalog)).toEqual({
      "greeting.hello": "こんにちは",
      "greeting.withName": "{name} さん、こんにちは",
      "greeting.twice": "{name} と {name}",
      "count.remaining": "残り {count} 文字",
      "nested.deeper.leaf": "葉",
    });
  });
});
