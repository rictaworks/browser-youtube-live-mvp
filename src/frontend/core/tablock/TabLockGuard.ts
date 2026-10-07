// タブ間の排他（requirements.md 13.1「二重開始の試行」・14・30.1）。同一ブラウザの複数タブから、同時に配信を開始しないようにする。
//
//   - ロックのマネージャーを注入する（Web Locks API の形。本物の navigator.locks をそのまま渡せる）。Domain Core は、ブラウザの大域の物を参照しない
//   - 取れなければ false（二重開始の試行。開始せず、進行中の配信がある旨と、復帰・停止の操作を示す）
//   - ロック API が無い環境は "unsupported" として区別して返す（黙って成功にしない）。サーバー側の排他のみで運用する結果として、呼び出し側が扱う
//   - 保持は、acquire() から release() まで（配信の開始から終了まで）。タブを閉じる・クラッシュしたときは、ブラウザがロックを解放する
//   - 解放の確実性：release() は何度呼んでも安全で、完了を待てば、ロックは確実に空いている

/** ロックの要求のオプション（Web Locks API の LockOptions のうち、使うもの）。 */
export interface LockRequestOptionsLike {
  readonly mode?: "exclusive" | "shared";
  readonly ifAvailable?: boolean;
}

/**
 * ロックのマネージャー（Web Locks API の LockManager の形）。
 * request は、コールバックが返す Promise が決着するまでロックを保持し、決着すると解放する。
 * ifAvailable で、取れないとき（別の保持者がいるとき）は、待たずに、コールバックへ null を渡す。
 */
export interface LockManagerLike {
  request(name: string, options: LockRequestOptionsLike, callback: (lock: unknown) => unknown): Promise<unknown>;
}

/** acquire() の結果。true = 取得した（または、この guard が既に保持している）、false = 別のタブが保持している、"unsupported" = ロック API が無い。 */
export type TabLockAcquireResult = boolean | "unsupported";

/** 既定のロック名（ASCII の固定値）。同じオリジンの全タブで共通。 */
export const TAB_LOCK_NAME = "bl.broadcast-start";

/** ロックの要求そのものに失敗した（API が例外を投げた・Promise が拒否された）。原因を cause に持つ。 */
export class TabLockError extends Error {
  constructor(message: string, cause?: unknown) {
    super(message, { cause });
    this.name = "TabLockError";
  }
}

/** 1 回のロックの要求（取得から保持の終わりまで）。 */
interface LockSession {
  /** 取得の結果（true = 取得した、false = 別の保持者がいる）。要求そのものに失敗したら、TabLockError で拒否される */
  readonly acquired: Promise<boolean>;
  /** 保持を解く（コールバックが返す Promise を決着させる）。取得していなければ、何も起きない */
  readonly letGo: () => void;
  /** 要求が終わった（保持を解いた・ロックを奪われた・取得できなかった・失敗した）。拒否されない */
  readonly finished: Promise<void>;
}

function noop(): void {
  // 何もしない（Promise の解決関数の仮の初期値）
}

function isLockManager(manager: LockManagerLike | null | undefined): manager is LockManagerLike {
  return manager !== null && manager !== undefined && typeof manager.request === "function";
}

export class TabLockGuard {
  private session: LockSession | null = null;
  private held = false;
  /** 直近の解放の完了。解放の途中に acquire() が来ても、完了を待ってから要求する（取れないと誤判定されない）。 */
  private releasing: Promise<void> = Promise.resolve();

  constructor(
    private readonly manager: LockManagerLike | null | undefined,
    private readonly lockName: string = TAB_LOCK_NAME,
  ) {}

  /** ロックを保持している。 */
  get isHeld(): boolean {
    return this.held;
  }

  /**
   * ロックの取得を試みる（待たない）。
   * 取得できたら true。既に保持している guard では、要求を重ねず true（冪等）。別のタブが保持していたら false。
   * ロック API が無ければ "unsupported"。取得の完了を待たずに重ねて呼んでも、要求は 1 回で、同じ結果を返す。
   * 要求そのものに失敗したら TabLockError（保持していない状態へ戻り、次の取得を妨げない）。
   */
  acquire(): Promise<TabLockAcquireResult> {
    if (!isLockManager(this.manager)) {
      return Promise.resolve("unsupported");
    }
    if (this.session === null) {
      const session = this.openSession(this.manager, this.releasing);
      this.session = session;
      void session.acquired.then(
        (granted) => {
          if (this.session === session) {
            this.held = granted;
            if (!granted) {
              this.session = null;
            }
          }
        },
        () => {
          if (this.session === session) {
            this.session = null;
          }
        },
      );
      void session.finished.then(() => {
        if (this.session === session) {
          // 保持している途中で、要求が終わった（ロックを奪われた）。保持していない状態へ戻る
          this.session = null;
          this.held = false;
        }
      });
    }
    return this.session.acquired;
  }

  /**
   * 保持を解く。保持していなければ（複数回の呼び出し・取得していない・unsupported・取得に失敗した）、何もしない（例外にならない）。
   * 取得の途中なら、結果を待ち、取れていれば解く。返す Promise は、ロックが解放されてから決着する。
   */
  release(): Promise<void> {
    const session = this.session;
    if (session === null) {
      return this.releasing;
    }
    this.session = null;
    this.held = false;
    this.releasing = this.finishRelease(session);
    return this.releasing;
  }

  /**
   * 保持を解いて、ロックが解放されるのを待つ。取得の途中でも、同じ手順でよい：letGo() で、保持の Promise を先に決着させておけば、
   * あとでロックが得られた瞬間に（コールバックが決着済みの Promise を返すので）解放される。取れなかった・失敗したときは、解く物が無い。
   */
  private async finishRelease(session: LockSession): Promise<void> {
    session.letGo();
    await session.finished;
  }

  private openSession(manager: LockManagerLike, after: Promise<void>): LockSession {
    let resolveAcquired: (granted: boolean) => void = noop;
    let rejectAcquired: (error: TabLockError) => void = noop;
    const acquired = new Promise<boolean>((resolve, reject) => {
      resolveAcquired = resolve;
      rejectAcquired = reject;
    });
    let letGo: () => void = noop;
    const holding = new Promise<void>((resolve) => {
      letGo = resolve;
    });
    let answered = false;
    let granted = false;

    const finished = after
      .then(() =>
        manager.request(this.lockName, { mode: "exclusive", ifAvailable: true }, (lock) => {
          answered = true;
          if (lock === null) {
            resolveAcquired(false);
            return undefined;
          }
          granted = true;
          resolveAcquired(true);
          return holding;
        }),
      )
      .then(
        () => {
          if (!answered) {
            rejectAcquired(new TabLockError(`the lock manager finished the request for ${this.lockName} without calling back`));
          }
        },
        (cause: unknown) => {
          // 取得する前の失敗は、呼び出し側へ伝える。取得したあとの拒否（ロックを奪われた）は、保持が終わっただけ
          if (!granted) {
            rejectAcquired(new TabLockError(`could not request the lock ${this.lockName}`, cause));
          }
        },
      );
    return { acquired, letGo, finished };
  }
}
