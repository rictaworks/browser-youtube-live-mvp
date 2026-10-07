// ソースの取得・解除・喪失の監視（requirements.md 11.2・13.1・16.2・25.5。issue #26）の公開 API。
// 画面（#29）・合成（#27）・配信の制御（#28）は、ここから import する。テストの道具（test-support.ts）は、公開しない。
//
// 使い方（クライアントの部品の中で。サーバー側の描画では作らない。navigator.mediaDevices が無い文脈では、構築が TypeError になるので、能力検出で先に確かめる）
//   const manager = new SourceManager({ mediaDevices: navigator.mediaDevices });
//   void manager.devices.refresh();                      // デバイスの一覧（ラベルは、権限の取得後にのみ得られる）
//   button.onclick = () => { void manager.attach("screen"); };   // クリックのハンドラから、await を挟まずに呼ぶ（共有音声も、同じ取得で得る）
//   const unsubscribe = manager.subscribe((change) => { /* change.layout で合成を切り替える（トラックの終了も、ここへ来る） */ });
//   manager.dispose();                                   // 画面を離れるとき（取得したトラックを止める）
// マイク・共有音声を混合へつなぐのは、lib/audio の bindSourcesToMixer。
// SourceHandle の label・deviceId は、画面の表示のため。ログ・測定イベント・中継へ送らない（requirements.md 11.2）。

export { SourceManager } from "./SourceManager";
export type { SourceManagerOptions } from "./SourceManager";
export { DeviceCatalog } from "./DeviceCatalog";
export type { DeviceCatalogOptions, DeviceInfo, DeviceList, DeviceListListener } from "./DeviceCatalog";
export { SOURCE_ERROR_CODES, SourceError, isSourceError } from "./errors";
export type { SourceErrorCode } from "./errors";
export { ATTACHABLE_SOURCE_KINDS, MANAGED_SOURCE_KINDS, SOURCE_REASON_VALUES, isManagedSourceKind } from "./types";
export type { AttachableSourceKind, ManagedSourceKind, MediaDevicesLike, SourceChange, SourceChangeListener, SourceHandle, SourceHandles, SourceReason } from "./types";
export { NO_DIAGNOSTICS, createConsoleDiagnosticSink } from "./diagnostics";
export type { DiagnosticFields, DiagnosticSink } from "./diagnostics";
