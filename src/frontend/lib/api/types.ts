import type { BroadcastState, EndReason, Profile, RejectionReason, Resolution, YoutubeConnectionState } from "@/core/contract";

// API の応答・要求の型。契約 src/contracts/http-api.md の 2 章（共通の型）・3 章（エンドポイント）・4 章（受付の拒否）と一致させる。
// キーは契約と同じ snake_case。時刻は ISO 8601（JST、+09:00）の文字列。列挙は core/contract の型。

/** 配信の表示用の情報（契約 2.1）。タイトルを含まない */
export interface BroadcastView {
  readonly id: string;
  readonly state: BroadcastState;
  /** state が ended のときだけ */
  readonly end_reason: EndReason | null;
  /** 準備の完了後に確定。それまでは null */
  readonly profile: Profile | null;
  readonly accepted_at: string;
  readonly live_at: string | null;
  readonly ended_at: string | null;
  readonly time_limit_ends_at: string | null;
  readonly watch_url: string | null;
  readonly resumable: boolean;
  readonly duration_seconds: number | null;
  readonly next_available_at: string | null;
}

/** 利用状況（契約 2.2） */
export interface UsageView {
  readonly usage_date: string;
  readonly allowance_total: number;
  readonly allowance_remaining: number;
  readonly attempts_remaining: number;
  readonly next_available_at: string | null;
  readonly monthly_intake_closed: boolean;
  readonly intake_paused: boolean;
}

/** YouTube の接続（契約 2.3） */
export interface YoutubeView {
  readonly state: YoutubeConnectionState;
  /** GET /api/state が with_channel=1 のときだけ。取得できなければ null */
  readonly channel_title: string | null;
  /** 次に再確認できる時刻。今すぐ再確認できるなら null */
  readonly can_recheck_at: string | null;
}

export interface UnauthenticatedState {
  readonly authenticated: false;
  readonly csrf_token: null;
}

export interface AuthenticatedState {
  readonly authenticated: true;
  /** 状態を変える要求の X-CSRF-Token。メモリにだけ持つ */
  readonly csrf_token: string;
  readonly usage: UsageView;
  readonly youtube: YoutubeView;
  /** 終了していない配信だけ。無ければ null */
  readonly broadcast: BroadcastView | null;
}

/** GET /api/state の応答 */
export type StateResponse = UnauthenticatedState | AuthenticatedState;

/** ログイン・YouTube 接続の開始の応答（Google の認可 URL） */
export interface AuthorizationStart {
  readonly authorization_url: string;
}

export type PrivacyStatus = "public" | "unlisted" | "private";

/** POST /api/broadcasts の要求（契約 3 章） */
export interface StartRequest {
  /** 1〜100 文字（コードポイント）で、山括弧を含まない */
  readonly title: string;
  readonly privacy_status: PrivacyStatus;
  /** 子ども向けの申告。既定値を持たず、利用者の明示的な選択が要る */
  readonly made_for_kids: boolean;
  readonly recaptcha_token: string;
}

export interface ProfileLimits {
  readonly width: number;
  readonly height: number;
  readonly framerate: number;
  readonly video_bitrate_min_kbps: number;
  readonly video_bitrate_initial_kbps: number;
  readonly video_bitrate_max_kbps: number;
  readonly line_threshold_kbps: number;
}

/** 適用される上限（受理の応答） */
export interface StartLimits {
  readonly time_limit_seconds: number;
  readonly profiles: Readonly<Record<Profile, ProfileLimits>>;
  readonly audio_kbps: number;
}

/** 配信の受理（201） */
export interface StartAccepted {
  readonly broadcast: BroadcastView;
  /** 接続チケット。60 秒で失効する、1 回限りの値。ログ・画面へ出さない */
  readonly ticket: string;
  /** 中継の接続先（ws:// または wss://） */
  readonly relay_url: string;
  readonly limits: StartLimits;
}

/** 復帰のための、新しい接続チケット */
export interface TicketIssued {
  readonly ticket: string;
  readonly relay_url: string;
}

/** ライブ確定前の取り消しの理由（契約: 列挙 end_reason のうち、2 つ） */
export type CancelReason = "user_cancel" | "insufficient_bandwidth";

/** ブラウザが送れる測定イベントの種別（契約 3 章: POST /api/usage-events） */
export type BrowserUsageEventType = "capability_detected" | "source_granted" | "source_denied" | "line_measured" | "watch_url_copied";

export interface BrowserClass {
  readonly family: "chromium" | "firefox" | "webkit" | "other";
  readonly supported: boolean;
}

/** 測定イベント（契約 3 章）。ユーザーエージェントの文字列・氏名・チャンネル名・タイトルを含めない */
export interface UsageEventRequest {
  readonly event_type: BrowserUsageEventType;
  /** 符号（^[a-z0-9_]{1,32}$） */
  readonly reason_code?: string;
  /** 0 以上の整数 */
  readonly value?: number;
  readonly browser_class?: BrowserClass;
}

/** 受付の拒否（契約 4 章）の本文 */
export interface RejectedBody {
  readonly reason: RejectionReason;
  readonly resolution: Resolution;
  readonly retry_at: string | null;
  /** invalid_input のときだけ */
  readonly fields: readonly string[] | null;
}
