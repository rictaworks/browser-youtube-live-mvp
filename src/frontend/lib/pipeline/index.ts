// 配信パイプライン（映像の合成と H.264／AAC のエンコード。requirements.md 11.3〜11.7・12・16.2。issue #27）の公開 API。
// 合成とエンコードは、ワーカー（workers/pipeline）の上で行い、画面の描画周期に依存しない。ここは、メインスレッド側のクライアントと、共通の型。
// 配信の制御（#28）・画面（#29）は、ここから import する。テストの道具（test-support.ts）は、公開しない。
//
// 使い方（スタジオ画面の部品の中で。サーバー側の描画では作らない）
//   import { createPipelineWorker } from "@/lib/pipeline/defaultWorker";   // import.meta を含むので、この入り口には含めない
//   const client = new PipelineClient({ createWorker: createPipelineWorker, onChunk, onFault, onLayoutChanged, onDecoderConfigChanged });
//   await client.start();
//   client.attachPreview(canvasElement);                  // プレビュー（transferControlToOffscreen。同じ <canvas> は 1 回だけ）
//   manager.subscribe((change) => applySourceChange(client, change));   // SourceManager（#26）の変化を、映像ソースの追加・解除へ。戻り値の layout は SourceChange.layout
//                                                         // （トラックを止めるのは、マネージャ。パイプラインは止めない）
//   // 配信の開始（利用者のクリックの中で）
//   mixer.subscribe(client.audioListener);                // AudioContext の停止・再開を、メディアクロックへ
//   await mixer.start({ sink: client.openAudioSink() });  // 音声のブロックが、ワーカーへ直接届く
//   const { video, audio } = await client.configure({ profile, videoCodec, videoBitrateKbps });   // 復号器設定 -> 開始通知（start）
//   client.beginDelivery();                               // 送出の開始の通知（status の confirming）を受けたあと。復帰では、キーフレーム要求を受けたあと
//   // onChunk で受けた EncodedChunk を、SendQueue へ積み、FrameCodec で送る（#25・#28）
//   client.setBitrate(kbps) / client.requestKeyframe() / client.pauseDelivery()   // 適応制御・再接続
//   await client.endSession(); client.terminate();

export { PipelineClient } from "./PipelineClient";
export type { ConfigSnapshot, ConfigureOptions, ConfiguredResult, PipelineClientOptions, PipelineWorkerLike, PreviewCanvasSource, TimerApi } from "./PipelineClient";
export { applySourceChange } from "./sourceBridge";
export type { BridgeOutcome, BridgeResult, VideoSourceTarget } from "./sourceBridge";
export { createTrackReadable } from "./trackReadable";
export type { TrackProcessorConstructor, TrackReadable } from "./trackReadable";
export { createDecoderConfigChunk, createEncodedChunk, isDecoderConfigChunk, isEncodedChunk } from "./chunks";
export type { DecoderConfigChunk, EncodedChunk, EncodedChunkInput, MediaKind } from "./chunks";
export { PIPELINE_ERROR_CODES, PipelineError, errorFromFault, faultOf, isPipelineErrorCode } from "./errors";
export type { PipelineErrorCode, PipelineFault } from "./errors";
export { buildAudioEncoderConfig, buildVideoEncoderConfig } from "./encoderConfig";
export type { AudioEncoderSettings, VideoEncoderSettings } from "./encoderConfig";
export { planFrame } from "./drawPlan";
export type { DrawCommand, FramePlanInput, SourceSize, SourceSlot } from "./drawPlan";
export type { PipelineStats } from "@/workers/pipeline/messages";
export type { VideoSourceKind } from "@/workers/pipeline/FrameStore";
