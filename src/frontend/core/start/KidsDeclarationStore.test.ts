/**
 * @jest-environment node
 */
// 子ども向けの申告の記憶（requirements.md 9.1・16.3）。初回は未選択、以後は前回の選択を、次回の初期値にする。
// 記憶はブラウザ内（注入するストレージ。Web Storage の形）。読めない・壊れているときは、未選択として扱う
// （利用者に、明示的な選択をさせる側へ倒す。誤った値を初期値にしない）。
//
// モックの境界：実際の localStorage（ブラウザ・オリジンごとの永続）は、このテストでは再現しない。FakeStorage は Web Storage の getItem・setItem の形だけを再現する。
import { KIDS_DECLARATION_STORAGE_KEY, KidsDeclarationStore } from "./KidsDeclarationStore";
import type { KeyValueStorageLike } from "./KidsDeclarationStore";

// 型の互換（コンパイル時の検査。tsc --noEmit が確かめる）：本物の Storage（localStorage）を、そのまま注入できる
const acceptsWebStorage = (storage: Storage): KeyValueStorageLike => storage;
void acceptsWebStorage;

class FakeStorage implements KeyValueStorageLike {
  readonly items = new Map<string, string>();
  readonly writes: Array<[string, string]> = [];

  getItem(key: string): string | null {
    return this.items.get(key) ?? null;
  }

  setItem(key: string, value: string): void {
    this.writes.push([key, value]);
    this.items.set(key, value);
  }
}

describe("KidsDeclarationStore.read", () => {
  test("初回（記憶が無い）は、未選択（null）", () => {
    expect(new KidsDeclarationStore(new FakeStorage()).read()).toBeNull();
  });

  test("書いた値を、次回の初期値として読める（はい = true・いいえ = false）。別のインスタンスでも読める", () => {
    const storage = new FakeStorage();
    expect(new KidsDeclarationStore(storage).write(true)).toBe(true);
    expect(new KidsDeclarationStore(storage).read()).toBe(true);
    expect(new KidsDeclarationStore(storage).write(false)).toBe(true);
    expect(new KidsDeclarationStore(storage).read()).toBe(false);
  });

  test("最後の選択が残る（上書き）", () => {
    const store = new KidsDeclarationStore(new FakeStorage());
    store.write(true);
    store.write(false);
    store.write(true);
    expect(store.read()).toBe(true);
  });

  test.each([
    ["空文字", ""],
    ["未知の文字列", "maybe"],
    ["大文字", "TRUE"],
    ["数値の文字列", "1"],
    ["JSON の null", "null"],
    ["前後に空白", " true"],
  ])("記憶が壊れている（%s）ときは、未選択（null）。誤った値を初期値にしない", (_label, stored) => {
    const storage = new FakeStorage();
    storage.items.set(KIDS_DECLARATION_STORAGE_KEY, stored);
    expect(new KidsDeclarationStore(storage).read()).toBeNull();
  });

  test("ストレージが例外を投げる（無効・容量・プライベートモード）ときは、未選択（null）", () => {
    const storage: KeyValueStorageLike = {
      getItem: () => {
        throw new Error("SecurityError: storage is disabled");
      },
      setItem: () => undefined,
    };
    expect(new KidsDeclarationStore(storage).read()).toBeNull();
  });

  test.each([
    ["undefined（localStorage にアクセスできない環境）", undefined],
    ["null", null],
  ])("ストレージが無い（%s）ときは、未選択（null）", (_label, storage) => {
    expect(new KidsDeclarationStore(storage).read()).toBeNull();
  });
});

describe("KidsDeclarationStore.write", () => {
  test("記憶できたら true。固定の ASCII のキーに、\"true\" か \"false\" の文字列だけを書く（他の情報を書かない）", () => {
    const storage = new FakeStorage();
    const store = new KidsDeclarationStore(storage);
    expect(store.write(true)).toBe(true);
    expect(store.write(false)).toBe(true);
    expect(storage.writes).toEqual([
      [KIDS_DECLARATION_STORAGE_KEY, "true"],
      [KIDS_DECLARATION_STORAGE_KEY, "false"],
    ]);
    expect(KIDS_DECLARATION_STORAGE_KEY).toMatch(/^[a-z0-9._:-]+$/);
  });

  test("ストレージが例外を投げたら、false（記憶できなかった。例外にしない：選択の記憶は、配信の開始を妨げない）", () => {
    const storage: KeyValueStorageLike = {
      getItem: () => null,
      setItem: () => {
        throw new Error("QuotaExceededError");
      },
    };
    expect(new KidsDeclarationStore(storage).write(true)).toBe(false);
  });

  test("ストレージが無ければ、false", () => {
    expect(new KidsDeclarationStore(undefined).write(true)).toBe(false);
    expect(new KidsDeclarationStore(null).write(false)).toBe(false);
  });

  test("真偽値でない値は、記憶せず RangeError（未選択を、記憶として書かない）", () => {
    const storage = new FakeStorage();
    const store = new KidsDeclarationStore(storage);
    expect(() => store.write(null as never)).toThrow(RangeError);
    expect(() => store.write(undefined as never)).toThrow(RangeError);
    expect(() => store.write("true" as never)).toThrow(RangeError);
    expect(storage.writes).toEqual([]);
  });

  test("キーを指定すれば、別のキーに記憶する（既定のキーに影響しない）", () => {
    const storage = new FakeStorage();
    new KidsDeclarationStore(storage, "other-key").write(true);
    expect(storage.items.get("other-key")).toBe("true");
    expect(new KidsDeclarationStore(storage).read()).toBeNull();
  });
});
