// 転送メッセージの型（ws-protocol.md の 3 章・5 章）。ブラウザ → 中継の 7 種（送る）と、中継 → ブラウザの 7 種（受ける）。
// JSON の本文の型は、契約の項目の名前（snake_case）のまま持つ（ワイヤの形と 1 対 1。変換の取り違えを作らない）。
// 型の名前に、DOM・WebCodecs の大域の名前（VideoFrame など）を使わない（core の走査が、大域の参照として検知する）。

import { LIMITS } from "../contract";
import type { BroadcastState, BrowserEventKind, EndReason, FatalCode, Profile } from "../contract";
import type { TimestampUs } from "./frameLayout";

/** 映像のコーデック文字列：H.264 Main（Level 3.1）、または、Main が使えない環境の Constrained Baseline（11.7）。 */
export type VideoCodec = typeof LIMITS.video.codec_main | typeof LIMITS.video.codec_constrained_baseline;
/** 音声のコーデック文字列：AAC-LC。 */
export type AudioCodec = typeof LIMITS.audio.codec;

/** 状態報告の state。列挙 studio_state の値のうち、配信中の 2 つ。 */
export const REPORT_STATE_VALUES = Object.freeze(["live", "degraded"] as const);
export type ReportState = (typeof REPORT_STATE_VALUES)[number];

/** 終了通知の理由。列挙 end_reason の値のうち、ブラウザが伝えられる 3 つ（ws-protocol.md の 5.7）。 */
export const BROWSER_END_REASON_VALUES = Object.freeze(["user_stop", "user_cancel", "insufficient_bandwidth"] as const satisfies readonly EndReason[]);
export type BrowserEndReason = (typeof BROWSER_END_REASON_VALUES)[number];

/** 状態通知の警告（ws-protocol.md の 5.13）。契約の列挙には無く、文書が定める唯一の値。 */
export const STATUS_WARNING_VALUES = Object.freeze(["youtube_stream_unhealthy"] as const);
export type StatusWarning = (typeof STATUS_WARNING_VALUES)[number];

/**
 * 視聴 URL（status の watch_url。ws-protocol.md の 5.13）として受け取るホスト。https の YouTube だけ（契約の例は https://www.youtube.com/watch?v=...）。
 * 視聴 URL は画面のリンクに使われ得る。中継から届いた値を、そのまま通さない（javascript: や別のドメインは、invalid_body で破棄する）。
 */
export const WATCH_URL_HOSTS = Object.freeze(["www.youtube.com", "youtube.com", "youtu.be"] as const);

// ---------------------------------------------------------------------------
// 本文（JSON）。ブラウザ → 中継
// ---------------------------------------------------------------------------

/** start の video（5.3）。 */
export interface StartVideoConfig {
  readonly codec: VideoCodec;
  readonly width: number;
  readonly height: number;
  readonly framerate: number;
  /** 映像ビットレートの開始値（kbps）。プロファイルの下限から上限の範囲 */
  readonly bitrate_kbps: number;
  /** 復号器設定（AVCDecoderConfigurationRecord）の base64（標準の文字集合・パディングあり） */
  readonly description_b64: string;
}

/** start の audio（5.3）。 */
export interface StartAudioConfig {
  readonly codec: AudioCodec;
  readonly sample_rate: number;
  readonly channels: number;
  readonly bitrate_kbps: number;
  /** 復号器設定（AudioSpecificConfig）の base64 */
  readonly description_b64: string;
}

/** 開始通知（5.3）。 */
export interface StartBody {
  readonly profile: Profile;
  readonly video: StartVideoConfig;
  readonly audio: StartAudioConfig;
}

/** 出来事の detail の値：整数、または符号（^[a-z0-9_]{1,32}$）。自由記述を載せない（5.6）。 */
export type EventDetailValue = number | string;
/** 出来事の detail：キーは ^[a-z][a-z0-9_]{0,31}$、組は最大 4 つ（5.6）。 */
export type EventDetail = { readonly [key: string]: EventDetailValue };

/** 状態報告に載せる、ブラウザ側の出来事（5.6）。 */
export interface ReportEvent {
  readonly kind: BrowserEventKind;
  readonly detail?: EventDetail;
}

/** 状態報告（5.6）。1 秒間隔。 */
export interface ReportBody {
  /** 滞留時間（ミリ秒） */
  readonly backlog_ms: number;
  /** 破棄した映像フレームの累計 */
  readonly dropped_video_frames: number;
  /** 現在の目標ビットレート（映像。kbps） */
  readonly target_kbps: number;
  readonly state: ReportState;
  /** 前回の report 以降に起きた出来事。1 回ずつ（欠落なく、重複なく） */
  readonly events: readonly ReportEvent[];
}

/** 終了通知（5.7）。 */
export interface EndBody {
  readonly reason: BrowserEndReason;
}

// ---------------------------------------------------------------------------
// 本文（JSON）。中継 → ブラウザ
// ---------------------------------------------------------------------------

/** 接続受理（5.8）。 */
export interface AcceptedBody {
  /** 照合したときの配信レコードの状態 */
  readonly state: BroadcastState;
  /** 再開（復帰）なら true */
  readonly resume: boolean;
  /** 再開のとき、確定済みのプロファイル。初回は null */
  readonly profile: Profile | null;
  readonly limits: { readonly time_limit_seconds: number };
}

/** 計測結果（5.9）。 */
export interface ProbeResultBody {
  readonly throughput_kbps: number;
}

/** 受領応答（5.10）。中継が受領済みの、映像・音声の最新のメディア時刻（マイクロ秒）。まだ 1 つも受けていない種別は 0。 */
export interface AckBody {
  readonly video_us: number;
  readonly audio_us: number;
}

/** 抑制指示（5.12）。 */
export interface ThrottleBody {
  readonly target_kbps: number;
}

/** 状態通知（5.13）。毎回、状態の全体（スナップショット）。 */
export interface StatusBody {
  readonly state: BroadcastState;
  readonly watch_url: string | null;
  readonly warning: StatusWarning | null;
  readonly time_limit_notice_seconds: number | null;
  readonly end_reason: EndReason | null;
}

/** 致命通知（5.14）。 */
export interface FatalBody {
  readonly code: FatalCode;
}

// ---------------------------------------------------------------------------
// メッセージ（フレーム）。ブラウザが送る 7 種
// ---------------------------------------------------------------------------

/** 接続通知：接続チケット（JSON ではなく、UTF-8 の文字列そのもの）。 */
export interface HelloMessage {
  readonly type: "hello";
  readonly ticket: string;
}

/** 計測データ：任意のバイト列（1 メッセージ 32 KB 程度）。 */
export interface ProbeMessage {
  readonly type: "probe";
  readonly payload: Uint8Array;
}

/** 開始通知。 */
export interface StartMessage {
  readonly type: "start";
  readonly body: StartBody;
}

/** 映像：AVCC 形式の符号化データ。keyframe は属性の bit0。 */
export interface VideoMessage {
  readonly type: "video";
  readonly timestampUs: TimestampUs;
  readonly keyframe: boolean;
  readonly payload: Uint8Array;
}

/** 音声：AAC の生フレーム（ADTS なし）。 */
export interface AudioMessage {
  readonly type: "audio";
  readonly timestampUs: TimestampUs;
  readonly payload: Uint8Array;
}

/** 状態報告。 */
export interface ReportMessage {
  readonly type: "report";
  readonly body: ReportBody;
}

/** 終了通知。 */
export interface EndMessage {
  readonly type: "end";
  readonly body: EndBody;
}

/** ブラウザ → 中継の 7 種。 */
export type OutboundMessage = HelloMessage | ProbeMessage | StartMessage | VideoMessage | AudioMessage | ReportMessage | EndMessage;

// ---------------------------------------------------------------------------
// メッセージ（フレーム）。ブラウザが受ける 7 種
// ---------------------------------------------------------------------------

export interface AcceptedMessage {
  readonly type: "accepted";
  readonly body: AcceptedBody;
}

export interface ProbeResultMessage {
  readonly type: "probe_result";
  readonly body: ProbeResultBody;
}

export interface AckMessage {
  readonly type: "ack";
  readonly body: AckBody;
}

/** キーフレーム要求：本文は空（本文長 0）。 */
export interface KeyframeRequestMessage {
  readonly type: "keyframe_request";
}

export interface ThrottleMessage {
  readonly type: "throttle";
  readonly body: ThrottleBody;
}

export interface StatusMessage {
  readonly type: "status";
  readonly body: StatusBody;
}

export interface FatalMessage {
  readonly type: "fatal";
  readonly body: FatalBody;
}

/** 中継 → ブラウザの 7 種。 */
export type InboundMessage = AcceptedMessage | ProbeResultMessage | AckMessage | KeyframeRequestMessage | ThrottleMessage | StatusMessage | FatalMessage;
