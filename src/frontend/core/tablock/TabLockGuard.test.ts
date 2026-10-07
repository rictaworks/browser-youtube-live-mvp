/**
 * @jest-environment node
 */
// タブ間の排他（requirements.md 13.1「二重開始の試行」・14・30.1）。
//   - ロックのマネージャーを注入する（Web Locks API の形。本物の navigator.locks をそのまま渡せる）
//   - 取れなければ false（二重開始の試行）。ロック API が無い環境は "unsupported" として区別して返す（黙って成功にしない）
//   - 解放の確実性：例外・複数回の呼び出し・取得の途中・ロックを奪われたとき
//
// モックの境界：実際の複数タブ（同じオリジンの別のタブ）は、このテストでは再現できない。
// FakeLockManager は、Web Locks API の排他ロック（ifAvailable 付き）の規則（保持中なら null を渡す・保持を解くのは、コールバックが返す Promise の決着）を再現する。
// 実ブラウザでの複数タブの確認は、ユーザーテストの手順（README）で行う。
import { TAB_LOCK_NAME, TabLockError, TabLockGuard } from "./TabLockGuard";
import type { LockManagerLike, LockRequestOptionsLike } from "./TabLockGuard";

// 型の互換（コンパイル時の検査。tsc --noEmit が確かめる）：本物の Web Locks API（LockManager）を、そのまま注入できる
const acceptsWebLocks = (manager: LockManager): LockManagerLike => manager;
void acceptsWebLocks;

interface RecordedRequest {
  readonly name: string;
  readonly options: LockRequestOptionsLike;
}

/** Web Locks API の排他ロック（ifAvailable）を再現する疑似のマネージャー。同じ疑似のマネージャーを共有する guard が「別のタブ」になる。 */
class FakeLockManager implements LockManagerLike {
  readonly requests: RecordedRequest[] = [];
  /** true なら、保持者の解放（コールバックの Promise の決着）から、ロックが空き、request の Promise が決着するまでに、マクロタスクの時間がかかる（本物の Web Locks の解放は非同期）。 */
  slowRelease = false;
  private readonly holders = new Map<string, (reason: Error) => void>();

  request(name: string, options: LockRequestOptionsLike, callback: (lock: unknown) => unknown): Promise<unknown> {
    this.requests.push({ name, options });
    if (options.ifAvailable !== true || options.mode !== "exclusive") {
      throw new Error("TabLockGuard must request an exclusive lock with ifAvailable (never wait for another tab)");
    }
    return new Promise((resolve, reject) => {
      // 本物と同じく、コールバックは非同期に呼ばれる
      void Promise.resolve().then(() => {
        if (this.holders.has(name)) {
          resolve(callback(null));
          return;
        }
        this.holders.set(name, reject);
        Promise.resolve(callback({ name, mode: "exclusive" })).then(
          (value) => this.free(name, () => resolve(value)),
          (error: unknown) => this.free(name, () => reject(error)),
        );
      });
    });
  }

  /** ロックを空け、そのあとで、request の Promise を決着させる。 */
  private free(name: string, settle: () => void): void {
    const release = (): void => {
      this.holders.delete(name);
      settle();
    };
    if (this.slowRelease) {
      setImmediate(release);
    } else {
      release();
    }
  }

  isHeld(name: string): boolean {
    return this.holders.has(name);
  }

  /** 別のコンテキストが、steal でロックを奪った（保持していた側の request の Promise は AbortError で拒否される）。 */
  steal(name: string): void {
    const reject = this.holders.get(name);
    if (reject === undefined) {
      throw new Error(`no holder for ${name}`);
    }
    this.holders.delete(name);
    reject(new Error("AbortError: the lock was stolen"));
  }
}

/** 待っている Promise の連鎖（マイクロタスク）が、すべて進むまで待つ。 */
function flushPromises(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}

describe("TabLockGuard: 取得", () => {
  test("空いていれば true。排他（exclusive）・待たない（ifAvailable）で要求する", async () => {
    const manager = new FakeLockManager();
    const guard = new TabLockGuard(manager);
    expect(await guard.acquire()).toBe(true);
    expect(guard.isHeld).toBe(true);
    expect(manager.isHeld(TAB_LOCK_NAME)).toBe(true);
    expect(manager.requests).toEqual([{ name: TAB_LOCK_NAME, options: { mode: "exclusive", ifAvailable: true } }]);
  });

  test("別のタブ（同じ疑似のマネージャーを共有する guard）が保持中なら false（二重開始の試行）。保持していない", async () => {
    const manager = new FakeLockManager();
    const first = new TabLockGuard(manager);
    const second = new TabLockGuard(manager);
    expect(await first.acquire()).toBe(true);
    expect(await second.acquire()).toBe(false);
    expect(second.isHeld).toBe(false);
    expect(first.isHeld).toBe(true);
    expect(manager.isHeld(TAB_LOCK_NAME)).toBe(true);
  });

  test("保持者が解放すれば、別のタブが取得できる", async () => {
    const manager = new FakeLockManager();
    const first = new TabLockGuard(manager);
    const second = new TabLockGuard(manager);
    await first.acquire();
    expect(await second.acquire()).toBe(false);

    await first.release();
    expect(manager.isHeld(TAB_LOCK_NAME)).toBe(false);
    expect(await second.acquire()).toBe(true);
    expect(await first.acquire()).toBe(false);
  });

  test("false だったあと、相手が解放すれば、同じ guard が改めて取得できる", async () => {
    const manager = new FakeLockManager();
    const holder = new TabLockGuard(manager);
    const waiter = new TabLockGuard(manager);
    await holder.acquire();
    expect(await waiter.acquire()).toBe(false);
    await holder.release();
    expect(await waiter.acquire()).toBe(true);
    expect(waiter.isHeld).toBe(true);
  });

  test("名前が違えば、別のロック（互いに妨げない）", async () => {
    const manager = new FakeLockManager();
    const first = new TabLockGuard(manager, "lock-a");
    const second = new TabLockGuard(manager, "lock-b");
    expect(await first.acquire()).toBe(true);
    expect(await second.acquire()).toBe(true);
    expect(manager.requests.map((request) => request.name)).toEqual(["lock-a", "lock-b"]);
  });

  test("保持中の guard の acquire() は、要求を重ねず true（同じ保持者。冪等）", async () => {
    const manager = new FakeLockManager();
    const guard = new TabLockGuard(manager);
    expect(await guard.acquire()).toBe(true);
    expect(await guard.acquire()).toBe(true);
    expect(await guard.acquire()).toBe(true);
    expect(manager.requests).toHaveLength(1);
  });

  test("取得の完了を待たずに acquire() を重ねても、要求は 1 回で、全員が同じ結果", async () => {
    const manager = new FakeLockManager();
    const guard = new TabLockGuard(manager);
    const results = await Promise.all([guard.acquire(), guard.acquire(), guard.acquire()]);
    expect(results).toEqual([true, true, true]);
    expect(manager.requests).toHaveLength(1);
  });

  test("別のタブに取られているときに重ねても、全員が false（要求は 1 回）", async () => {
    const manager = new FakeLockManager();
    await new TabLockGuard(manager).acquire();
    const guard = new TabLockGuard(manager);
    const results = await Promise.all([guard.acquire(), guard.acquire()]);
    expect(results).toEqual([false, false]);
    expect(manager.requests).toHaveLength(2); // 先に取った guard の 1 回 + この guard の 1 回
  });
});

describe("TabLockGuard: ロック API が無い環境（黙って成功にしない）", () => {
  test.each([
    ["undefined（navigator.locks が無い）", undefined],
    ["null", null],
    ["request を持たないオブジェクト", {}],
    ["request が関数でない", { request: 1 }],
  ])("%s：\"unsupported\"（成功でも失敗でもない、別の結果。サーバー側の排他のみで運用する結果として、呼び出し側が扱う）", async (_label, manager) => {
    const guard = new TabLockGuard(manager as never);
    const result = await guard.acquire();
    expect(result).toBe("unsupported");
    expect(result).not.toBe(true);
    expect(result).not.toBe(false);
    expect(guard.isHeld).toBe(false);
  });

  test("unsupported でも、release() は何もせず成功し、何度呼んでも同じ", async () => {
    const guard = new TabLockGuard(undefined);
    await guard.acquire();
    await expect(guard.release()).resolves.toBeUndefined();
    await expect(guard.release()).resolves.toBeUndefined();
    expect(await guard.acquire()).toBe("unsupported");
  });
});

describe("TabLockGuard: 解放の確実性", () => {
  test("release() のあと、ロックは確実に解放されている（待てば、別のタブが即座に取得できる）", async () => {
    const manager = new FakeLockManager();
    const guard = new TabLockGuard(manager);
    await guard.acquire();
    await guard.release();
    expect(guard.isHeld).toBe(false);
    expect(manager.isHeld(TAB_LOCK_NAME)).toBe(false);
    expect(await new TabLockGuard(manager).acquire()).toBe(true);
  });

  test("取得していない guard の release() は、何もしない（例外なし）", async () => {
    const manager = new FakeLockManager();
    const guard = new TabLockGuard(manager);
    await expect(guard.release()).resolves.toBeUndefined();
    expect(manager.requests).toHaveLength(0);
  });

  test("release() を複数回呼んでも、例外にならず、2 回目以降は何もしない。他のタブの保持を解かない", async () => {
    const manager = new FakeLockManager();
    const first = new TabLockGuard(manager);
    await first.acquire();
    await first.release();
    const second = new TabLockGuard(manager);
    expect(await second.acquire()).toBe(true);

    await first.release();
    await first.release();
    expect(manager.isHeld(TAB_LOCK_NAME)).toBe(true);
    expect(second.isHeld).toBe(true);
  });

  test("release() を待たずに重ねて呼んでも、解放は 1 回で、ロックは空く", async () => {
    const manager = new FakeLockManager();
    const guard = new TabLockGuard(manager);
    await guard.acquire();
    await Promise.all([guard.release(), guard.release(), guard.release()]);
    expect(guard.isHeld).toBe(false);
    expect(manager.isHeld(TAB_LOCK_NAME)).toBe(false);
  });

  test("解放したあと、同じ guard で再び取得できる（要求は新しくなる）", async () => {
    const manager = new FakeLockManager();
    const guard = new TabLockGuard(manager);
    expect(await guard.acquire()).toBe(true);
    await guard.release();
    expect(await guard.acquire()).toBe(true);
    expect(guard.isHeld).toBe(true);
    expect(manager.requests).toHaveLength(2);
  });

  test("release() の完了を待たずに acquire() しても、解放の完了を待ってから要求するため、取れないと誤判定されない（解放が非同期の疑似のマネージャーで検査）", async () => {
    const manager = new FakeLockManager();
    manager.slowRelease = true;
    const guard = new TabLockGuard(manager);
    await guard.acquire();
    const releasing = guard.release();
    const acquiring = guard.acquire();
    expect(await acquiring).toBe(true);
    await releasing;
    expect(guard.isHeld).toBe(true);
    expect(manager.isHeld(TAB_LOCK_NAME)).toBe(true);
  });

  test("取得できなかった（false）guard の release() は、何もしない。別のタブの保持を解かない", async () => {
    const manager = new FakeLockManager();
    const holder = new TabLockGuard(manager);
    const loser = new TabLockGuard(manager);
    await holder.acquire();
    expect(await loser.acquire()).toBe(false);

    await expect(loser.release()).resolves.toBeUndefined();
    expect(manager.isHeld(TAB_LOCK_NAME)).toBe(true);
    expect(holder.isHeld).toBe(true);
  });

  test("取得の途中で release() を呼ぶと、取得の結果を待って、取れていれば解放する（ロックを持ったまま残さない）", async () => {
    const manager = new FakeLockManager();
    const guard = new TabLockGuard(manager);
    const acquiring = guard.acquire();
    const releasing = guard.release();
    await Promise.all([acquiring, releasing]);
    expect(guard.isHeld).toBe(false);
    expect(manager.isHeld(TAB_LOCK_NAME)).toBe(false);
    expect(await new TabLockGuard(manager).acquire()).toBe(true);
  });

  test("別のタブが保持している間に、取得（取れない）の途中で release() を呼んでも、相手の保持を解かない", async () => {
    const manager = new FakeLockManager();
    const holder = new TabLockGuard(manager);
    await holder.acquire();
    const loser = new TabLockGuard(manager);
    const acquiring = loser.acquire();
    const releasing = loser.release();
    expect(await acquiring).toBe(false);
    await releasing;
    expect(manager.isHeld(TAB_LOCK_NAME)).toBe(true);
    expect(holder.isHeld).toBe(true);
    expect(loser.isHeld).toBe(false);
  });

  test("別のコンテキストにロックを奪われたら、保持していない状態へ戻る。release() は例外にならず、再び取得できる", async () => {
    const manager = new FakeLockManager();
    const guard = new TabLockGuard(manager);
    await guard.acquire();
    manager.steal(TAB_LOCK_NAME);
    await flushPromises();
    expect(guard.isHeld).toBe(false);

    await expect(guard.release()).resolves.toBeUndefined();
    expect(await guard.acquire()).toBe(true);
  });
});

describe("TabLockGuard: 例外（握りつぶさず TabLockError。状態は取得前に戻る）", () => {
  test("request が同期的に例外を投げたら、acquire() は TabLockError（原因つき）で拒否される。保持していない。次の取得を妨げない", async () => {
    const cause = new Error("SecurityError: locks are not available");
    let calls = 0;
    const manager: LockManagerLike = {
      request: () => {
        calls += 1;
        if (calls === 1) {
          throw cause;
        }
        return Promise.resolve(undefined);
      },
    };
    const guard = new TabLockGuard(manager);
    const failure = await guard.acquire().then(
      () => null,
      (error: unknown) => error,
    );
    expect(failure).toBeInstanceOf(TabLockError);
    expect((failure as TabLockError).cause).toBe(cause);
    expect(guard.isHeld).toBe(false);
    await expect(guard.release()).resolves.toBeUndefined();
    // 2 回目の取得は、新しい要求として試みられる（失敗の状態を引きずらない）
    await guard.acquire().catch(() => undefined);
    expect(calls).toBe(2);
  });

  test("コールバックが呼ばれる前に request の Promise が拒否されたら、acquire() は TabLockError で拒否される。保持していない", async () => {
    const cause = new Error("NotSupportedError");
    const manager: LockManagerLike = { request: () => Promise.reject(cause) };
    const guard = new TabLockGuard(manager);
    const failure = await guard.acquire().then(
      () => null,
      (error: unknown) => error,
    );
    expect(failure).toBeInstanceOf(TabLockError);
    expect((failure as TabLockError).cause).toBe(cause);
    expect(guard.isHeld).toBe(false);
    await expect(guard.release()).resolves.toBeUndefined();
  });

  test("TabLockError は、名前と原因とメッセージを持つ（デバッグでたどれる）", () => {
    const cause = new Error("inner");
    const error = new TabLockError("could not request the lock", cause);
    expect(error.name).toBe("TabLockError");
    expect(error.cause).toBe(cause);
    expect(error.message).toContain("could not request the lock");
  });
});

describe("TabLockGuard: 既定のロック名", () => {
  test("既定の名前は、ASCII の固定値（利用者に表示する文字列ではない）", () => {
    expect(TAB_LOCK_NAME).toMatch(/^[a-z0-9._:-]+$/);
  });
});
