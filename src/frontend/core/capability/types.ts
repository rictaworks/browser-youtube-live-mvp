// 能力検出（requirements.md 16.6・30.1・15 章「能力検出」）の型。対応の可否は、ブラウザの名称や版ではなく、起動時の能力検出の結果のみで決める。

/**
 * 能力の識別子（30.1 の表の 7 行の順）。画面の案内（不足している能力の表示。16.6）は、この識別子から、文言カタログの文言を引く。
 *   h264_encode          H.264 の映像エンコード（プロファイルの設定が利用可能）
 *   aac_encode           AAC-LC の音声エンコード（44.1 kHz・2 ch が利用可能）
 *   worker_frame_capture ワーカー上でのフレーム取得と描画（下の FrameCaptureReport の 4 条件がすべて真）
 *   audio_processing     音声の処理周期での信号取得（AudioWorklet）
 *   websocket            WebSocket
 *   screen_capture       画面共有 API（欠ける場合は、画面共有の操作のみを提供しない）
 *   tab_lock             タブ間の排他（欠ける場合は、サーバー側の排他のみで運用する）
 */
export const CAPABILITY_IDS = Object.freeze([
  "h264_encode",
  "aac_encode",
  "worker_frame_capture",
  "audio_processing",
  "websocket",
  "screen_capture",
  "tab_lock",
] as const);
export type CapabilityId = (typeof CAPABILITY_IDS)[number];

/** 開始に必須の能力（30.1 の「欠ける場合」が「配信の開始を提供しない」のもの）。 */
export const REQUIRED_CAPABILITY_IDS = Object.freeze(["h264_encode", "aac_encode", "worker_frame_capture", "audio_processing", "websocket"] as const);
export type RequiredCapabilityId = (typeof REQUIRED_CAPABILITY_IDS)[number];

/** 検出の名前（失敗の記録に使う）。 */
export type CapabilityProbeName = "h264_encode" | "aac_encode" | "readable_stream_transfer" | "worker_probe";

/**
 * 検出が判定できなかった（例外・応答なし・不正な応答）記録。判定できないものは、能力なし（拒否側）として扱う（9.3）。
 * errorName はエラーの名前だけ（メッセージ・スタック・URL を残さない）。
 */
export interface ProbeFailure {
  readonly probe: CapabilityProbeName;
  readonly errorName: string;
}

/**
 * 「ワーカー上でのフレーム取得と描画」を成り立たせる 4 つの条件（30.1・11.4）。
 * Chrome では、MediaStreamTrackProcessor はワーカー内で使えず、MediaStreamTrack も転送できない。メインスレッド（Window）で
 * MediaStreamTrackProcessor を作り、その readable（VideoFrame のストリーム）をワーカーへ転送して、ワーカー上で読む。
 */
export interface FrameCaptureReport {
  /** MediaStreamTrackProcessor が Window にある */
  readonly trackProcessorInWindow: boolean;
  /** ReadableStream をワーカーへ転送できる（structuredClone で検査） */
  readonly readableStreamTransfer: boolean;
  /** ワーカー内に OffscreenCanvas がある（小さなワーカーを実際に起動して検査） */
  readonly offscreenCanvasInWorker: boolean;
  /** ワーカー内に VideoFrame がある（同上） */
  readonly videoFrameInWorker: boolean;
}

/** 検出の結果（readBrowserCapabilities が作り、evaluateCapabilities が評価する）。 */
export interface CapabilityReport {
  /** 使える H.264 のコーデック文字列（Main（avc1.4D401F）を優先し、使えなければ Constrained Baseline（avc1.42E01F）。どちらも使えなければ null） */
  readonly videoCodec: string | null;
  /** AAC-LC（mp4a.40.2・44.1 kHz・2 ch・128 kbps）をエンコードできる */
  readonly aacEncode: boolean;
  readonly frameCapture: FrameCaptureReport;
  /** AudioWorklet がある（音声の処理周期での信号取得） */
  readonly audioWorklet: boolean;
  readonly webSocket: boolean;
  /** 画面共有 API（getDisplayMedia）がある */
  readonly screenCapture: boolean;
  /** タブ間の排他（navigator.locks）がある */
  readonly tabLock: boolean;
  /** 判定できなかった検出の記録（無ければ空） */
  readonly failures: readonly ProbeFailure[];
}

/** 能力の評価（30.1 の表の規則）。 */
export interface CapabilityEvaluation {
  /** 開始に必須の能力がすべてそろう場合のみ真 */
  readonly canStart: boolean;
  /** 画面共有の操作を提供できる。偽なら、画面共有の操作のみを提供しない */
  readonly canShareScreen: boolean;
  /** タブ間の排他が使える。偽なら、サーバー側の排他のみで運用する */
  readonly tabLock: boolean;
  /** 使う H.264 のコーデック文字列（使えなければ null） */
  readonly videoCodec: string | null;
  /** 開始に必須で、不足している能力（16.6 の表示用。30.1 の表の順。無ければ空） */
  readonly missingRequired: readonly RequiredCapabilityId[];
}

/**
 * 注入する環境オブジェクト（window に当たるもの。実際のブラウザでは window をそのまま渡せる）。
 * Domain Core は大域の物（window・navigator・Worker など）を参照せず、検出に使う物を、このオブジェクトから読む。
 * どの項目も、無いことがある（その機能が無い環境）。値は信用せず、検出が実行時に確かめる（関数かどうか・メソッドを持つか）。
 */
export interface BrowserGlobals {
  /** VideoEncoder（静的メソッド isConfigSupported を持つ） */
  readonly VideoEncoder?: unknown;
  /** AudioEncoder（静的メソッド isConfigSupported を持つ） */
  readonly AudioEncoder?: unknown;
  /** MediaStreamTrackProcessor（Window で検査する。ワーカー内では検査しない） */
  readonly MediaStreamTrackProcessor?: unknown;
  /** AudioWorkletNode（AudioWorklet の有無の検査） */
  readonly AudioWorkletNode?: unknown;
  readonly WebSocket?: unknown;
  /** ReadableStream のコンストラクタ（転送可否の検査に使う） */
  readonly ReadableStream?: unknown;
  /** structuredClone（transfer オプションで、ReadableStream を転送できるかの検査に使う） */
  readonly structuredClone?: unknown;
  /** Worker・Blob・URL（小さなワーカーを起動して、ワーカー内の可否を検査するために使う） */
  readonly Worker?: unknown;
  readonly Blob?: unknown;
  readonly URL?: unknown;
  /** navigator（mediaDevices.getDisplayMedia と locks.request の有無だけを読む。userAgent など、ブラウザの名称・版は読まない） */
  readonly navigator?: unknown;
  /** タイマー（ワーカーが応答しないときの期限に使う。注入されたものだけを使う） */
  readonly setTimeout?: unknown;
  readonly clearTimeout?: unknown;
}
