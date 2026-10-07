import {
  isBroadcastState,
  isEndReason,
  isProfile,
  isRejectionReason,
  isResolution,
  isYoutubeConnectionState,
} from "@/core/contract";
import { isApiErrorCode, type ApiErrorCode } from "./error-codes";
import type {
  AuthenticatedState,
  AuthorizationStart,
  BroadcastView,
  ProfileLimits,
  RejectedBody,
  StartAccepted,
  StartLimits,
  StateResponse,
  TicketIssued,
  UsageView,
  YoutubeView,
} from "./types";
import {
  childPath,
  expectBoolean,
  expectEnum,
  expectNonEmptyString,
  expectNonNegativeInteger,
  expectNullableEnum,
  expectNullableNonNegativeInteger,
  expectNullableString,
  expectObject,
  expectStringArray,
  expectWebSocketUrl,
  ShapeError,
} from "./validate";

// 応答の検証（契約の形・列挙に合わないものは、ShapeError。成功にしない）。位置は、ドット区切りの項目名（根は、空文字）。

function parseUsageView(value: unknown, path: string): UsageView {
  const usage = expectObject(value, path);
  return {
    usage_date: expectNonEmptyString(usage.usage_date, childPath(path, "usage_date")),
    allowance_total: expectNonNegativeInteger(usage.allowance_total, childPath(path, "allowance_total")),
    allowance_remaining: expectNonNegativeInteger(usage.allowance_remaining, childPath(path, "allowance_remaining")),
    attempts_remaining: expectNonNegativeInteger(usage.attempts_remaining, childPath(path, "attempts_remaining")),
    next_available_at: expectNullableString(usage.next_available_at, childPath(path, "next_available_at")),
    monthly_intake_closed: expectBoolean(usage.monthly_intake_closed, childPath(path, "monthly_intake_closed")),
    intake_paused: expectBoolean(usage.intake_paused, childPath(path, "intake_paused")),
  };
}

function parseYoutubeView(value: unknown, path: string): YoutubeView {
  const youtube = expectObject(value, path);
  return {
    state: expectEnum(youtube.state, isYoutubeConnectionState, childPath(path, "state")),
    channel_title: expectNullableString(youtube.channel_title, childPath(path, "channel_title")),
    can_recheck_at: expectNullableString(youtube.can_recheck_at, childPath(path, "can_recheck_at")),
  };
}

export function parseBroadcastView(value: unknown, path: string): BroadcastView {
  const broadcast = expectObject(value, path);
  return {
    id: expectNonEmptyString(broadcast.id, childPath(path, "id")),
    state: expectEnum(broadcast.state, isBroadcastState, childPath(path, "state")),
    end_reason: expectNullableEnum(broadcast.end_reason, isEndReason, childPath(path, "end_reason")),
    profile: expectNullableEnum(broadcast.profile, isProfile, childPath(path, "profile")),
    accepted_at: expectNonEmptyString(broadcast.accepted_at, childPath(path, "accepted_at")),
    live_at: expectNullableString(broadcast.live_at, childPath(path, "live_at")),
    ended_at: expectNullableString(broadcast.ended_at, childPath(path, "ended_at")),
    time_limit_ends_at: expectNullableString(broadcast.time_limit_ends_at, childPath(path, "time_limit_ends_at")),
    watch_url: expectNullableString(broadcast.watch_url, childPath(path, "watch_url")),
    resumable: expectBoolean(broadcast.resumable, childPath(path, "resumable")),
    duration_seconds: expectNullableNonNegativeInteger(broadcast.duration_seconds, childPath(path, "duration_seconds")),
    next_available_at: expectNullableString(broadcast.next_available_at, childPath(path, "next_available_at")),
  };
}

/** GET /api/state の応答。未ログインは csrf_token が null、ログイン済みは、トークンと利用状況・YouTube・進行中の配信を持つ */
export function parseStateResponse(value: unknown): StateResponse {
  const root = expectObject(value, "");
  if (!expectBoolean(root.authenticated, "authenticated")) {
    if (root.csrf_token !== null) {
      throw new ShapeError("csrf_token");
    }
    return { authenticated: false, csrf_token: null };
  }
  const state: AuthenticatedState = {
    authenticated: true,
    csrf_token: expectNonEmptyString(root.csrf_token, "csrf_token"),
    usage: parseUsageView(root.usage, "usage"),
    youtube: parseYoutubeView(root.youtube, "youtube"),
    broadcast: root.broadcast === null ? null : parseBroadcastView(root.broadcast, "broadcast"),
  };
  return state;
}

export function parseAuthorizationStart(value: unknown): AuthorizationStart {
  const root = expectObject(value, "");
  return { authorization_url: expectNonEmptyString(root.authorization_url, "authorization_url") };
}

/** {"youtube":{...}}（再確認・接続解除の応答）から、youtube を取り出す */
export function parseYoutubeEnvelope(value: unknown): YoutubeView {
  const root = expectObject(value, "");
  return parseYoutubeView(root.youtube, "youtube");
}

function parseProfileLimits(value: unknown, path: string): ProfileLimits {
  const limits = expectObject(value, path);
  return {
    width: expectNonNegativeInteger(limits.width, childPath(path, "width")),
    height: expectNonNegativeInteger(limits.height, childPath(path, "height")),
    framerate: expectNonNegativeInteger(limits.framerate, childPath(path, "framerate")),
    video_bitrate_min_kbps: expectNonNegativeInteger(limits.video_bitrate_min_kbps, childPath(path, "video_bitrate_min_kbps")),
    video_bitrate_initial_kbps: expectNonNegativeInteger(limits.video_bitrate_initial_kbps, childPath(path, "video_bitrate_initial_kbps")),
    video_bitrate_max_kbps: expectNonNegativeInteger(limits.video_bitrate_max_kbps, childPath(path, "video_bitrate_max_kbps")),
    line_threshold_kbps: expectNonNegativeInteger(limits.line_threshold_kbps, childPath(path, "line_threshold_kbps")),
  };
}

function parseStartLimits(value: unknown, path: string): StartLimits {
  const limits = expectObject(value, path);
  const profilesPath = childPath(path, "profiles");
  const profiles = expectObject(limits.profiles, profilesPath);
  return {
    time_limit_seconds: expectNonNegativeInteger(limits.time_limit_seconds, childPath(path, "time_limit_seconds")),
    // プロファイルの全値（列挙 profile）を明示する。契約が値を増やしたら、型の検査が、ここの不足を指摘する
    profiles: {
      "720p": parseProfileLimits(profiles["720p"], childPath(profilesPath, "720p")),
      "480p": parseProfileLimits(profiles["480p"], childPath(profilesPath, "480p")),
    },
    audio_kbps: expectNonNegativeInteger(limits.audio_kbps, childPath(path, "audio_kbps")),
  };
}

/** 配信の受理（201） */
export function parseStartAccepted(value: unknown): StartAccepted {
  const root = expectObject(value, "");
  return {
    broadcast: parseBroadcastView(root.broadcast, "broadcast"),
    ticket: expectNonEmptyString(root.ticket, "ticket"),
    relay_url: expectWebSocketUrl(root.relay_url, "relay_url"),
    limits: parseStartLimits(root.limits, "limits"),
  };
}

export function parseTicketIssued(value: unknown): TicketIssued {
  const root = expectObject(value, "");
  return {
    ticket: expectNonEmptyString(root.ticket, "ticket"),
    relay_url: expectWebSocketUrl(root.relay_url, "relay_url"),
  };
}

/** {"broadcast":{...}}（停止・取り消し・取得の応答）から、broadcast を取り出す */
export function parseBroadcastEnvelope(value: unknown): BroadcastView {
  const root = expectObject(value, "");
  return parseBroadcastView(root.broadcast, "broadcast");
}

export interface ParsedErrorEnvelope {
  readonly code: ApiErrorCode;
  readonly details: Readonly<Record<string, unknown>>;
}

/** {"error":{"code":"<符号>","details":{...}}}（details は省略できる。省略は、空のオブジェクトと同じ） */
export function parseErrorEnvelope(value: unknown): ParsedErrorEnvelope {
  const root = expectObject(value, "");
  const error = expectObject(root.error, "error");
  return {
    code: expectEnum(error.code, isApiErrorCode, "error.code"),
    details: error.details === undefined ? {} : expectObject(error.details, "error.details"),
  };
}

/** {"rejected":{"reason":..,"resolution":..,"retry_at":..,"fields"?:[..]}}（受付の拒否） */
export function parseRejectedEnvelope(value: unknown): RejectedBody {
  const root = expectObject(value, "");
  const rejected = expectObject(root.rejected, "rejected");
  return {
    reason: expectEnum(rejected.reason, isRejectionReason, "rejected.reason"),
    resolution: expectEnum(rejected.resolution, isResolution, "rejected.resolution"),
    retry_at: expectNullableString(rejected.retry_at, "rejected.retry_at"),
    fields: rejected.fields === undefined ? null : expectStringArray(rejected.fields, "rejected.fields"),
  };
}
