/**
 * @jest-environment node
 */
// 受信の堅牢性：どんなバイト列を受けても、FrameCodec.decode は、型付きのメッセージを返すか、FrameError を投げるかのどちらかで、
// それ以外の例外（TypeError・RangeError など）を投げず、結果が不定にならない（接続を維持して、そのメッセージだけを破棄できる。4.1）。
// 入力は、決定的な乱数による、ランダムなバイト列・正しいフレームの 1 バイトの書き換え・あらゆる長さへの切り詰め。
import { Problems, seededRandom } from "../testing/helpers";
import { FrameCodec } from "./FrameCodec";
import { isFrameError } from "./errors";
import { encodeRawFrame } from "./frameLayout";

const codec = new FrameCodec();

function utf8(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}

/** 正しい、中継 → ブラウザのフレームの見本（7 種）。 */
const SAMPLES: ReadonlyArray<readonly [string, Uint8Array]> = [
  ["accepted", encodeRawFrame({ type: "accepted", body: utf8('{"state":"live","resume":true,"profile":"720p","limits":{"time_limit_seconds":3600}}') })],
  ["probe_result", encodeRawFrame({ type: "probe_result", body: utf8('{"throughput_kbps":5200}') })],
  ["ack", encodeRawFrame({ type: "ack", body: utf8('{"video_us":33333,"audio_us":23220}') })],
  ["keyframe_request", encodeRawFrame({ type: "keyframe_request", body: new Uint8Array(0) })],
  ["throttle", encodeRawFrame({ type: "throttle", body: utf8('{"target_kbps":3150}') })],
  ["status", encodeRawFrame({ type: "status", body: utf8('{"state":"live","watch_url":"https://www.youtube.com/watch?v=dummyVideoId","warning":null,"time_limit_notice_seconds":300,"end_reason":null}') })],
  ["fatal", encodeRawFrame({ type: "fatal", body: utf8('{"code":"stale_epoch"}') })],
];

/** decode の結果が、型付きのメッセージか、FrameError か。それ以外は、不具合の説明を返す。 */
function classify(message: Uint8Array): string | undefined {
  try {
    const decoded = codec.decode(message);
    return typeof decoded.type === "string" ? undefined : "decoded message has no type";
  } catch (error) {
    return isFrameError(error) ? undefined : `unexpected exception: ${String(error)}`;
  }
}

describe("decode は、型付きのメッセージか FrameError のどちらかだけを返す", () => {
  test("見本の 7 種は、そのまま復号できる（検査の土台）", () => {
    for (const [, frame] of SAMPLES) {
      expect(classify(frame)).toBeUndefined();
      expect(() => codec.decode(frame)).not.toThrow();
    }
  });

  test("あらゆる長さへの切り詰め（0 バイトから、全長 - 1 まで）", () => {
    const problems = new Problems();
    for (const [name, frame] of SAMPLES) {
      for (let length = 0; length < frame.length; length += 1) {
        const problem = classify(frame.subarray(0, length));
        if (problem !== undefined) {
          problems.report(`${name} truncated to ${length}: ${problem}`);
        }
        let threw = false;
        try {
          codec.decode(frame.subarray(0, length));
        } catch {
          threw = true;
        }
        if (!threw) {
          problems.report(`${name} truncated to ${length} was accepted`);
        }
      }
    }
    expect(problems.list()).toEqual([]);
  });

  test("全長より長いバイト列（末尾に 1 バイト以上を足す）は、length_mismatch で拒否される", () => {
    const problems = new Problems();
    for (const [name, frame] of SAMPLES) {
      for (const extra of [1, 2, 17, 4096]) {
        try {
          codec.decode(Uint8Array.from([...frame, ...new Uint8Array(extra)]));
          problems.report(`${name} + ${extra} bytes was accepted`);
        } catch (error) {
          if (!isFrameError(error) || error.code !== "length_mismatch") {
            problems.report(`${name} + ${extra} bytes: ${String(error)}`);
          }
        }
      }
    }
    expect(problems.list()).toEqual([]);
  });

  test("正しいフレームの、1 バイトの書き換え（全位置 × 8 通りの値）", () => {
    const problems = new Problems();
    const values = [0x00, 0x01, 0x7f, 0x80, 0xc0, 0xe0, 0xf5, 0xff];
    for (const [name, frame] of SAMPLES) {
      for (let position = 0; position < frame.length; position += 1) {
        for (const value of values) {
          const mutated = Uint8Array.from(frame);
          mutated[position] = value;
          const problem = classify(mutated);
          if (problem !== undefined) {
            problems.report(`${name} byte ${position} = ${value}: ${problem}`);
          }
        }
      }
    }
    expect(problems.list()).toEqual([]);
  });

  test("ランダムなバイト列（長さ 0 から 200。2,000 通り）", () => {
    const random = seededRandom(2025);
    const problems = new Problems();
    for (let round = 0; round < 2_000; round += 1) {
      const bytes = Uint8Array.from({ length: Math.floor(random() * 201) }, () => Math.floor(random() * 256));
      const problem = classify(bytes);
      if (problem !== undefined) {
        problems.report(`round ${round} (${bytes.length} bytes): ${problem}`);
      }
    }
    expect(problems.list()).toEqual([]);
  });

  test("正しいヘッダ（識別子・版・種別）に、ランダムな本文（長さを合わせる）。JSON として不正でも、FrameError だけ", () => {
    const random = seededRandom(7);
    const problems = new Problems();
    const types = ["accepted", "probe_result", "ack", "keyframe_request", "throttle", "status", "fatal"] as const;
    for (let round = 0; round < 2_000; round += 1) {
      const type = types[Math.floor(random() * types.length)];
      const body = Uint8Array.from({ length: Math.floor(random() * 60) }, () => Math.floor(random() * 256));
      const problem = classify(encodeRawFrame({ type, body }));
      if (problem !== undefined) {
        problems.report(`round ${round} ${type}: ${problem}`);
      }
    }
    expect(problems.list()).toEqual([]);
  });

  test("JSON として正しいが、型が不正な本文（項目の型を、すべて入れ替える）。FrameError だけ", () => {
    const problems = new Problems();
    const wrongValues: unknown[] = [null, true, false, 0, -1, 1.5, "x", "", [], {}, [1], { a: 1 }, 1e308, -1e308];
    const templates: ReadonlyArray<readonly [string, Record<string, unknown>]> = [
      ["accepted", { state: "live", resume: false, profile: null, limits: { time_limit_seconds: 1 } }],
      ["probe_result", { throughput_kbps: 1 }],
      ["ack", { video_us: 1, audio_us: 1 }],
      ["throttle", { target_kbps: 1 }],
      ["status", { state: "live", watch_url: null, warning: null, time_limit_notice_seconds: null, end_reason: null }],
      ["fatal", { code: "internal_error" }],
    ];
    for (const [type, template] of templates) {
      for (const key of Object.keys(template)) {
        for (const wrong of wrongValues) {
          const body = utf8(JSON.stringify({ ...template, [key]: wrong }));
          const problem = classify(encodeRawFrame({ type: type as "ack", body }));
          if (problem !== undefined) {
            problems.report(`${type}.${key} = ${JSON.stringify(wrong)}: ${problem}`);
          }
        }
      }
    }
    expect(problems.list()).toEqual([]);
  });
});
