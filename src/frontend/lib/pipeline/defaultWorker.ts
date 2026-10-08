// 既定のワーカーの作り方（issue #27）。配信パイプラインのワーカー（workers/pipeline/pipeline.worker.ts）を、モジュールワーカーとして起動する。
//
// Next.js のバンドル: new Worker(new URL("…", import.meta.url), { type: "module" }) の式を、静的に解析して、ワーカーの入り口と
// そのモジュールの塊を、別に出力する（Turbopack。公式の文書: node_modules/next/dist/docs の 08-turbopack.md の「Magic Comments」の節が、
// new Worker() の式を扱うことを示し、turbopackWorkerAssetPrefix が「Web Worker の URL（入り口とモジュールの塊）」を扱う）。
// そのため、式の形を変えない（URL は、リテラルの相対パスで、new Worker の引数の中に書く）。
//
// このファイルは import.meta を含むので、Jest が読み込む部品（index.ts など）から import しない。
// 画面（#29）・配信の制御（#28）が、直接 import する:  import { createPipelineWorker } from "@/lib/pipeline/defaultWorker";

import type { PipelineWorkerLike } from "./PipelineClient";

export function createPipelineWorker(): PipelineWorkerLike {
  return new Worker(new URL("../../workers/pipeline/pipeline.worker.ts", import.meta.url), { type: "module" });
}
