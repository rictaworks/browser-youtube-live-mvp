/**
 * @jest-environment node
 */
// FrameCodec（ws-protocol.md の 3 章・5 章）：ブラウザが送る 7 種の encode と、ブラウザが受ける 7 種の decode。
//   - encode は、型付きのメッセージを検証し、契約のキーの順の JSON（UTF-8）と、17 バイトのヘッダのフレームにする。知らない項目を送らない
//   - decode は、方向（中継 → ブラウザだけを受理）・長さ・大きさを、ws-protocol.md の 4 章の順に検証し、JSON の本文を型付きにする。
//     不備は、そのメッセージを破棄するための、型付きのエラー（FrameError）。黙って捨てない
//   - 共有テストベクタとの突き合わせは、FrameCodec.vectors.test.ts
import { LIMITS } from "../contract";
import { FrameCodec } from "./FrameCodec";
import { isFrameError } from "./errors";
import type { FrameErrorCode } from "./errors";
import { decodeRawFrame, encodeRawFrame } from "./frameLayout";
import type { OutboundMessage } from "./messages";

const codec = new FrameCodec();

function utf8(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}

function text(bytes: Uint8Array): string {
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}

function expectFrameError(action: () => unknown, code: FrameErrorCode): void {
  let thrown: unknown;
  try {
    action();
  } catch (error) {
    thrown = error;
  }
  expect(isFrameError(thrown) ? thrown.code : thrown).toBe(code);
}

/** 中継 → ブラウザの、JSON の本文のフレームを作る（中継の EncodeControl に当たる）。 */
function relayFrame(type: "accepted" | "probe_result" | "ack" | "throttle" | "status" | "fatal", body: unknown): Uint8Array {
  return encodeRawFrame({ type, body: utf8(JSON.stringify(body)) });
}

const START_BODY = {
  profile: "720p",
  video: { codec: "avc1.4D401F", width: 1280, height: 720, framerate: 30, bitrate_kbps: 4500, description_b64: "AU1AH//hAA9nTUAfllQFAe2AoEA8IhEBAARo7jyA" },
  audio: { codec: "mp4a.40.2", sample_rate: 44100, channels: 2, bitrate_kbps: 128, description_b64: "EhA=" },
} as const;

describe("encode: hello（接続チケット）", () => {
  test("本文は、UTF-8 のチケットそのもの（JSON ではない）。時刻 0・属性 0", () => {
    const ticket = "dummy-ticket-0123456789abcdefghijklmnopqrstuvwxyz";
    const raw = decodeRawFrame(codec.encode({ type: "hello", ticket }), "browser_to_relay");
    expect(raw.type).toBe("hello");
    expect(text(raw.body)).toBe(ticket);
    expect(raw.timestampUs).toBe(BigInt(0));
    expect(raw.keyframe).toBe(false);
  });

  test.each([["空", ""], ["空白を含む", "a b"], ["日本語を含む", "チケット"]])("チケットが%sなら invalid_message", (_label, ticket) => {
    expectFrameError(() => codec.encode({ type: "hello", ticket }), "invalid_message");
  });
});

describe("encode: probe（計測データ）", () => {
  test("本文は、渡したバイト列そのもの。32 KB 程度でも、全体が上限以下なら符号化できる", () => {
    const payload = Uint8Array.from({ length: LIMITS.line_probe.message_bytes_hint }, (_, index) => index % 251);
    const encoded = codec.encode({ type: "probe", payload });
    expect(encoded.length).toBe(LIMITS.ws_frame.header_bytes + payload.length);
    const raw = decodeRawFrame(encoded, "browser_to_relay");
    expect(raw.type).toBe("probe");
    expect(Array.from(raw.body)).toEqual(Array.from(payload));
  });

  test("全体が 2,097,152 バイトちょうどまでは符号化でき、1 バイト超えると too_large", () => {
    const limit = LIMITS.ws_frame.max_message_bytes - LIMITS.ws_frame.header_bytes;
    expect(codec.encode({ type: "probe", payload: new Uint8Array(limit) }).length).toBe(LIMITS.ws_frame.max_message_bytes);
    expectFrameError(() => codec.encode({ type: "probe", payload: new Uint8Array(limit + 1) }), "too_large");
  });

  test("本文が Uint8Array でなければ invalid_message", () => {
    expectFrameError(() => codec.encode({ type: "probe", payload: "abc" as unknown as Uint8Array }), "invalid_message");
  });
});

describe("encode: start（開始通知）", () => {
  test("本文は、契約のキーの順の JSON（UTF-8）。時刻 0", () => {
    const raw = decodeRawFrame(codec.encode({ type: "start", body: START_BODY }), "browser_to_relay");
    expect(raw.type).toBe("start");
    expect(text(raw.body)).toBe(JSON.stringify(START_BODY));
    expect(raw.timestampUs).toBe(BigInt(0));
  });

  test("本文長は、文字数ではなく、エンコードしたバイト数", () => {
    const encoded = codec.encode({ type: "start", body: START_BODY });
    const declared = new DataView(encoded.buffer, encoded.byteOffset, encoded.byteLength).getUint32(13);
    expect(declared).toBe(utf8(JSON.stringify(START_BODY)).length);
    expect(encoded.length).toBe(17 + declared);
  });

  test("型にない余計なプロパティを持つ入力でも、余計な項目を送らない（デバイス名・ラベルなどが紛れ込まない）", () => {
    const polluted = { ...START_BODY, deviceLabel: "My Camera", video: { ...START_BODY.video, label: "front" } };
    const raw = decodeRawFrame(codec.encode({ type: "start", body: polluted as never }), "browser_to_relay");
    expect(text(raw.body)).toBe(JSON.stringify(START_BODY));
  });

  test("プロファイルと食い違う（720p なのに幅が 854）開始通知は invalid_body", () => {
    const body = { ...START_BODY, video: { ...START_BODY.video, width: 854 } };
    expectFrameError(() => codec.encode({ type: "start", body: body as never }), "invalid_body");
  });
});

describe("encode: video（映像）", () => {
  const payload = Uint8Array.from([0, 0, 0, 6, 0x65, 0x88, 0x84, 0x00, 0x33, 0xff]);

  test("キーフレームの属性（bit0）と、時刻（マイクロ秒）と、符号化データそのものを載せる", () => {
    const raw = decodeRawFrame(codec.encode({ type: "video", timestampUs: 2_000_000, keyframe: true, payload }), "browser_to_relay");
    expect(raw.type).toBe("video");
    expect(raw.keyframe).toBe(true);
    expect(raw.timestampUs).toBe(BigInt(2_000_000));
    expect(Array.from(raw.body)).toEqual(Array.from(payload));
    const delta = decodeRawFrame(codec.encode({ type: "video", timestampUs: 33_333, keyframe: false, payload }), "browser_to_relay");
    expect(delta.keyframe).toBe(false);
  });

  test("時刻は BigInt でも渡せる。2^53 を超える値も、厳密に符号化する（Number に変換しない）", () => {
    const timestampUs = (BigInt(1) << BigInt(53)) + BigInt(1);
    const raw = decodeRawFrame(codec.encode({ type: "video", timestampUs, keyframe: false, payload }), "browser_to_relay");
    expect(raw.timestampUs).toBe(timestampUs);
  });

  test.each([
    ["Number の 2^53（BigInt で渡す）", Number.MAX_SAFE_INTEGER + 1],
    ["負の数", -1],
    ["小数", 33_333.5],
    ["NaN", Number.NaN],
  ])("時刻が不正（%s）は invalid_message", (_label, timestampUs) => {
    expectFrameError(() => codec.encode({ type: "video", timestampUs, keyframe: false, payload }), "invalid_message");
  });

  test("符号化データが空でも、符号化できる（長さの検査だけ。中身は解釈しない）", () => {
    expect(codec.encode({ type: "video", timestampUs: 0, keyframe: true, payload: new Uint8Array(0) }).length).toBe(17);
  });

  test("keyframe が真偽値でなければ invalid_message", () => {
    expectFrameError(() => codec.encode({ type: "video", timestampUs: 0, keyframe: undefined as unknown as boolean, payload }), "invalid_message");
  });
});

describe("encode: audio（音声）", () => {
  test("属性は 0（音声にキーフレームは無い）。時刻と符号化データを載せる", () => {
    const payload = Uint8Array.from([0x21, 0x10, 0x04, 0x60]);
    const encoded = codec.encode({ type: "audio", timestampUs: 23_220, payload });
    expect(encoded[4]).toBe(0);
    const raw = decodeRawFrame(encoded, "browser_to_relay");
    expect(raw.type).toBe("audio");
    expect(raw.timestampUs).toBe(BigInt(23_220));
    expect(Array.from(raw.body)).toEqual(Array.from(payload));
  });
});

describe("encode: report（状態報告）と end（終了通知）", () => {
  const report = {
    backlog_ms: 1800,
    dropped_video_frames: 12,
    target_kbps: 3000,
    state: "degraded",
    events: [{ kind: "bitrate_down", detail: { from_kbps: 3300, to_kbps: 3000 } }, { kind: "video_dropped", detail: { frames: 12 } }, { kind: "degraded_started" }],
  } as const;

  test("report の本文は、契約のキーの順の JSON。出来事は、1 回ずつ、順に載る", () => {
    const raw = decodeRawFrame(codec.encode({ type: "report", body: report as never }), "browser_to_relay");
    expect(raw.type).toBe("report");
    expect(text(raw.body)).toBe(JSON.stringify(report));
  });

  test("detail に自由記述（デバイス名・ラベル）を載せる report は、送らない（invalid_body）", () => {
    const body = { ...report, events: [{ kind: "source_lost", detail: { source: "Front Camera (USB 0123)" } }] };
    expectFrameError(() => codec.encode({ type: "report", body: body as never }), "invalid_body");
  });

  test("end の本文は、{\"reason\":…}。ブラウザが伝えられる 3 つの理由だけ", () => {
    for (const reason of ["user_stop", "user_cancel", "insufficient_bandwidth"] as const) {
      const raw = decodeRawFrame(codec.encode({ type: "end", body: { reason } }), "browser_to_relay");
      expect(raw.type).toBe("end");
      expect(text(raw.body)).toBe(JSON.stringify({ reason }));
    }
    expectFrameError(() => codec.encode({ type: "end", body: { reason: "time_limit" as never } }), "invalid_body");
  });
});

describe("encode: 呼び出しの誤り", () => {
  test("中継 → ブラウザの種別（accepted など）は、ブラウザが送れない（wrong_direction）", () => {
    for (const type of ["accepted", "probe_result", "ack", "keyframe_request", "throttle", "status", "fatal"]) {
      expectFrameError(() => codec.encode({ type } as unknown as OutboundMessage), "wrong_direction");
    }
  });

  test("未知の種別は unknown_type。メッセージがオブジェクトでなければ invalid_message", () => {
    expectFrameError(() => codec.encode({ type: "nope" } as unknown as OutboundMessage), "unknown_type");
    expectFrameError(() => codec.encode(null as unknown as OutboundMessage), "invalid_message");
    expectFrameError(() => codec.encode("hello" as unknown as OutboundMessage), "invalid_message");
    expectFrameError(() => codec.encode({} as unknown as OutboundMessage), "unknown_type");
  });

  test("encode は、入力を変更しない。呼ぶたびに、新しいバイト列を返す", () => {
    const payload = Uint8Array.from([1, 2, 3]);
    const message: OutboundMessage = { type: "audio", timestampUs: 1, payload };
    const first = codec.encode(message);
    const second = codec.encode(message);
    expect(first).not.toBe(second);
    expect(Array.from(first)).toEqual(Array.from(second));
    first[17] = 99;
    expect(Array.from(payload)).toEqual([1, 2, 3]);
    expect(second[17]).toBe(1);
  });
});

describe("decode: 中継 → ブラウザの 7 種", () => {
  test("accepted（接続受理）", () => {
    const body = { state: "reserved", resume: false, profile: null, limits: { time_limit_seconds: 3600 } };
    expect(codec.decode(relayFrame("accepted", body))).toEqual({ type: "accepted", body });
  });

  test("probe_result（計測結果）", () => {
    expect(codec.decode(relayFrame("probe_result", { throughput_kbps: 5200 }))).toEqual({ type: "probe_result", body: { throughput_kbps: 5200 } });
  });

  test("ack（受領応答）", () => {
    expect(codec.decode(relayFrame("ack", { video_us: 33_333, audio_us: 23_220 }))).toEqual({ type: "ack", body: { video_us: 33_333, audio_us: 23_220 } });
  });

  test("keyframe_request（本文は空）は、本文を持たない", () => {
    const message = codec.decode(encodeRawFrame({ type: "keyframe_request", body: new Uint8Array(0) }));
    expect(message).toEqual({ type: "keyframe_request" });
    expect("body" in message).toBe(false);
  });

  test("keyframe_request の本文が空でなければ invalid_body（契約は、本文長 0）", () => {
    expectFrameError(() => codec.decode(encodeRawFrame({ type: "keyframe_request", body: Uint8Array.from([0]) })), "invalid_body");
  });

  test("throttle（抑制指示）", () => {
    expect(codec.decode(relayFrame("throttle", { target_kbps: 3150 }))).toEqual({ type: "throttle", body: { target_kbps: 3150 } });
  });

  test("status（状態通知）：null の項目を含む、状態の全体", () => {
    const body = { state: "live", watch_url: "https://www.youtube.com/watch?v=dummyVideoId", warning: null, time_limit_notice_seconds: 300, end_reason: null };
    expect(codec.decode(relayFrame("status", body))).toEqual({ type: "status", body });
  });

  test("fatal（致命通知）", () => {
    expect(codec.decode(relayFrame("fatal", { code: "stale_epoch" }))).toEqual({ type: "fatal", body: { code: "stale_epoch" } });
  });

  test("未知のキー（x_ で始まるものを含む）は無視し、結果に含めない", () => {
    const message = codec.decode(relayFrame("ack", { video_us: 1, audio_us: 2, x_trace: "t", extra: { nested: true } }));
    expect(JSON.stringify(message)).toBe('{"type":"ack","body":{"video_us":1,"audio_us":2}}');
  });

  test("制御メッセージのヘッダの属性・時刻は、読まない（0 でなくても復号できる）", () => {
    const frame = encodeRawFrame({ type: "ack", keyframe: true, timestampUs: 12_345, body: utf8('{"video_us":1,"audio_us":2}') });
    expect(codec.decode(frame)).toEqual({ type: "ack", body: { video_us: 1, audio_us: 2 } });
  });
});

describe("decode: 入力の形", () => {
  const frame = relayFrame("probe_result", { throughput_kbps: 4100 });
  const expected = { type: "probe_result", body: { throughput_kbps: 4100 } };

  test("Uint8Array・ArrayBuffer・Node の Buffer・ビュー（byteOffset がある）・DataView を受け取る", () => {
    expect(codec.decode(frame)).toEqual(expected);
    const arrayBuffer = new ArrayBuffer(frame.length);
    new Uint8Array(arrayBuffer).set(frame);
    expect(codec.decode(arrayBuffer)).toEqual(expected);
    expect(codec.decode(Buffer.from(frame))).toEqual(expected);
    const backing = new Uint8Array(frame.length + 8);
    backing.set(frame, 5);
    expect(codec.decode(backing.subarray(5, 5 + frame.length))).toEqual(expected);
    expect(codec.decode(new DataView(backing.buffer, 5, frame.length))).toEqual(expected);
  });

  test.each([
    ["文字列（テキストのメッセージ）", '{"throughput_kbps":1}'],
    ["null", null],
    ["undefined", undefined],
    ["数値", 17],
    ["配列", [66, 76]],
    ["オブジェクト", {}],
  ])("バイナリでない入力（%s）は invalid_message", (_label, input) => {
    expectFrameError(() => codec.decode(input as unknown as Uint8Array), "invalid_message");
  });

  test("入力を変更しない", () => {
    const copy = Uint8Array.from(frame);
    codec.decode(copy);
    expect(Array.from(copy)).toEqual(Array.from(frame));
  });
});

describe("decode: ヘッダの検証（ws-protocol.md の 4 章の順）は、FrameError の符号で返る", () => {
  const good = relayFrame("fatal", { code: "stale_epoch" });
  const cases: ReadonlyArray<readonly [string, Uint8Array, FrameErrorCode]> = [
    ["切り詰め", good.subarray(0, 16), "truncated_header"],
    ["識別子の誤り", good.map((value, index) => (index === 0 ? 0 : value)), "invalid_magic"],
    ["版の誤り", good.map((value, index) => (index === 2 ? 2 : value)), "unsupported_version"],
    ["未知の種別", good.map((value, index) => (index === 3 ? 0xfe : value)), "unknown_type"],
    ["方向違い（ブラウザ → 中継の種別）", encodeRawFrame({ type: "video", body: new Uint8Array(0) }), "wrong_direction"],
    ["長さの不一致（本文が足りない）", good.subarray(0, good.length - 1), "length_mismatch"],
    ["長さの不一致（本文が多い）", Uint8Array.from([...good, 0]), "length_mismatch"],
    ["2 MB 超（宣言）", Uint8Array.from([...good.subarray(0, 13), 0xff, 0xff, 0xff, 0xff]), "too_large"],
  ];

  test.each(cases)("%s -> %s", (_label, message, code) => {
    expectFrameError(() => codec.decode(message), code);
  });
});

describe("decode: 本文（JSON）の不備は、invalid_body（そのメッセージを破棄する。値を、エラーに含めない）", () => {
  const frameOf = (body: Uint8Array): Uint8Array => encodeRawFrame({ type: "status", body });

  test.each([
    ["JSON でない", utf8("{not json")],
    ["空の本文", new Uint8Array(0)],
    ["UTF-8 として不正なバイト", Uint8Array.from([0x7b, 0xff, 0xfe, 0x7d])],
    ["BOM 付き", Uint8Array.from([0xef, 0xbb, 0xbf, ...utf8('{"state":"live"}')])],
    ["オブジェクトでない（配列）", utf8("[]")],
    ["オブジェクトでない（文字列）", utf8('"live"')],
    ["オブジェクトでない（数値）", utf8("1")],
    ["オブジェクトでない（null）", utf8("null")],
    ["必須の項目が無い", utf8('{"state":"live"}')],
    ["列挙の値でない", utf8('{"state":"idle","watch_url":null,"warning":null,"time_limit_notice_seconds":null,"end_reason":null}')],
    ["ひどく深い入れ子", utf8(`${"[".repeat(100_000)}${"]".repeat(100_000)}`)],
  ])("%s", (_label, body) => {
    expectFrameError(() => codec.decode(frameOf(body)), "invalid_body");
  });

  test("エラーの詳細・メッセージに、本文の中身（視聴 URL など）を含めない", () => {
    const body = utf8('{"state":"live","watch_url":12345,"warning":null,"time_limit_notice_seconds":null,"end_reason":"https://secret.example/abc"}');
    try {
      codec.decode(frameOf(body));
      throw new Error("expected a failure");
    } catch (error) {
      expect(isFrameError(error) && error.code).toBe("invalid_body");
      expect(String((error as Error).message)).not.toContain("secret.example");
    }
  });
});

describe("decode: 日本語を含む本文は、バイト数で長さを数える（5.5）", () => {
  test("未知のキーに多バイト文字がある本文でも、復号できる（未知のキーは無視する）", () => {
    const body = { video_us: 1, audio_us: 2, x_note: `${String.fromCodePoint(0x65e5)}${String.fromCodePoint(0x672c)}${String.fromCodePoint(0x8a9e)}` };
    const frame = relayFrame("ack", body);
    const declared = new DataView(frame.buffer, frame.byteOffset, frame.byteLength).getUint32(13);
    expect(declared).toBe(utf8(JSON.stringify(body)).length);
    expect(declared).toBeGreaterThan(JSON.stringify(body).length);
    expect(codec.decode(frame)).toEqual({ type: "ack", body: { video_us: 1, audio_us: 2 } });
  });
});
