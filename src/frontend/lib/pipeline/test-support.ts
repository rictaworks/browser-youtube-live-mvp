// 配信パイプライン（メインスレッド側）のテストの共通部品。テストからだけ使う（実行時のコードから import しない）。
//
// モックの境界: Worker・MediaStreamTrack・MediaStreamTrackProcessor・HTMLCanvasElement・タイマは、すべて疑似。
// ワーカーとのメッセージ（送ったもの・転送対象）を記録し、ワーカーからのメッセージ・異常終了は、テストが疑似する。
// 実際のワーカー（new Worker）・実際の MediaStreamTrackProcessor は、test/ の実ブラウザの確認が受け持つ。
import type { PipelineEvent } from "@/workers/pipeline/messages";
import type { PipelineWorkerLike, TimerApi } from "./PipelineClient";

export interface PostedMessage {
  readonly message: { readonly type: string; readonly [key: string]: unknown };
  readonly transfer: readonly unknown[];
}

/** Worker の疑似。送ったメッセージを記録する。ワーカーからのメッセージは emit で疑似する。 */
export class FakeWorker implements PipelineWorkerLike {
  onmessage: ((event: MessageEvent) => void) | null = null;
  onerror: ((event: ErrorEvent) => void) | null = null;
  onmessageerror: ((event: MessageEvent) => void) | null = null;
  readonly posted: PostedMessage[] = [];
  terminateCount = 0;
  failPost: Error | null = null;

  postMessage(message: unknown, transfer: Transferable[]): void {
    if (this.failPost !== null) {
      throw this.failPost;
    }
    this.posted.push({ message: message as PostedMessage["message"], transfer });
  }

  terminate(): void {
    this.terminateCount += 1;
  }

  /** 送られたコマンドのうち、種類が type のもの。 */
  commands(type: string): PostedMessage[] {
    return this.posted.filter((entry) => entry.message.type === type);
  }

  /** ワーカーが、イベントを送ってきたことを疑似する。 */
  emit(event: PipelineEvent): void {
    this.onmessage?.({ data: event } as MessageEvent);
  }

  emitRaw(data: unknown): void {
    this.onmessage?.({ data } as MessageEvent);
  }

  /** ワーカーの未処理の例外（異常終了）を疑似する。 */
  crash(): void {
    this.onerror?.({ message: "Uncaught Error: secret detail at https://example.invalid/x" } as ErrorEvent);
  }

  /** 直近の、応答のある要求の requestId。 */
  lastRequestId(type: string): number {
    const found = this.commands(type);
    if (found.length === 0) {
      throw new Error(`no ${type} request was posted`);
    }
    return found[found.length - 1].message.requestId as number;
  }
}

/** 手動で進めるタイマ（setTimeout・clearTimeout）。実時間を待たない。 */
export class FakeTimers implements TimerApi {
  private nextHandle = 1;
  private now = 0;
  private readonly timers = new Map<number, { readonly callback: () => void; readonly due: number }>();

  setTimeout = (callback: () => void, delayMs: number): unknown => {
    const handle = this.nextHandle++;
    this.timers.set(handle, { callback, due: this.now + delayMs });
    return handle;
  };

  clearTimeout = (handle: unknown): void => {
    this.timers.delete(handle as number);
  };

  get activeCount(): number {
    return this.timers.size;
  }

  advance(ms: number): void {
    const target = this.now + ms;
    for (;;) {
      let dueHandle: number | null = null;
      let dueTime = Number.POSITIVE_INFINITY;
      for (const [handle, timer] of this.timers) {
        if (timer.due <= target && timer.due < dueTime) {
          dueTime = timer.due;
          dueHandle = handle;
        }
      }
      if (dueHandle === null) {
        break;
      }
      const timer = this.timers.get(dueHandle);
      this.timers.delete(dueHandle);
      this.now = dueTime;
      timer?.callback();
    }
    this.now = target;
  }
}

/** MediaStreamTrack の疑似（映像）。 */
export class FakeVideoTrack {
  kind = "video";
  readyState: "live" | "ended" = "live";
  stopCount = 0;

  asTrack(): MediaStreamTrack {
    return this as unknown as MediaStreamTrack;
  }
}

/** プレビュー用の <canvas> の疑似。transferControlToOffscreen は 1 回だけ成功する（2 回目は InvalidStateError。実際の HTMLCanvasElement と同じ）。 */
export class FakePreviewCanvas {
  transferCount = 0;
  failWith: Error | null = null;
  readonly offscreen = { getContext: () => null, width: 1280, height: 720 };

  transferControlToOffscreen(): OffscreenCanvas {
    if (this.failWith !== null) {
      throw this.failWith;
    }
    this.transferCount += 1;
    if (this.transferCount > 1) {
      throw new DOMException("already transferred", "InvalidStateError");
    }
    return this.offscreen as unknown as OffscreenCanvas;
  }
}
