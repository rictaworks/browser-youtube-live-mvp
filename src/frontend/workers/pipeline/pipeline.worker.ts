// 配信パイプラインのワーカー（issue #27）のスクリプト本体。メインスレッドの lib/pipeline/defaultWorker.ts が、
// new Worker(new URL("…/pipeline.worker.ts", import.meta.url), { type: "module" }) で起動する（Next.js が、このファイルをワーカー用にバンドルする）。
// ここは配線だけ。仕事は startWorker.ts（入り口）・PipelineHost.ts（本体）にある。
import { startPipelineWorker } from "./startWorker";
import type { PipelineWorkerScope } from "./startWorker";

startPipelineWorker(self as unknown as PipelineWorkerScope);
