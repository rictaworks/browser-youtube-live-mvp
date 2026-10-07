// Emitter（購読者への通知）。購読者の例外が、通知を行った側の処理（ソースの取得など）と、他の購読者を止めないこと。
// 例外は握りつぶさず、指定の処理へ渡す（既定は、次のタスクで投げ直して、未処理の例外として見える形にする）。
import { Emitter, rethrowLater } from "./emitter";

describe("Emitter", () => {
  it("購読した順に、通知する", () => {
    const emitter = new Emitter<(value: number) => void>(() => undefined);
    const calls: string[] = [];
    emitter.subscribe((value) => calls.push(`a${value}`));
    emitter.subscribe((value) => calls.push(`b${value}`));

    emitter.notify((listener) => listener(1));

    expect(calls).toEqual(["a1", "b1"]);
  });

  it("購読の解除は、関数を返す。解除したあとは、通知されない。解除は何度呼んでもよい", () => {
    const emitter = new Emitter<() => void>(() => undefined);
    const listener = jest.fn();
    const unsubscribe = emitter.subscribe(listener);

    unsubscribe();
    unsubscribe();
    emitter.notify((entry) => entry());

    expect(listener).not.toHaveBeenCalled();
    expect(emitter.size).toBe(0);
  });

  it("同じ関数を 2 回購読しても、1 回だけ通知される（解除は 1 回で足りる）", () => {
    const emitter = new Emitter<() => void>(() => undefined);
    const listener = jest.fn();
    emitter.subscribe(listener);
    const unsubscribe = emitter.subscribe(listener);

    emitter.notify((entry) => entry());
    unsubscribe();
    emitter.notify((entry) => entry());

    expect(listener).toHaveBeenCalledTimes(1);
  });

  it("購読者の例外は、他の購読者への通知を止めず、通知した側へも伝わらない。例外は、処理へ渡す", () => {
    const errors: unknown[] = [];
    const emitter = new Emitter<() => void>((error) => errors.push(error));
    const failure = new Error("listener failure");
    const after = jest.fn();
    emitter.subscribe(() => {
      throw failure;
    });
    emitter.subscribe(after);

    expect(() => emitter.notify((listener) => listener())).not.toThrow();

    expect(errors).toEqual([failure]);
    expect(after).toHaveBeenCalledTimes(1);
  });

  it("通知の最中の購読・解除は、その通知の対象を変えない（解除された購読者は、呼ばれない。追加された購読者は、次の通知から）", () => {
    const emitter = new Emitter<() => void>(() => undefined);
    const calls: string[] = [];
    let unsubscribeSecond: () => void = () => undefined;
    emitter.subscribe(() => {
      calls.push("first");
      unsubscribeSecond();
      emitter.subscribe(() => calls.push("added"));
    });
    unsubscribeSecond = emitter.subscribe(() => calls.push("second"));

    emitter.notify((listener) => listener());

    expect(calls).toEqual(["first"]);
    emitter.notify((listener) => listener());
    expect(calls).toEqual(["first", "first", "added"]);
  });

  it("購読者がいなくても、通知は成功する", () => {
    expect(() => new Emitter<() => void>(() => undefined).notify((listener) => listener())).not.toThrow();
  });
});

describe("rethrowLater（既定の例外の扱い）", () => {
  beforeEach(() => {
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it("次のタスクで、同じ例外を投げ直す（握りつぶさない。通知した側の処理も止めない）", () => {
    const failure = new Error("listener failure");
    const emitter = new Emitter<() => void>();
    emitter.subscribe(() => {
      throw failure;
    });

    expect(() => emitter.notify((listener) => listener())).not.toThrow();

    expect(() => jest.runAllTimers()).toThrow(failure);
  });

  it("単体でも、呼び出した時点では投げない", () => {
    expect(() => rethrowLater(new Error("later"))).not.toThrow();
    expect(() => jest.runAllTimers()).toThrow("later");
  });
});
