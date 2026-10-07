// API クライアントと、これを使う画面のテストの共通部品。テストからだけ使う（実行時のコードから import しない）。
// 応答の例は、src/contracts/http-api.md の例（符号・数値・時刻の形）に合わせた、明らかなダミーの値。
import type { ApiFetch, ApiRequestInit, ApiResponseLike } from "./client";

export const DUMMY_CSRF_TOKEN = "dummy-csrf-token-0123456789abcdef";
export const DUMMY_RECAPTCHA_TOKEN = "dummy-recaptcha-token";
export const DUMMY_BROADCAST_ID = "2f6c1d0e-7b5a-4f0e-9a43-5c8f1e2d3a4b";
export const DUMMY_AUTHORIZATION_URL =
  "https://accounts.google.com/o/oauth2/v2/auth?client_id=dummy&response_type=code&scope=openid&state=dummy-state";

export const UNAUTHENTICATED_STATE = { authenticated: false, csrf_token: null } as const;

export const USAGE_VIEW = {
  usage_date: "2026-10-07",
  allowance_total: 1,
  allowance_remaining: 1,
  attempts_remaining: 3,
  next_available_at: null,
  monthly_intake_closed: false,
  intake_paused: false,
} as const;

export const YOUTUBE_VIEW = { state: "connected", channel_title: null, can_recheck_at: null } as const;

export const BROADCAST_VIEW = {
  id: DUMMY_BROADCAST_ID,
  state: "live",
  end_reason: null,
  profile: "720p",
  accepted_at: "2026-10-07T13:30:00+09:00",
  live_at: "2026-10-07T13:31:10+09:00",
  ended_at: null,
  time_limit_ends_at: "2026-10-07T14:31:10+09:00",
  watch_url: "https://www.youtube.com/watch?v=dummyVideoId",
  resumable: true,
  duration_seconds: null,
  next_available_at: null,
} as const;

export function authenticatedState(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    authenticated: true,
    csrf_token: DUMMY_CSRF_TOKEN,
    usage: { ...USAGE_VIEW },
    youtube: { ...YOUTUBE_VIEW },
    broadcast: null,
    ...overrides,
  };
}

export const START_ACCEPTED = {
  broadcast: { ...BROADCAST_VIEW, state: "reserved", profile: null, live_at: null, time_limit_ends_at: null, watch_url: null, resumable: false },
  ticket: "dummy-ticket-0123456789abcdefghijklmnopqrstuvwxyz",
  relay_url: "ws://localhost:3002/ws",
  limits: {
    time_limit_seconds: 3600,
    profiles: {
      "720p": {
        width: 1280,
        height: 720,
        framerate: 30,
        video_bitrate_min_kbps: 3000,
        video_bitrate_initial_kbps: 4500,
        video_bitrate_max_kbps: 6000,
        line_threshold_kbps: 4100,
      },
      "480p": {
        width: 854,
        height: 480,
        framerate: 30,
        video_bitrate_min_kbps: 800,
        video_bitrate_initial_kbps: 1500,
        video_bitrate_max_kbps: 2500,
        line_threshold_kbps: 1200,
      },
    },
    audio_kbps: 128,
  },
} as const;

export interface FakeCall {
  readonly url: string;
  readonly init: ApiRequestInit;
}

/** 応答を、JSON の本文つきで作る（Content-Type は、契約どおり application/json; charset=utf-8） */
export function jsonResponse(status: number, body: unknown, headers: Record<string, string> = {}): ApiResponseLike {
  return makeResponse(status, JSON.stringify(body), { "content-type": "application/json; charset=utf-8", ...headers });
}

export function emptyResponse(status: number): ApiResponseLike {
  return makeResponse(status, "", {});
}

export function textResponse(status: number, text: string, contentType: string): ApiResponseLike {
  return makeResponse(status, text, { "content-type": contentType });
}

function makeResponse(status: number, text: string, headers: Record<string, string>): ApiResponseLike {
  const lower = new Map(Object.entries(headers).map(([name, value]) => [name.toLowerCase(), value]));
  return {
    status,
    headers: { get: (name: string) => lower.get(name.toLowerCase()) ?? null },
    text: async () => text,
  };
}

export type FakeRespond = (url: string, init: ApiRequestInit) => ApiResponseLike | Promise<ApiResponseLike>;

/** 呼び出しを記録する、fetch の疑似実装（本物のバックエンドを呼ばない） */
export function createFakeFetch(respond: FakeRespond): { fetch: ApiFetch; calls: FakeCall[] } {
  const calls: FakeCall[] = [];
  const fetchImpl: ApiFetch = async (url, init) => {
    calls.push({ url, init });
    return respond(url, init);
  };
  return { fetch: fetchImpl, calls };
}

export function headerOf(call: FakeCall | undefined, name: string): string | undefined {
  if (call === undefined) {
    throw new Error("fetch was not called");
  }
  const wanted = name.toLowerCase();
  const entry = Object.entries(call.init.headers).find(([key]) => key.toLowerCase() === wanted);
  return entry?.[1];
}
