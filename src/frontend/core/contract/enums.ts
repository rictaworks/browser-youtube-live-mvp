// 契約の列挙（src/contracts/enums.json の複製）。符号だけを持ち、画面に出す文言を含まない。
// 実行時に src/contracts を読まない（デプロイ単位が層ごとのため）。JSON との一致は contract.test.ts が、両方向に保証する。
// 列挙ごとに、全値の凍結した配列 <名前>_VALUES（契約の順）・ユニオン型・型ガードを持つ。

import { deepFreeze } from "./deep-freeze";

function isOneOf<T extends string>(values: readonly T[], value: unknown): value is T {
  return typeof value === "string" && (values as readonly string[]).includes(value);
}

/** 列挙 source_kind（requirements.md 20.4（ソース種別）・4 章）。契約の順。 */
export const SOURCE_KIND_VALUES = Object.freeze([
  "camera",
  "screen",
  "microphone",
  "shared_audio",
  "slate",
] as const);
export type SourceKind = (typeof SOURCE_KIND_VALUES)[number];
export function isSourceKind(value: unknown): value is SourceKind {
  return isOneOf(SOURCE_KIND_VALUES, value);
}

/** 列挙 layout（requirements.md 20.4（レイアウト）・11.3）。契約の順。 */
export const LAYOUT_VALUES = Object.freeze([
  "screen_with_wipe",
  "screen_only",
  "camera_only",
  "slate",
] as const);
export type Layout = (typeof LAYOUT_VALUES)[number];
export function isLayout(value: unknown): value is Layout {
  return isOneOf(LAYOUT_VALUES, value);
}

/** 列挙 profile（requirements.md 20.4（エンコードプロファイル）・11.7）。契約の順。 */
export const PROFILE_VALUES = Object.freeze(["720p", "480p"] as const);
export type Profile = (typeof PROFILE_VALUES)[number];
export function isProfile(value: unknown): value is Profile {
  return isOneOf(PROFILE_VALUES, value);
}

/** 列挙 broadcast_state（requirements.md 20.4（配信レコードの状態）・25.1）。契約の順。 */
export const BROADCAST_STATE_VALUES = Object.freeze([
  "reserved",
  "awaiting_media",
  "confirming",
  "live",
  "interrupted",
  "ended",
] as const);
export type BroadcastState = (typeof BROADCAST_STATE_VALUES)[number];
export function isBroadcastState(value: unknown): value is BroadcastState {
  return isOneOf(BROADCAST_STATE_VALUES, value);
}

/** 列挙 settlement_state（requirements.md 20.4（清算状態）・25.2）。契約の順。 */
export const SETTLEMENT_STATE_VALUES = Object.freeze(["none", "pending", "settled", "abandoned"] as const);
export type SettlementState = (typeof SETTLEMENT_STATE_VALUES)[number];
export function isSettlementState(value: unknown): value is SettlementState {
  return isOneOf(SETTLEMENT_STATE_VALUES, value);
}

/** 列挙 end_reason（requirements.md 20.4（終了理由））。契約の順。 */
export const END_REASON_VALUES = Object.freeze([
  "user_stop",
  "time_limit",
  "connection_lost",
  "youtube_ended",
  "authorization_revoked",
  "admin_stop",
  "start_timeout",
  "confirm_timeout",
  "prepare_failed",
  "prior_unsettled",
  "insufficient_bandwidth",
  "user_cancel",
  "relay_disconnect",
] as const);
export type EndReason = (typeof END_REASON_VALUES)[number];
export function isEndReason(value: unknown): value is EndReason {
  return isOneOf(END_REASON_VALUES, value);
}

/** 列挙 rejection_reason（requirements.md 20.4（開始の拒否理由）・9.2。配列の順が 9.2 の順 0〜13）。契約の順。 */
export const REJECTION_REASON_VALUES = Object.freeze([
  "invalid_input",
  "not_logged_in",
  "rate_limited",
  "bot_check_failed",
  "broadcast_in_progress",
  "youtube_not_connected",
  "authorization_revoked",
  "live_not_enabled",
  "allowance_consumed",
  "attempts_exhausted",
  "intake_paused",
  "transfer_budget_exceeded",
  "capacity_full",
  "quota_insufficient",
] as const);
export type RejectionReason = (typeof REJECTION_REASON_VALUES)[number];
export function isRejectionReason(value: unknown): value is RejectionReason {
  return isOneOf(REJECTION_REASON_VALUES, value);
}

/** 列挙 youtube_connection_state（requirements.md 20.4（YouTube 接続状態）・25.4）。契約の順。 */
export const YOUTUBE_CONNECTION_STATE_VALUES = Object.freeze([
  "not_connected",
  "connected",
  "live_not_enabled",
  "revoked",
] as const);
export type YoutubeConnectionState = (typeof YOUTUBE_CONNECTION_STATE_VALUES)[number];
export function isYoutubeConnectionState(value: unknown): value is YoutubeConnectionState {
  return isOneOf(YOUTUBE_CONNECTION_STATE_VALUES, value);
}

/** 列挙 studio_state（requirements.md 20.4（スタジオの状態）・25.3）。契約の順。 */
export const STUDIO_STATE_VALUES = Object.freeze([
  "idle",
  "requesting",
  "connecting",
  "probing",
  "starting",
  "live",
  "degraded",
  "reconnecting",
  "stopping",
  "ended",
] as const);
export type StudioState = (typeof STUDIO_STATE_VALUES)[number];
export function isStudioState(value: unknown): value is StudioState {
  return isOneOf(STUDIO_STATE_VALUES, value);
}

/** 列挙 source_state（requirements.md 20.4（ソースの状態）・25.5）。契約の順。 */
export const SOURCE_STATE_VALUES = Object.freeze([
  "detached",
  "requesting",
  "active",
  "denied",
  "lost",
] as const);
export type SourceState = (typeof SOURCE_STATE_VALUES)[number];
export function isSourceState(value: unknown): value is SourceState {
  return isOneOf(SOURCE_STATE_VALUES, value);
}

/** 列挙 ws_message_type（requirements.md 20.4（転送メッセージ種別）・11.9。前の 7 種がブラウザ → 中継、後の 7 種が中継 → ブラウザ）。契約の順。 */
export const WS_MESSAGE_TYPE_VALUES = Object.freeze([
  "hello",
  "probe",
  "start",
  "video",
  "audio",
  "report",
  "end",
  "accepted",
  "probe_result",
  "ack",
  "keyframe_request",
  "throttle",
  "status",
  "fatal",
] as const);
export type WsMessageType = (typeof WS_MESSAGE_TYPE_VALUES)[number];
export function isWsMessageType(value: unknown): value is WsMessageType {
  return isOneOf(WS_MESSAGE_TYPE_VALUES, value);
}

/** 列挙 internal_call（requirements.md 20.4（内部通信の呼び出し）・11.9）。契約の順。 */
export const INTERNAL_CALL_VALUES = Object.freeze(["verify", "provision", "heartbeat", "event"] as const);
export type InternalCall = (typeof INTERNAL_CALL_VALUES)[number];
export function isInternalCall(value: unknown): value is InternalCall {
  return isOneOf(INTERNAL_CALL_VALUES, value);
}

/** 列挙 broadcast_event_type（requirements.md 20.4（配信の出来事の種別））。契約の順。 */
export const BROADCAST_EVENT_TYPE_VALUES = Object.freeze([
  "accepted",
  "verified",
  "probe_done",
  "provision_started",
  "provision_done",
  "publish_started",
  "live_confirmed",
  "source_added",
  "source_lost",
  "fallback_switched",
  "bitrate_down",
  "bitrate_up",
  "video_dropped",
  "degraded_started",
  "degraded_cleared",
  "interrupted",
  "resumed",
  "throttle_directed",
  "keyframe_requested",
  "youtube_warning",
  "time_limit_notice",
  "ended",
  "settlement_succeeded",
  "settlement_failed",
] as const);
export type BroadcastEventType = (typeof BROADCAST_EVENT_TYPE_VALUES)[number];
export function isBroadcastEventType(value: unknown): value is BroadcastEventType {
  return isOneOf(BROADCAST_EVENT_TYPE_VALUES, value);
}

/** 列挙 usage_event_type（requirements.md 20.4（測定イベントの種別）・18 章）。契約の順。 */
export const USAGE_EVENT_TYPE_VALUES = Object.freeze([
  "login_started",
  "login_completed",
  "connect_started",
  "connect_completed",
  "connect_failed",
  "capability_detected",
  "source_granted",
  "source_denied",
  "start_requested",
  "start_rejected",
  "line_measured",
  "prepared",
  "live_confirmed",
  "degraded",
  "reconnect_started",
  "reconnect_succeeded",
  "broadcast_ended",
  "watch_url_copied",
  "disconnected",
  "account_deleted",
] as const);
export type UsageEventType = (typeof USAGE_EVENT_TYPE_VALUES)[number];
export function isUsageEventType(value: unknown): value is UsageEventType {
  return isOneOf(USAGE_EVENT_TYPE_VALUES, value);
}

/** 列挙 setting_key（requirements.md 20.4（制限値・設定）・8 章）。契約の順。 */
export const SETTING_KEY_VALUES = Object.freeze([
  "daily_allowance",
  "attempt_limit",
  "concurrent_limit",
  "time_limit_minutes",
  "intake_rate_per_hour",
  "monthly_transfer_budget_gb",
  "daily_quota_units",
  "bot_score_threshold",
  "intake_paused",
] as const);
export type SettingKey = (typeof SETTING_KEY_VALUES)[number];
export function isSettingKey(value: unknown): value is SettingKey {
  return isOneOf(SETTING_KEY_VALUES, value);
}

/** 列挙 adaptive_condition（requirements.md 20.4（適応制御の条件）・12 章。配列の順が 12 章の表の 7 行の順）。契約の順。 */
export const ADAPTIVE_CONDITION_VALUES = Object.freeze([
  "backlog_high_twice",
  "backlog_low_no_drop",
  "backlog_critical",
  "video_ack_stalled",
  "backlog_severe_sustained",
  "degraded_enter",
  "degraded_exit",
] as const);
export type AdaptiveCondition = (typeof ADAPTIVE_CONDITION_VALUES)[number];
export function isAdaptiveCondition(value: unknown): value is AdaptiveCondition {
  return isOneOf(ADAPTIVE_CONDITION_VALUES, value);
}

/** 列挙 color_role（requirements.md 20.4（配色の役割）・17.2）。契約の順。 */
export const COLOR_ROLE_VALUES = Object.freeze([
  "base",
  "surface",
  "surface_raised",
  "divider",
  "control_border",
  "text_primary",
  "text_secondary",
  "accent",
  "live",
  "warning",
  "success",
  "focus",
] as const);
export type ColorRole = (typeof COLOR_ROLE_VALUES)[number];
export function isColorRole(value: unknown): value is ColorRole {
  return isOneOf(COLOR_ROLE_VALUES, value);
}

/** 配色の役割ごとの 16 進値（17.2）。on_hex は、その役割の上に載せる文字の色。 */
export const COLOR_ROLE_ATTRIBUTES = deepFreeze({
  base: {
    hex: "#0F1115",
  },
  surface: {
    hex: "#171A21",
  },
  surface_raised: {
    hex: "#1F2430",
  },
  divider: {
    hex: "#2B3140",
  },
  control_border: {
    hex: "#6B7488",
  },
  text_primary: {
    hex: "#F2F4F8",
  },
  text_secondary: {
    hex: "#A9B1C1",
  },
  accent: {
    hex: "#3FB6A8",
    on_hex: "#06201D",
  },
  live: {
    hex: "#CE2C31",
    on_hex: "#FFFFFF",
  },
  warning: {
    hex: "#F5A524",
  },
  success: {
    hex: "#46A758",
  },
  focus: {
    hex: "#8AB4F8",
  },
} as const);

/** 列挙 fatal_code（契約独自の列挙（#3）。ws-protocol.md の致命通知）。契約の順。 */
export const FATAL_CODE_VALUES = Object.freeze([
  "message_too_large",
  "bitrate_exceeded",
  "hello_timeout",
  "invalid_ticket",
  "stale_epoch",
  "broadcast_ended",
  "protocol_violation",
  "heartbeat_lost",
  "publish_failed",
  "internal_error",
] as const);
export type FatalCode = (typeof FATAL_CODE_VALUES)[number];
export function isFatalCode(value: unknown): value is FatalCode {
  return isOneOf(FATAL_CODE_VALUES, value);
}

/** 列挙 relay_event_kind（契約独自の列挙（#3）。internal-api.md の事象の種類）。契約の順。 */
export const RELAY_EVENT_KIND_VALUES = Object.freeze([
  "publish_started",
  "interrupted",
  "resumed",
  "publish_failed",
  "relay_disconnected",
  "session_ended",
] as const);
export type RelayEventKind = (typeof RELAY_EVENT_KIND_VALUES)[number];
export function isRelayEventKind(value: unknown): value is RelayEventKind {
  return isOneOf(RELAY_EVENT_KIND_VALUES, value);
}

/** 列挙 interrupt_cause（契約独自の列挙（#3）。internal-api.md の事象（中断）の原因）。契約の順。 */
export const INTERRUPT_CAUSE_VALUES = Object.freeze([
  "browser_disconnected",
  "media_stalled",
  "rtmps_disconnected",
  "buffer_overflow",
] as const);
export type InterruptCause = (typeof INTERRUPT_CAUSE_VALUES)[number];
export function isInterruptCause(value: unknown): value is InterruptCause {
  return isOneOf(INTERRUPT_CAUSE_VALUES, value);
}

/** 列挙 browser_event_kind（契約独自の列挙（#3）。状態報告に載せる、ブラウザ側の出来事（配信の出来事の種別の部分集合））。契約の順。 */
export const BROWSER_EVENT_KIND_VALUES = Object.freeze([
  "source_added",
  "source_lost",
  "fallback_switched",
  "bitrate_down",
  "bitrate_up",
  "video_dropped",
  "degraded_started",
  "degraded_cleared",
] as const);
export type BrowserEventKind = (typeof BROWSER_EVENT_KIND_VALUES)[number];
export function isBrowserEventKind(value: unknown): value is BrowserEventKind {
  return isOneOf(BROWSER_EVENT_KIND_VALUES, value);
}

/** 列挙 connect_result（契約独自の列挙（#3）。YouTube 接続の結果（7.2））。契約の順。 */
export const CONNECT_RESULT_VALUES = Object.freeze([
  "connected",
  "live_not_enabled",
  "scope_denied",
  "no_refresh_token",
  "no_channel",
  "unverifiable",
] as const);
export type ConnectResult = (typeof CONNECT_RESULT_VALUES)[number];
export function isConnectResult(value: unknown): value is ConnectResult {
  return isOneOf(CONNECT_RESULT_VALUES, value);
}

/** 列挙 login_error（契約独自の列挙（#3）。ログインの失敗の種類（7.1））。契約の順。 */
export const LOGIN_ERROR_VALUES = Object.freeze(["registration_held", "oauth_failed"] as const);
export type LoginError = (typeof LOGIN_ERROR_VALUES)[number];
export function isLoginError(value: unknown): value is LoginError {
  return isOneOf(LOGIN_ERROR_VALUES, value);
}

/** 列挙 resolution（契約独自の列挙（#3）。拒否の「再試行で解消するか」の区分（9.2））。契約の順。 */
export const RESOLUTION_VALUES = Object.freeze([
  "fix_input",
  "log_in",
  "wait",
  "stop_first",
  "connect",
  "reconnect",
  "enable_live",
  "next_usage_day",
  "after_release",
  "next_month",
  "next_quota_day",
] as const);
export type Resolution = (typeof RESOLUTION_VALUES)[number];
export function isResolution(value: unknown): value is Resolution {
  return isOneOf(RESOLUTION_VALUES, value);
}
