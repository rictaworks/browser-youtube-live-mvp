// ワーカーの入り口の配線（issue #27）。薄く保つ: 実行環境（WebCodecs・OffscreenCanvas・タイマ）を作り、ホスト（PipelineHost）を作り、
// メッセージを渡す。pipeline.worker.ts（ワーカーのスクリプト本体）は、この関数を 1 回呼ぶだけ。
//
//   - 準備ができたら ready を知らせる。実行環境に必要な機能が無ければ、ready の代わりに、型付きの故障を知らせる
//     （メインスレッドが、起動の失敗を、期限切れを待たずに知れる）
//   - 符号化結果は、ArrayBuffer を転送して送る（コピーしない。prepareEventForPost）
//   - shutdown を受けて、ホストが資源を解放したら、ワーカー自身を閉じる
//   - 診断は、符号と、元のエラーの名前だけ（console.debug へ 1 行）

import { PipelineError, faultOf } from "@/lib/pipeline/errors";
import { createConsoleDiagnosticSink } from "@/lib/sources/diagnostics";
import type { DiagnosticSink } from "@/lib/sources/diagnostics";
import { createWorkerEnvironment } from "./environment";
import type { WorkerGlobals } from "./environment";
import { prepareEventForPost } from "./messages";
import type { PipelineEvent } from "./messages";
import { PipelineHost } from "./PipelineHost";

/** ワーカーの大域（self）のうち、入り口が使うもの。 */
export interface PipelineWorkerScope extends WorkerGlobals {
  postMessage(message: unknown, transfer?: Transferable[]): void;
  onmessage: ((event: MessageEvent) => void) | null;
  close(): void;
}

export interface StartOptions {
  /** 診断の出力先。既定は、console.debug へ 1 行 */
  readonly diagnostic?: DiagnosticSink;
}

/** メインスレッドへ送る関数を作る。符号化結果の ArrayBuffer は、転送する。 */
export function createPoster(scope: Pick<PipelineWorkerScope, "postMessage">): (event: PipelineEvent) => void {
  return (event) => {
    const prepared = prepareEventForPost(event);
    scope.postMessage(prepared.message, prepared.transfer);
  };
}

/**
 * ワーカーを起動する。成功したら、ホストを返す（ready を知らせ済み）。実行環境に必要な機能が無ければ、故障を知らせて null を返す。
 */
export function startPipelineWorker(scope: PipelineWorkerScope, options: StartOptions = {}): PipelineHost | null {
  const post = createPoster(scope);
  const diagnostic = options.diagnostic ?? createConsoleDiagnosticSink("pipeline-worker");
  let host: PipelineHost;
  try {
    host = new PipelineHost({ environment: createWorkerEnvironment(scope), post, diagnostic });
  } catch (error) {
    post({ type: "fault", fault: faultOf(error instanceof PipelineError ? error : new PipelineError("unexpected", error)) });
    return null;
  }
  scope.onmessage = (event: MessageEvent) => {
    host.handle(event.data);
    if (host.isDisposed) {
      scope.close();
    }
  };
  post({ type: "ready" });
  return host;
}
