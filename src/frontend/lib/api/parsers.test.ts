/**
 * @jest-environment node
 */
import { BROADCAST_STATE_VALUES, END_REASON_VALUES, REJECTION_REASON_VALUES, RESOLUTION_VALUES, YOUTUBE_CONNECTION_STATE_VALUES } from "@/core/contract";
import {
  parseAuthorizationStart,
  parseBroadcastEnvelope,
  parseBroadcastView,
  parseErrorEnvelope,
  parseRejectedEnvelope,
  parseStartAccepted,
  parseStateResponse,
  parseTicketIssued,
  parseYoutubeEnvelope,
} from "./parsers";
import {
  authenticatedState,
  BROADCAST_VIEW,
  DUMMY_AUTHORIZATION_URL,
  DUMMY_CSRF_TOKEN,
  START_ACCEPTED,
  UNAUTHENTICATED_STATE,
  USAGE_VIEW,
  YOUTUBE_VIEW,
} from "./test-support";
import { ShapeError } from "./validate";

// 応答の検証は、契約（src/contracts/http-api.md）の形と、列挙（core/contract）に合わないものを、成功にしない（フォールバック禁止）。
// 例外は、不正な項目の「位置」だけを持つ（値は、トークンなどを含みうるため、持たない）。

function shapeErrorPath(run: () => unknown): string {
  try {
    run();
  } catch (error) {
    if (error instanceof ShapeError) {
      return error.path;
    }
    throw error;
  }
  throw new Error("ShapeError になるはずが、成功した");
}

describe("parseStateResponse", () => {
  it("未ログインの応答（authenticated: false・csrf_token: null）", () => {
    expect(parseStateResponse(UNAUTHENTICATED_STATE)).toEqual({ authenticated: false, csrf_token: null });
  });

  it("ログイン済みの応答（利用状況・YouTube の接続・進行中の配信なし）", () => {
    const state = parseStateResponse(authenticatedState());

    expect(state).toEqual(authenticatedState());
    expect(state.authenticated && state.csrf_token).toBe(DUMMY_CSRF_TOKEN);
  });

  it("進行中の配信（BroadcastView）を持つ応答", () => {
    const state = parseStateResponse(authenticatedState({ broadcast: { ...BROADCAST_VIEW } }));

    expect(state.authenticated && state.broadcast?.state).toBe("live");
  });

  it("チャンネル名・再確認できる時刻を持つ YouTube の接続", () => {
    const state = parseStateResponse(
      authenticatedState({ youtube: { state: "live_not_enabled", channel_title: "dummy-channel", can_recheck_at: "2026-10-07T13:31:00+09:00" } }),
    );

    expect(state.authenticated && state.youtube).toEqual({
      state: "live_not_enabled",
      channel_title: "dummy-channel",
      can_recheck_at: "2026-10-07T13:31:00+09:00",
    });
  });

  it.each(YOUTUBE_CONNECTION_STATE_VALUES.map((value) => [value] as const))("YouTube の接続状態 %s を受け付ける", (value) => {
    expect(() => parseStateResponse(authenticatedState({ youtube: { ...YOUTUBE_VIEW, state: value } }))).not.toThrow();
  });

  it.each([
    ["JSON のオブジェクトではない", "not an object", "$"],
    ["null", null, "$"],
    ["配列", [], "$"],
    ["authenticated が無い", { csrf_token: null }, "authenticated"],
    ["authenticated が真偽値でない", { authenticated: "false", csrf_token: null }, "authenticated"],
    ["未ログインなのに csrf_token が文字列", { authenticated: false, csrf_token: "x" }, "csrf_token"],
    ["ログイン済みなのに csrf_token が null", authenticatedState({ csrf_token: null }), "csrf_token"],
    ["ログイン済みなのに csrf_token が空", authenticatedState({ csrf_token: "" }), "csrf_token"],
    ["usage が無い", authenticatedState({ usage: undefined }), "usage"],
    ["usage の数が文字列", authenticatedState({ usage: { ...USAGE_VIEW, allowance_total: "1" } }), "usage.allowance_total"],
    ["usage の数が負", authenticatedState({ usage: { ...USAGE_VIEW, attempts_remaining: -1 } }), "usage.attempts_remaining"],
    ["usage の数が小数", authenticatedState({ usage: { ...USAGE_VIEW, allowance_remaining: 0.5 } }), "usage.allowance_remaining"],
    ["usage の真偽値が文字列", authenticatedState({ usage: { ...USAGE_VIEW, intake_paused: "no" } }), "usage.intake_paused"],
    ["youtube が無い", authenticatedState({ youtube: undefined }), "youtube"],
    ["youtube.state が未知の値", authenticatedState({ youtube: { ...YOUTUBE_VIEW, state: "unknown_state" } }), "youtube.state"],
    ["youtube.channel_title が数", authenticatedState({ youtube: { ...YOUTUBE_VIEW, channel_title: 1 } }), "youtube.channel_title"],
    ["broadcast が undefined（キーが無い。契約は、値が無いとき null で、必ず持つ）", authenticatedState({ broadcast: undefined }), "broadcast"],
    ["broadcast.state が未知の値", authenticatedState({ broadcast: { ...BROADCAST_VIEW, state: "paused" } }), "broadcast.state"],
  ])("不正な応答（%s）は、ShapeError（位置: %s）", (_title, value, path) => {
    expect(shapeErrorPath(() => parseStateResponse(value))).toBe(path);
  });
});

describe("parseBroadcastView", () => {
  it("契約の例（ライブ中）", () => {
    expect(parseBroadcastView({ ...BROADCAST_VIEW }, "broadcast")).toEqual(BROADCAST_VIEW);
  });

  it.each(BROADCAST_STATE_VALUES.map((value) => [value] as const))("配信の状態 %s を受け付ける", (state) => {
    expect(parseBroadcastView({ ...BROADCAST_VIEW, state }, "broadcast").state).toBe(state);
  });

  it.each(END_REASON_VALUES.map((value) => [value] as const))("終了理由 %s を受け付ける", (endReason) => {
    expect(parseBroadcastView({ ...BROADCAST_VIEW, state: "ended", end_reason: endReason }, "broadcast").end_reason).toBe(endReason);
  });

  it("終了した配信（配信時間・次に開始できる時刻を持つ）", () => {
    const ended = {
      ...BROADCAST_VIEW,
      state: "ended",
      end_reason: "user_stop",
      ended_at: "2026-10-07T13:51:10+09:00",
      duration_seconds: 1200,
      next_available_at: "2026-10-08T03:00:00+09:00",
      resumable: false,
    };

    expect(parseBroadcastView(ended, "broadcast")).toEqual(ended);
  });

  it.each([
    ["id が無い", { ...BROADCAST_VIEW, id: undefined }, "broadcast.id"],
    ["end_reason が未知の値", { ...BROADCAST_VIEW, end_reason: "crashed" }, "broadcast.end_reason"],
    ["profile が未知の値", { ...BROADCAST_VIEW, profile: "1080p" }, "broadcast.profile"],
    ["accepted_at が無い", { ...BROADCAST_VIEW, accepted_at: undefined }, "broadcast.accepted_at"],
    ["resumable が真偽値でない", { ...BROADCAST_VIEW, resumable: 1 }, "broadcast.resumable"],
    ["duration_seconds が文字列", { ...BROADCAST_VIEW, duration_seconds: "10" }, "broadcast.duration_seconds"],
    ["watch_url が数", { ...BROADCAST_VIEW, watch_url: 1 }, "broadcast.watch_url"],
  ])("不正（%s）は、ShapeError（位置: %s）", (_title, value, path) => {
    expect(shapeErrorPath(() => parseBroadcastView(value, "broadcast"))).toBe(path);
  });
});

describe("parseAuthorizationStart（ログイン・YouTube 接続の開始）", () => {
  it("authorization_url を返す", () => {
    expect(parseAuthorizationStart({ authorization_url: DUMMY_AUTHORIZATION_URL })).toEqual({ authorization_url: DUMMY_AUTHORIZATION_URL });
  });

  it.each([
    ["authorization_url が無い", {}, "authorization_url"],
    ["authorization_url が空", { authorization_url: "" }, "authorization_url"],
    ["authorization_url が文字列でない", { authorization_url: 1 }, "authorization_url"],
  ])("不正（%s）は、ShapeError（位置: %s）", (_title, value, path) => {
    expect(shapeErrorPath(() => parseAuthorizationStart(value))).toBe(path);
  });
});

describe("parseYoutubeEnvelope（再確認・接続解除）", () => {
  it("youtube を取り出す", () => {
    expect(parseYoutubeEnvelope({ youtube: { state: "connected", channel_title: null, can_recheck_at: "2026-10-07T13:31:00+09:00" } })).toEqual({
      state: "connected",
      channel_title: null,
      can_recheck_at: "2026-10-07T13:31:00+09:00",
    });
  });

  it("youtube が無ければ、ShapeError", () => {
    expect(shapeErrorPath(() => parseYoutubeEnvelope({}))).toBe("youtube");
  });
});

describe("parseStartAccepted（配信の受理 201）", () => {
  it("契約の例", () => {
    expect(parseStartAccepted({ ...START_ACCEPTED })).toEqual(START_ACCEPTED);
  });

  it.each([
    ["ticket が空", { ...START_ACCEPTED, ticket: "" }, "ticket"],
    ["relay_url が無い", { ...START_ACCEPTED, relay_url: undefined }, "relay_url"],
    ["relay_url が WebSocket の URL でない（http）", { ...START_ACCEPTED, relay_url: "http://localhost:3002/ws" }, "relay_url"],
    ["relay_url が URL でない", { ...START_ACCEPTED, relay_url: "not a url" }, "relay_url"],
    ["limits が無い", { ...START_ACCEPTED, limits: undefined }, "limits"],
    ["time_limit_seconds が文字列", { ...START_ACCEPTED, limits: { ...START_ACCEPTED.limits, time_limit_seconds: "3600" } }, "limits.time_limit_seconds"],
    [
      "480p のプロファイルが無い",
      { ...START_ACCEPTED, limits: { ...START_ACCEPTED.limits, profiles: { "720p": START_ACCEPTED.limits.profiles["720p"] } } },
      "limits.profiles.480p",
    ],
    [
      "プロファイルの数が文字列",
      {
        ...START_ACCEPTED,
        limits: {
          ...START_ACCEPTED.limits,
          profiles: { ...START_ACCEPTED.limits.profiles, "720p": { ...START_ACCEPTED.limits.profiles["720p"], width: "1280" } },
        },
      },
      "limits.profiles.720p.width",
    ],
    ["audio_kbps が無い", { ...START_ACCEPTED, limits: { ...START_ACCEPTED.limits, audio_kbps: undefined } }, "limits.audio_kbps"],
    ["broadcast が不正", { ...START_ACCEPTED, broadcast: { ...START_ACCEPTED.broadcast, state: "x" } }, "broadcast.state"],
  ])("不正（%s）は、ShapeError（位置: %s）", (_title, value, path) => {
    expect(shapeErrorPath(() => parseStartAccepted(value))).toBe(path);
  });

  it("wss の接続先も受け付ける", () => {
    expect(parseStartAccepted({ ...START_ACCEPTED, relay_url: "wss://relay.example.test/ws" }).relay_url).toBe("wss://relay.example.test/ws");
  });
});

describe("parseTicketIssued（復帰のチケット）", () => {
  it("ticket と relay_url を返す", () => {
    expect(parseTicketIssued({ ticket: "dummy-ticket", relay_url: "ws://localhost:3002/ws" })).toEqual({
      ticket: "dummy-ticket",
      relay_url: "ws://localhost:3002/ws",
    });
  });

  it("ticket が無ければ、ShapeError", () => {
    expect(shapeErrorPath(() => parseTicketIssued({ relay_url: "ws://localhost:3002/ws" }))).toBe("ticket");
  });
});

describe("parseBroadcastEnvelope（停止・取り消し・取得）", () => {
  it("broadcast を取り出す", () => {
    expect(parseBroadcastEnvelope({ broadcast: { ...BROADCAST_VIEW } })).toEqual(BROADCAST_VIEW);
  });

  it("broadcast が無ければ、ShapeError", () => {
    expect(shapeErrorPath(() => parseBroadcastEnvelope({}))).toBe("broadcast");
  });
});

describe("parseErrorEnvelope（エラーの形 {error:{code,details}}）", () => {
  it("符号と details を返す", () => {
    expect(parseErrorEnvelope({ error: { code: "rate_limited", details: { retry_at: "2026-10-07T13:31:00+09:00" } } })).toEqual({
      code: "rate_limited",
      details: { retry_at: "2026-10-07T13:31:00+09:00" },
    });
  });

  it("details を省略した形は、空の details と同じ", () => {
    expect(parseErrorEnvelope({ error: { code: "not_logged_in" } })).toEqual({ code: "not_logged_in", details: {} });
  });

  it.each([
    ["error が無い", {}, "error"],
    ["code が未知の符号", { error: { code: "made_up_code" } }, "error.code"],
    ["code が無い", { error: {} }, "error.code"],
    ["details がオブジェクトでない", { error: { code: "invalid_input", details: "x" } }, "error.details"],
    ["rejected の形（エラーの形ではない）", { rejected: { reason: "rate_limited" } }, "error"],
  ])("不正（%s）は、ShapeError（位置: %s）", (_title, value, path) => {
    expect(shapeErrorPath(() => parseErrorEnvelope(value))).toBe(path);
  });
});

describe("parseRejectedEnvelope（受付の拒否 {rejected:{reason,resolution,retry_at}}）", () => {
  it("契約の例（次の利用日まで）", () => {
    expect(
      parseRejectedEnvelope({ rejected: { reason: "allowance_consumed", resolution: "next_usage_day", retry_at: "2026-10-08T03:00:00+09:00" } }),
    ).toEqual({ reason: "allowance_consumed", resolution: "next_usage_day", retry_at: "2026-10-08T03:00:00+09:00", fields: null });
  });

  it("invalid_input は、不備のある項目名（fields）を持つ", () => {
    expect(
      parseRejectedEnvelope({ rejected: { reason: "invalid_input", resolution: "fix_input", retry_at: null, fields: ["title"] } }),
    ).toEqual({ reason: "invalid_input", resolution: "fix_input", retry_at: null, fields: ["title"] });
  });

  it.each(REJECTION_REASON_VALUES.map((value) => [value] as const))("拒否理由 %s を受け付ける", (reason) => {
    expect(parseRejectedEnvelope({ rejected: { reason, resolution: "wait", retry_at: null } }).reason).toBe(reason);
  });

  it.each(RESOLUTION_VALUES.map((value) => [value] as const))("区分 %s を受け付ける", (resolution) => {
    expect(parseRejectedEnvelope({ rejected: { reason: "capacity_full", resolution, retry_at: null } }).resolution).toBe(resolution);
  });

  it.each([
    ["rejected が無い", {}, "rejected"],
    ["reason が未知", { rejected: { reason: "nope", resolution: "wait", retry_at: null } }, "rejected.reason"],
    ["resolution が未知", { rejected: { reason: "capacity_full", resolution: "nope", retry_at: null } }, "rejected.resolution"],
    ["retry_at が無い（契約は、値が無いとき null で、必ず持つ）", { rejected: { reason: "capacity_full", resolution: "wait" } }, "rejected.retry_at"],
    ["retry_at が数", { rejected: { reason: "capacity_full", resolution: "wait", retry_at: 1 } }, "rejected.retry_at"],
    ["fields が文字列の配列でない", { rejected: { reason: "invalid_input", resolution: "fix_input", retry_at: null, fields: [1] } }, "rejected.fields"],
  ])("不正（%s）は、ShapeError（位置: %s）", (_title, value, path) => {
    expect(shapeErrorPath(() => parseRejectedEnvelope(value))).toBe(path);
  });
});

describe("ShapeError", () => {
  it("メッセージは、位置だけを持つ（不正な値・トークンを含めない）", () => {
    const secret = "dummy-secret-value-that-must-not-leak";

    try {
      parseAuthorizationStart({ authorization_url: 12345, secret });
    } catch (error) {
      expect((error as ShapeError).message).toBe("unexpected response shape at authorization_url");
      expect((error as ShapeError).message).not.toContain(secret);
    }
    expect.assertions(2);
  });
});
