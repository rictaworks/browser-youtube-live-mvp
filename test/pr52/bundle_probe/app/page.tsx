"use client";
// 配信パイプラインのワーカーが、Next.js（Turbopack）のバンドルで動くことの確認用ページ（issue #27）。test/pr52/probe_worker_bundle.cjs が、
// 作業用のディレクトリへ写して使う。製品の画面ではない（src/frontend には置かない）。
//   - 製品の既定のワーカーの作り方（createPipelineWorker: new Worker(new URL(...), { type: "module" })）で、ワーカーを起動する
//   - ready を待ち、get_stats の応答を window.__probeStats に残し、状態を data-testid="status" へ出す
import { useEffect, useState } from "react";
import { PipelineClient } from "@/lib/pipeline";
import { createPipelineWorker } from "@/lib/pipeline/defaultWorker";

export default function Page() {
  const [status, setStatus] = useState("init");
  useEffect(() => {
    // React の StrictMode（開発）は、効果を 2 回実行する。前の実行の結果は、無視する
    let active = true;
    const client = new PipelineClient({
      createWorker: createPipelineWorker,
      onChunk: () => undefined,
      onFault: (fault) => active && setStatus(`fault:${fault.code}`),
    });
    client
      .start()
      .then(async () => {
        const stats = await client.getStats();
        if (active) {
          (window as unknown as { __probeStats: unknown }).__probeStats = stats;
          setStatus("ready");
        }
      })
      .catch((error: unknown) => active && setStatus(`failed:${String((error as { code?: string }).code ?? error)}`));
    return () => {
      active = false;
      client.terminate();
    };
  }, []);
  return <main data-testid="status">{status}</main>;
}
