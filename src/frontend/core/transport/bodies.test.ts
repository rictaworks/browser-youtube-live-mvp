/**
 * @jest-environment node
 */
// 本文（JSON）の検証と正規化（ws-protocol.md の 5 章）。
//   - 受け取った値（unknown）から、既知の項目だけを、契約の順で取り出した、新しいオブジェクトを返す（JSON.stringify すると、ベクタと同じ並び）
//   - 未知のキー（x_ で始まるキーを含む）は無視する（前方互換。5.5）。必須の項目が無い・型や値が不正は、FrameError（invalid_body）。項目の名前を詳細に含める
//   - 検査の値は、契約の文書（ws-protocol.md）から書き下している
import { LIMITS } from "../contract";
import { isFrameError } from "./errors";
import {
  parseAcceptedBody,
  parseAckBody,
  parseEndBody,
  parseFatalBody,
  parseHelloTicket,
  parseProbeResultBody,
  parseReportBody,
  parseStartBody,
  parseStatusBody,
  parseThrottleBody,
} from "./bodies";

type Parser = (value: unknown) => unknown;

/** 不正な入力で、invalid_body になり、詳細に項目の名前が入ること。 */
function expectInvalidBody(parse: Parser, input: unknown, fieldFragment: string): void {
  let thrown: unknown;
  try {
    parse(input);
  } catch (error) {
    thrown = error;
  }
  expect(isFrameError(thrown)).toBe(true);
  if (isFrameError(thrown)) {
    expect({ code: thrown.code, mentionsField: thrown.detail.includes(fieldFragment) }).toEqual({ code: "invalid_body", mentionsField: true });
  }
}

/** オブジェクトから、キーを 1 つ除いた複製。 */
function without(object: Record<string, unknown>, key: string): Record<string, unknown> {
  return Object.fromEntries(Object.entries(object).filter(([name]) => name !== key));
}

describe("parseHelloTicket（接続チケット。JSON ではなく、文字列そのもの）", () => {
  test.each([["dummy-ticket-0123456789abcdefghijklmnopqrstuvwxyz"], ["A_b-C.d~e"], ["x"]])("%j は正しい（空白を含まない、印字できる ASCII）", (ticket) => {
    expect(parseHelloTicket(ticket)).toBe(ticket);
  });

  test.each([
    ["空", ""],
    ["空白を含む", "abc def"],
    ["改行を含む", "abc\n"],
    ["制御文字を含む", `abc${String.fromCharCode(0)}`],
    ["ASCII でない文字を含む", `abc${String.fromCodePoint(0x3042)}`],
    ["数値", 123],
    ["null", null],
    ["undefined", undefined],
    ["オブジェクト", { ticket: "abc" }],
  ])("%s は invalid_message（チケットの値を、エラーに含めない）", (_label, value) => {
    let thrown: unknown;
    try {
      parseHelloTicket(value);
    } catch (error) {
      thrown = error;
    }
    expect(isFrameError(thrown) && thrown.code).toBe("invalid_message");
    expect(String((thrown as Error).message)).not.toContain("abc");
  });
});

const VALID_START = {
  profile: "720p",
  video: { codec: "avc1.4D401F", width: 1280, height: 720, framerate: 30, bitrate_kbps: 4500, description_b64: "AU1AH//hAA9nTUAfllQFAe2AoEA8IhEBAARo7jyA" },
  audio: { codec: "mp4a.40.2", sample_rate: 44100, channels: 2, bitrate_kbps: 128, description_b64: "EhA=" },
};

describe("parseStartBody", () => {
  test("正しい開始通知を、契約のキーの順（profile・video・audio。video は codec から description_b64 まで）で返す", () => {
    const parsed = parseStartBody(VALID_START);
    expect(JSON.stringify(parsed)).toBe(JSON.stringify(VALID_START));
    expect(Object.keys(parsed)).toEqual(["profile", "video", "audio"]);
    expect(Object.keys(parsed.video)).toEqual(["codec", "width", "height", "framerate", "bitrate_kbps", "description_b64"]);
    expect(Object.keys(parsed.audio)).toEqual(["codec", "sample_rate", "channels", "bitrate_kbps", "description_b64"]);
  });

  test("480p と Constrained Baseline も正しい。キーの順が違う入力も、契約の順に直す", () => {
    const reordered = {
      audio: { description_b64: "EhA=", bitrate_kbps: 128, channels: 2, sample_rate: 44100, codec: "mp4a.40.2" },
      video: { description_b64: "AU1AH//hABBnTUAfllQDAf6AoEA8IhGoAQAEaO48gA==", bitrate_kbps: 1500, framerate: 30, height: 480, width: 854, codec: "avc1.42E01F" },
      profile: "480p",
    };
    const parsed = parseStartBody(reordered);
    expect(Object.keys(parsed)).toEqual(["profile", "video", "audio"]);
    expect(Object.keys(parsed.video)).toEqual(["codec", "width", "height", "framerate", "bitrate_kbps", "description_b64"]);
    expect(parsed.video.codec).toBe(LIMITS.video.codec_constrained_baseline);
  });

  test("未知のキー（x_ で始まるものを含む）を、結果に含めない（余計な項目を送らない）", () => {
    const withExtras = { ...VALID_START, x_note: "extra", device_label: "My Camera", video: { ...VALID_START.video, x_hint: 1 } };
    const parsed = parseStartBody(withExtras);
    expect(JSON.stringify(parsed)).toBe(JSON.stringify(VALID_START));
  });

  test.each([
    ["映像ビットレートが、プロファイルの下限ちょうど（720p は 3,000）", { video: { ...VALID_START.video, bitrate_kbps: 3000 } }],
    ["映像ビットレートが、プロファイルの上限ちょうど（720p は 6,000）", { video: { ...VALID_START.video, bitrate_kbps: 6000 } }],
  ])("%s は正しい", (_label, override) => {
    expect(() => parseStartBody({ ...VALID_START, ...override })).not.toThrow();
  });

  test.each([
    ["映像ビットレートが下限の 1 つ下（720p は 2,999）", { video: { ...VALID_START.video, bitrate_kbps: 2999 } }, "video.bitrate_kbps"],
    ["映像ビットレートが上限の 1 つ上（720p は 6,001）", { video: { ...VALID_START.video, bitrate_kbps: 6001 } }, "video.bitrate_kbps"],
    ["映像ビットレートが小数", { video: { ...VALID_START.video, bitrate_kbps: 4500.5 } }, "video.bitrate_kbps"],
    ["プロファイルが未知", { profile: "1080p" }, "profile"],
    ["プロファイルが文字列でない", { profile: 720 }, "profile"],
    ["映像のコーデックが未知", { video: { ...VALID_START.video, codec: "avc1.640028" } }, "video.codec"],
    ["映像の幅がプロファイルと違う", { video: { ...VALID_START.video, width: 1281 } }, "video.width"],
    ["映像の高さがプロファイルと違う", { video: { ...VALID_START.video, height: 721 } }, "video.height"],
    ["映像のフレームレートがプロファイルと違う", { video: { ...VALID_START.video, framerate: 60 } }, "video.framerate"],
    ["映像の復号器設定が base64 でない", { video: { ...VALID_START.video, description_b64: "not base64!" } }, "video.description_b64"],
    ["映像の復号器設定が空", { video: { ...VALID_START.video, description_b64: "" } }, "video.description_b64"],
    ["音声のコーデックが違う", { audio: { ...VALID_START.audio, codec: "mp4a.40.5" } }, "audio.codec"],
    ["音声のサンプルレートが違う", { audio: { ...VALID_START.audio, sample_rate: 48000 } }, "audio.sample_rate"],
    ["音声のチャンネル数が違う", { audio: { ...VALID_START.audio, channels: 1 } }, "audio.channels"],
    ["音声のビットレートが違う", { audio: { ...VALID_START.audio, bitrate_kbps: 96 } }, "audio.bitrate_kbps"],
    ["音声の復号器設定が base64 でない", { audio: { ...VALID_START.audio, description_b64: "EhA" } }, "audio.description_b64"],
    ["音声の復号器設定が空", { audio: { ...VALID_START.audio, description_b64: "" } }, "audio.description_b64"],
    ["video がオブジェクトでない", { video: "720p" }, "video"],
    ["audio が配列", { audio: [] }, "audio"],
  ])("%s は invalid_body", (_label, override, field) => {
    expectInvalidBody(parseStartBody, { ...VALID_START, ...override }, field);
  });

  test.each([
    ["profile", "profile"],
    ["video", "video"],
    ["audio", "audio"],
  ])("必須の項目 %s が無ければ invalid_body", (key, field) => {
    expectInvalidBody(parseStartBody, without(VALID_START, key), field);
  });

  test.each([
    ["null", null],
    ["配列", [VALID_START]],
    ["文字列", JSON.stringify(VALID_START)],
    ["数値", 1],
    ["undefined", undefined],
  ])("オブジェクトでない入力（%s）は invalid_body", (_label, input) => {
    expectInvalidBody(parseStartBody, input, "start");
  });

  test("継承されたプロパティ（toString など）を、項目として読まない", () => {
    expectInvalidBody(parseStartBody, Object.create(VALID_START), "profile");
  });
});

const VALID_REPORT = {
  backlog_ms: 1800,
  dropped_video_frames: 12,
  target_kbps: 3000,
  state: "degraded",
  events: [
    { kind: "bitrate_down", detail: { from_kbps: 3300, to_kbps: 3000 } },
    { kind: "video_dropped", detail: { frames: 12 } },
    { kind: "degraded_started" },
  ],
};

describe("parseReportBody", () => {
  test("正しい状態報告を、契約のキーの順で返す。detail が無い出来事は、detail のキーを持たない（null にしない）", () => {
    const parsed = parseReportBody(VALID_REPORT);
    expect(JSON.stringify(parsed)).toBe(JSON.stringify(VALID_REPORT));
    expect(Object.keys(parsed)).toEqual(["backlog_ms", "dropped_video_frames", "target_kbps", "state", "events"]);
    expect("detail" in parsed.events[2]).toBe(false);
  });

  test("出来事が無い（空の配列）報告も正しい。出来事の種別 8 種のすべてが正しい", () => {
    expect(parseReportBody({ ...VALID_REPORT, events: [] }).events).toEqual([]);
    const kinds = ["source_added", "source_lost", "fallback_switched", "bitrate_down", "bitrate_up", "video_dropped", "degraded_started", "degraded_cleared"];
    for (const kind of kinds) {
      expect(parseReportBody({ ...VALID_REPORT, events: [{ kind }] }).events[0].kind).toBe(kind);
    }
  });

  test("未知のキー（x_ で始まるもの）を無視する。日本語の値を持つ未知のキーも、結果に含めない", () => {
    const withExtras = { ...VALID_REPORT, x_vector_text: `${String.fromCodePoint(0x65e5)}${String.fromCodePoint(0x672c)}`, extra: 1, events: [{ kind: "degraded_cleared", note: "free text" }] };
    const parsed = parseReportBody(withExtras);
    expect(JSON.stringify(parsed)).toBe(JSON.stringify({ ...VALID_REPORT, events: [{ kind: "degraded_cleared" }] }));
  });

  test.each([
    ["滞留時間 0", { backlog_ms: 0 }],
    ["破棄フレーム数 0", { dropped_video_frames: 0 }],
    ["目標ビットレート 1", { target_kbps: 1 }],
    ["状態 live", { state: "live" }],
    ["安全整数の最大の滞留時間", { backlog_ms: Number.MAX_SAFE_INTEGER }],
  ])("%s は正しい", (_label, override) => {
    expect(() => parseReportBody({ ...VALID_REPORT, ...override })).not.toThrow();
  });

  test.each([
    ["滞留時間が負", { backlog_ms: -1 }, "backlog_ms"],
    ["滞留時間が小数", { backlog_ms: 1.5 }, "backlog_ms"],
    ["滞留時間が NaN", { backlog_ms: Number.NaN }, "backlog_ms"],
    ["滞留時間が無限大", { backlog_ms: Number.POSITIVE_INFINITY }, "backlog_ms"],
    ["滞留時間が安全整数を超える", { backlog_ms: Number.MAX_SAFE_INTEGER + 1 }, "backlog_ms"],
    ["滞留時間が文字列", { backlog_ms: "120" }, "backlog_ms"],
    ["破棄フレーム数が負", { dropped_video_frames: -1 }, "dropped_video_frames"],
    ["目標ビットレートが 0", { target_kbps: 0 }, "target_kbps"],
    ["目標ビットレートが小数", { target_kbps: 4500.1 }, "target_kbps"],
    ["状態が未知（studio_state の値のうち、配信中でない値）", { state: "reconnecting" }, "state"],
    ["状態が空", { state: "" }, "state"],
    ["events が配列でない", { events: {} }, "events"],
    ["events の要素がオブジェクトでない", { events: ["bitrate_down"] }, "events[0]"],
    ["出来事の種別が未知", { events: [{ kind: "throttle_directed" }] }, "events[0].kind"],
    ["出来事の種別が無い", { events: [{ detail: { frames: 1 } }] }, "events[0].kind"],
    ["detail が null", { events: [{ kind: "video_dropped", detail: null }] }, "events[0].detail"],
    ["detail が配列", { events: [{ kind: "video_dropped", detail: [1] }] }, "events[0].detail"],
    ["detail が文字列", { events: [{ kind: "video_dropped", detail: "frames=1" }] }, "events[0].detail"],
  ])("%s は invalid_body", (_label, override, field) => {
    expectInvalidBody(parseReportBody, { ...VALID_REPORT, ...override }, field);
  });

  test.each([
    ["backlog_ms", "backlog_ms"],
    ["dropped_video_frames", "dropped_video_frames"],
    ["target_kbps", "target_kbps"],
    ["state", "state"],
    ["events", "events"],
  ])("必須の項目 %s が無ければ invalid_body", (key, field) => {
    expectInvalidBody(parseReportBody, without(VALID_REPORT, key), field);
  });
});

describe("parseReportBody: detail は、符号と数値のみ（5.6。自由記述・デバイス名・ラベル・入れ子・配列・null を載せない）", () => {
  const withDetail = (detail: unknown): unknown => ({ ...VALID_REPORT, events: [{ kind: "source_lost", detail }] });

  test.each([
    ["整数の値", { frames: 12 }],
    ["符号の値（小文字・数字・アンダースコア）", { source: "shared_audio" }],
    ["数字だけの符号", { code: "720" }],
    ["組が 4 つ（上限）", { a: 1, b: 2, c: 3, d: 4 }],
    ["キーが 32 文字（上限）", { [`a${"b".repeat(31)}`]: 1 }],
    ["値の文字列が 32 文字（上限）", { source: "a".repeat(32) }],
    ["値が 0", { frames: 0 }],
    ["値が負の整数", { delta: -5 }],
    ["空の detail", {}],
  ])("%s は正しい", (_label, detail) => {
    expect(() => parseReportBody(withDetail(detail))).not.toThrow();
  });

  test.each([
    ["組が 5 つ（上限を超える）", { a: 1, b: 2, c: 3, d: 4, e: 5 }],
    ["キーが 33 文字", { [`a${"b".repeat(32)}`]: 1 }],
    ["キーが大文字を含む", { Source: "camera" }],
    ["キーが数字で始まる", { "1source": "camera" }],
    ["キーがハイフンを含む", { "from-kbps": 1 }],
    ["キーが空", { "": 1 }],
    ["キーが __proto__", JSON.parse('{"__proto__": 1}') as unknown],
    ["値の文字列が 33 文字", { source: "a".repeat(33) }],
    ["値の文字列が空", { source: "" }],
    ["値の文字列が大文字を含む（デバイス名・ラベルになり得る）", { source: "Camera" }],
    ["値の文字列が空白を含む（デバイス名・ラベルになり得る）", { source: "my camera" }],
    ["値の文字列がピリオドやハイフンを含む（ID・URL になり得る）", { source: "a.b-c" }],
    ["値の文字列が日本語", { source: String.fromCodePoint(0x30ab, 0x30e1, 0x30e9) }],
    ["値が小数", { frames: 1.5 }],
    ["値が NaN", { frames: Number.NaN }],
    ["値が安全整数を超える", { frames: Number.MAX_SAFE_INTEGER + 1 }],
    ["値が真偽値", { frames: true }],
    ["値が null", { frames: null }],
    ["値が入れ子のオブジェクト", { frames: { n: 1 } }],
    ["値が配列", { frames: [1] }],
  ])("%s は invalid_body", (_label, detail) => {
    expectInvalidBody(parseReportBody, withDetail(detail), "detail");
  });

  test("detail の組の順を、保つ（from_kbps、to_kbps の順）", () => {
    const parsed = parseReportBody({ ...VALID_REPORT, events: [{ kind: "bitrate_up", detail: { from_kbps: 3000, to_kbps: 3300 } }] });
    expect(Object.keys(parsed.events[0].detail ?? {})).toEqual(["from_kbps", "to_kbps"]);
  });
});

describe("parseEndBody", () => {
  test.each([["user_stop"], ["user_cancel"], ["insufficient_bandwidth"]])("理由 %s は正しい（ブラウザが伝えられる 3 つ）", (reason) => {
    expect(parseEndBody({ reason })).toEqual({ reason });
  });

  test.each([
    ["列挙 end_reason の値でも、ブラウザが伝えられない（time_limit）", { reason: "time_limit" }, "reason"],
    ["列挙 end_reason の値でも、ブラウザが伝えられない（relay_disconnect）", { reason: "relay_disconnect" }, "reason"],
    ["未知", { reason: "bored" }, "reason"],
    ["理由が無い", {}, "reason"],
    ["理由が文字列でない", { reason: 1 }, "reason"],
  ])("%s は invalid_body", (_label, input, field) => {
    expectInvalidBody(parseEndBody, input, field);
  });

  test("未知のキーを無視する", () => {
    expect(JSON.stringify(parseEndBody({ reason: "user_stop", x_a: 1, message: "bye" }))).toBe('{"reason":"user_stop"}');
  });
});

describe("parseAcceptedBody（中継 → ブラウザ。5.8）", () => {
  const first = { state: "reserved", resume: false, profile: null, limits: { time_limit_seconds: 3600 } };
  const resumed = { state: "live", resume: true, profile: "720p", limits: { time_limit_seconds: 3600 } };

  test("初回（resume が false・profile が null）と再開（resume が true・確定済みの profile）", () => {
    expect(parseAcceptedBody(first)).toEqual(first);
    expect(parseAcceptedBody(resumed)).toEqual(resumed);
  });

  test("配信レコードの状態 6 種（列挙 broadcast_state）が、すべて正しい", () => {
    for (const state of ["reserved", "awaiting_media", "confirming", "live", "interrupted", "ended"]) {
      expect(parseAcceptedBody({ ...first, state }).state).toBe(state);
    }
  });

  test("未知のキー（x_ を含む）と、limits の未知のキーを無視する", () => {
    const parsed = parseAcceptedBody({ ...first, x_trace: "t", limits: { time_limit_seconds: 60, x_other: 1 } });
    expect(JSON.stringify(parsed)).toBe(JSON.stringify({ ...first, limits: { time_limit_seconds: 60 } }));
  });

  test.each([
    ["state が未知", { state: "idle" }, "state"],
    ["state が null", { state: null }, "state"],
    ["resume が文字列", { resume: "false" }, "resume"],
    ["resume が数値", { resume: 0 }, "resume"],
    ["profile が未知", { profile: "1080p" }, "profile"],
    ["profile が数値", { profile: 720 }, "profile"],
    ["limits がオブジェクトでない", { limits: 3600 }, "limits"],
    ["時間上限が負", { limits: { time_limit_seconds: -1 } }, "limits.time_limit_seconds"],
    ["時間上限が小数", { limits: { time_limit_seconds: 3600.5 } }, "limits.time_limit_seconds"],
    ["時間上限が無い", { limits: {} }, "limits.time_limit_seconds"],
  ])("%s は invalid_body", (_label, override, field) => {
    expectInvalidBody(parseAcceptedBody, { ...first, ...override }, field);
  });

  test.each([["state"], ["resume"], ["profile"], ["limits"]])("必須の項目 %s が無ければ invalid_body（null でよい項目も、省略はできない）", (key) => {
    expectInvalidBody(parseAcceptedBody, without(first, key), key);
  });
});

describe("parseProbeResultBody（5.9）", () => {
  test.each([[0], [1], [1200], [4100], [5200], [Number.MAX_SAFE_INTEGER]])("throughput_kbps %i は正しい", (value) => {
    expect(parseProbeResultBody({ throughput_kbps: value })).toEqual({ throughput_kbps: value });
  });

  test.each([
    ["負", -1],
    ["小数", 5200.5],
    ["NaN", Number.NaN],
    ["文字列", "5200"],
    ["null", null],
    ["安全整数を超える", Number.MAX_SAFE_INTEGER + 1],
  ])("throughput_kbps が %s なら invalid_body", (_label, value) => {
    expectInvalidBody(parseProbeResultBody, { throughput_kbps: value }, "throughput_kbps");
  });

  test("項目が無ければ invalid_body。未知のキーは無視する", () => {
    expectInvalidBody(parseProbeResultBody, {}, "throughput_kbps");
    expect(parseProbeResultBody({ throughput_kbps: 1, x_a: 2 })).toEqual({ throughput_kbps: 1 });
  });
});

describe("parseAckBody（5.10。メディア時刻のマイクロ秒）", () => {
  test("映像・音声の受領済みの最新時刻。未受信の種別は 0", () => {
    expect(parseAckBody({ video_us: 33_333, audio_us: 23_220 })).toEqual({ video_us: 33_333, audio_us: 23_220 });
    expect(parseAckBody({ video_us: 0, audio_us: 0 })).toEqual({ video_us: 0, audio_us: 0 });
  });

  test("安全整数の最大まで正しい。それを超える値は、厳密に表せないので invalid_body", () => {
    expect(parseAckBody({ video_us: Number.MAX_SAFE_INTEGER, audio_us: 1 }).video_us).toBe(Number.MAX_SAFE_INTEGER);
    expectInvalidBody(parseAckBody, { video_us: Number.MAX_SAFE_INTEGER + 1, audio_us: 1 }, "video_us");
  });

  test.each([
    ["video_us が負", { video_us: -1, audio_us: 0 }, "video_us"],
    ["audio_us が負", { video_us: 0, audio_us: -1 }, "audio_us"],
    ["video_us が小数", { video_us: 0.5, audio_us: 0 }, "video_us"],
    ["audio_us が文字列", { video_us: 0, audio_us: "0" }, "audio_us"],
    ["video_us が無い", { audio_us: 0 }, "video_us"],
    ["audio_us が無い", { video_us: 0 }, "audio_us"],
  ])("%s は invalid_body", (_label, input, field) => {
    expectInvalidBody(parseAckBody, input, field);
  });
});

describe("parseThrottleBody（5.12。目標ビットレートは正の整数）", () => {
  test.each([[1], [800], [3150], [6000]])("target_kbps %i は正しい", (value) => {
    expect(parseThrottleBody({ target_kbps: value })).toEqual({ target_kbps: value });
  });

  test.each([
    ["0", 0],
    ["負", -3150],
    ["小数", 3150.5],
    ["文字列", "3150"],
    ["null", null],
  ])("target_kbps が %s なら invalid_body", (_label, value) => {
    expectInvalidBody(parseThrottleBody, { target_kbps: value }, "target_kbps");
  });

  test("項目が無ければ invalid_body", () => {
    expectInvalidBody(parseThrottleBody, {}, "target_kbps");
  });
});

describe("parseStatusBody（5.13。毎回、状態の全体）", () => {
  const live = { state: "live", watch_url: "https://www.youtube.com/watch?v=dummyVideoId", warning: null, time_limit_notice_seconds: null, end_reason: null };

  test("全体のスナップショット（null を含む）を、契約のキーの順で返す", () => {
    const parsed = parseStatusBody(live);
    expect(parsed).toEqual(live);
    expect(Object.keys(parsed)).toEqual(["state", "watch_url", "warning", "time_limit_notice_seconds", "end_reason"]);
  });

  test("視聴 URL が null（準備の完了前）・警告・時間上限の予告（300 秒）・終了の理由", () => {
    expect(parseStatusBody({ ...live, state: "reserved", watch_url: null }).watch_url).toBeNull();
    expect(parseStatusBody({ ...live, warning: "youtube_stream_unhealthy" }).warning).toBe("youtube_stream_unhealthy");
    expect(parseStatusBody({ ...live, time_limit_notice_seconds: 300 }).time_limit_notice_seconds).toBe(300);
    expect(parseStatusBody({ ...live, state: "ended", end_reason: "time_limit" }).end_reason).toBe("time_limit");
  });

  test("終了の理由 13 種（列挙 end_reason）が、すべて正しい", () => {
    const reasons = ["user_stop", "time_limit", "connection_lost", "youtube_ended", "authorization_revoked", "admin_stop", "start_timeout", "confirm_timeout", "prepare_failed", "prior_unsettled", "insufficient_bandwidth", "user_cancel", "relay_disconnect"];
    for (const end_reason of reasons) {
      expect(parseStatusBody({ ...live, state: "ended", end_reason }).end_reason).toBe(end_reason);
    }
  });

  test.each([
    ["state が未知", { state: "idle" }, "state"],
    ["watch_url が数値", { watch_url: 1 }, "watch_url"],
    ["watch_url がオブジェクト", { watch_url: {} }, "watch_url"],
    ["warning が未知", { warning: "stream_dead" }, "warning"],
    ["warning が真偽値", { warning: true }, "warning"],
    ["time_limit_notice_seconds が負", { time_limit_notice_seconds: -1 }, "time_limit_notice_seconds"],
    ["time_limit_notice_seconds が小数", { time_limit_notice_seconds: 299.5 }, "time_limit_notice_seconds"],
    ["time_limit_notice_seconds が文字列", { time_limit_notice_seconds: "300" }, "time_limit_notice_seconds"],
    ["end_reason が未知", { end_reason: "bored" }, "end_reason"],
    ["end_reason が数値", { end_reason: 1 }, "end_reason"],
  ])("%s は invalid_body", (_label, override, field) => {
    expectInvalidBody(parseStatusBody, { ...live, ...override }, field);
  });

  test.each([["state"], ["watch_url"], ["warning"], ["time_limit_notice_seconds"], ["end_reason"]])("必須の項目 %s が無ければ invalid_body（スナップショットは全体を載せる）", (key) => {
    expectInvalidBody(parseStatusBody, without(live, key), key);
  });
});

describe("parseFatalBody（5.14）", () => {
  test("致命通知の符号 10 種（列挙 fatal_code）が、すべて正しい", () => {
    const codes = ["message_too_large", "bitrate_exceeded", "hello_timeout", "invalid_ticket", "stale_epoch", "broadcast_ended", "protocol_violation", "heartbeat_lost", "publish_failed", "internal_error"];
    for (const code of codes) {
      expect(parseFatalBody({ code })).toEqual({ code });
    }
  });

  test.each([
    ["未知の符号", { code: "boom" }],
    ["符号が無い", {}],
    ["符号が数値", { code: 1 }],
    ["符号が null", { code: null }],
  ])("%s は invalid_body", (_label, input) => {
    expectInvalidBody(parseFatalBody, input, "code");
  });
});

describe("全体：本文の値は、入力を変更せず、新しいオブジェクトを返す", () => {
  test("入力のオブジェクト・配列を書き換えても、結果は変わらない（共有しない）", () => {
    const input = JSON.parse(JSON.stringify(VALID_REPORT)) as { events: Array<{ kind: string; detail?: Record<string, number> }> };
    const parsed = parseReportBody(input);
    const firstDetail = input.events[0].detail;
    if (firstDetail !== undefined) {
      firstDetail.from_kbps = 1;
    }
    input.events.push({ kind: "degraded_cleared" });
    expect(parsed.events).toHaveLength(3);
    expect(parsed.events[0].detail).toEqual({ from_kbps: 3300, to_kbps: 3000 });
  });
});
