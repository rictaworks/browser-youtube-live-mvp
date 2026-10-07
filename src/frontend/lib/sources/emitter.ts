// 購読者への通知。購読者の例外が、通知を行った側の処理（ソースの取得・音声の混合の制御）と、他の購読者を止めないようにする。
// 例外は握りつぶさない。指定の処理（onError）へ渡す。既定は、次のタスクで投げ直す（rethrowLater）。

/** 購読者の例外の扱い。 */
export type ListenerErrorHandler = (error: unknown) => void;

/**
 * 既定の例外の扱い。次のタスクで、同じ例外を投げ直す。
 * 購読者の不具合を、通知した側の処理（getDisplayMedia の呼び出しなど）を止めずに、未処理の例外として見える形で出すため。
 */
export function rethrowLater(error: unknown): void {
  setTimeout(() => {
    throw error;
  }, 0);
}

export class Emitter<Listener> {
  private readonly listeners = new Set<Listener>();

  constructor(private readonly onError: ListenerErrorHandler = rethrowLater) {}

  /** 購読する。購読の解除の関数を返す（何度呼んでもよい）。同じ購読者を重ねて購読しても、通知は 1 回。 */
  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  /**
   * すべての購読者へ、invoke で通知する。購読の順。通知の最中に解除された購読者は呼ばない。通知の最中に追加された購読者は、次の通知から。
   * 購読者の例外は、他の購読者への通知を止めず、onError へ渡す。
   */
  notify(invoke: (listener: Listener) => void): void {
    for (const listener of [...this.listeners]) {
      if (!this.listeners.has(listener)) {
        continue;
      }
      try {
        invoke(listener);
      } catch (error) {
        this.onError(error);
      }
    }
  }

  get size(): number {
    return this.listeners.size;
  }
}
