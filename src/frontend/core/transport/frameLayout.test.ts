/**
 * @jest-environment node
 */
// フレームの構造（ws-protocol.md の 2 章・4 章、requirements.md 11.9）：ヘッダ 17 バイト（識別子 2・版 1・種別 1・属性 1・時刻 8・本文長 4。
// ビッグエンディアン）と本文。符号化・復号・検証の順。方向は、受信側が受理する方向を引数で受け取る（中継は browser_to_relay、ブラウザは
// relay_to_browser。中継の Go の decodeFor と同じ作り）。
// 数値（符号・欄の位置・上限）は、実装と独立に、契約の文書から書き下している。64 ビットの時刻は BigInt で、境界（2^32-1・2^32・2^53-1・2^53・
// 2^53+1・2^63・2^64-1）を検査する。BigInt のリテラル（1n）は使わない（tsconfig の target が ES2017 のため、型検査で失敗する）。
import { Problems, seededRandom } from "../testing/helpers";
import { isFrameError } from "./errors";
import type { FrameErrorCode } from "./errors";
import { decodeRawFrame, encodeRawFrame } from "./frameLayout";
import type { FrameDirection, RawFrame } from "./frameLayout";

const BROWSER_TO_RELAY: FrameDirection = "browser_to_relay";
const RELAY_TO_BROWSER: FrameDirection = "relay_to_browser";

/** 契約（ws-protocol.md の 3 章）の、14 種の種別の符号と方向。実装の表とは独立に書く。 */
const TYPE_TABLE: ReadonlyArray<readonly [RawFrame["type"], number, FrameDirection]> = [
  ["hello", 0x01, BROWSER_TO_RELAY],
  ["probe", 0x02, BROWSER_TO_RELAY],
  ["start", 0x03, BROWSER_TO_RELAY],
  ["video", 0x04, BROWSER_TO_RELAY],
  ["audio", 0x05, BROWSER_TO_RELAY],
  ["report", 0x06, BROWSER_TO_RELAY],
  ["end", 0x07, BROWSER_TO_RELAY],
  ["accepted", 0x81, RELAY_TO_BROWSER],
  ["probe_result", 0x82, RELAY_TO_BROWSER],
  ["ack", 0x83, RELAY_TO_BROWSER],
  ["keyframe_request", 0x84, RELAY_TO_BROWSER],
  ["throttle", 0x85, RELAY_TO_BROWSER],
  ["status", 0x86, RELAY_TO_BROWSER],
  ["fatal", 0x87, RELAY_TO_BROWSER],
];

const MAX_MESSAGE_BYTES = 2_097_152;
const HEADER_BYTES = 17;

const ZERO = BigInt(0);
const ONE = BigInt(1);
const TWO_POW_32 = ONE << BigInt(32);
const TWO_POW_53 = ONE << BigInt(53);
const TWO_POW_63 = ONE << BigInt(63);
const TWO_POW_64 = ONE << BigInt(64);

/** 64 ビットの符号なし整数を、ビッグエンディアンの 8 バイトにする（実装の DataView に頼らず、シフトで分ける）。 */
function bigEndian64(value: bigint): number[] {
  return Array.from({ length: 8 }, (_, index) => Number((value >> BigInt(8 * (7 - index))) & BigInt(255)));
}

function bigEndian32(value: number): number[] {
  return [(value >>> 24) & 255, (value >>> 16) & 255, (value >>> 8) & 255, value & 255];
}

/** 検証を通さずに、17 バイトのヘッダを組み立てる。 */
function rawHeader(magic0: number, magic1: number, version: number, type: number, attributes: number, timestamp: bigint, declaredBodyBytes: number): Uint8Array {
  return Uint8Array.from([magic0, magic1, version, type, attributes, ...bigEndian64(timestamp), ...bigEndian32(declaredBodyBytes)]);
}

/** 正しい識別子・版のヘッダと、本文からなるメッセージ。 */
function rawMessage(type: number, attributes: number, timestamp: bigint, body: Uint8Array): Uint8Array {
  return Uint8Array.from([...rawHeader(0x42, 0x4c, 1, type, attributes, timestamp, body.length), ...body]);
}

function bodyOf(...values: number[]): Uint8Array {
  return Uint8Array.from(values);
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

describe("encodeRawFrame: ヘッダの構造", () => {
  test("識別子 0x42 0x4C・版 1・種別・属性・時刻 8 バイト・本文長 4 バイト（ビッグエンディアン）・本文の順", () => {
    // 時刻は、Number では厳密に書けない値なので、文字列から BigInt にする
    const encoded = encodeRawFrame({ type: "video", keyframe: true, timestampUs: BigInt("0x0102030405060708"), body: bodyOf(0xaa, 0xbb, 0xcc) });
    expect(Array.from(encoded)).toEqual([
      0x42, 0x4c, 0x01, 0x04, 0x01,
      0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
      0x00, 0x00, 0x00, 0x03,
      0xaa, 0xbb, 0xcc,
    ]);
    expect(encoded.length).toBe(HEADER_BYTES + 3);
  });

  test("全体の長さは、ヘッダ 17 バイト + 本文", () => {
    for (const bodyLength of [0, 1, 255, 256, 65_535, 65_536]) {
      const encoded = encodeRawFrame({ type: "probe", body: new Uint8Array(bodyLength) });
      expect(encoded.length).toBe(HEADER_BYTES + bodyLength);
    }
  });

  test.each([
    [0, [0, 0, 0, 0]],
    [1, [0, 0, 0, 1]],
    [255, [0, 0, 0, 255]],
    [256, [0, 0, 1, 0]],
    [65_536, [0, 1, 0, 0]],
    [2_097_135, [0, 0x1f, 0xff, 0xef]],
  ])("本文 %i バイトの、本文長の欄は %j（4 バイト・ビッグエンディアン）", (bodyLength, expectedField) => {
    const encoded = encodeRawFrame({ type: "probe", body: new Uint8Array(bodyLength) });
    expect(Array.from(encoded.subarray(13, 17))).toEqual(expectedField);
  });

  test.each(TYPE_TABLE)("種別 %s の符号は %i（10 進数。方向 %s）", (name, code) => {
    const encoded = encodeRawFrame({ type: name, timestampUs: 0, body: new Uint8Array(0) });
    expect(encoded[3]).toBe(code);
  });

  test("属性：bit0 がキーフレーム。予約のビット（bit1 から bit7）は 0（送信側は 0 にする）", () => {
    expect(encodeRawFrame({ type: "video", keyframe: true, timestampUs: 0, body: new Uint8Array(0) })[4]).toBe(0x01);
    expect(encodeRawFrame({ type: "video", keyframe: false, timestampUs: 0, body: new Uint8Array(0) })[4]).toBe(0x00);
    expect(encodeRawFrame({ type: "video", timestampUs: 0, body: new Uint8Array(0) })[4]).toBe(0x00);
  });

  test.each([
    ["0", ZERO, "0000000000000000"],
    ["2^32 - 1", TWO_POW_32 - ONE, "00000000ffffffff"],
    ["2^32", TWO_POW_32, "0000000100000000"],
    ["2^53 - 1", TWO_POW_53 - ONE, "001fffffffffffff"],
    ["2^53", TWO_POW_53, "0020000000000000"],
    ["2^53 + 1", TWO_POW_53 + ONE, "0020000000000001"],
    ["2^63", TWO_POW_63, "8000000000000000"],
    ["2^64 - 1", TWO_POW_64 - ONE, "ffffffffffffffff"],
  ])("時刻の境界 %s は、8 バイトのビッグエンディアン %s（Number に変換せず、BigInt で厳密に）", (_label, timestamp, expectedHex) => {
    const encoded = encodeRawFrame({ type: "audio", timestampUs: timestamp, body: new Uint8Array(0) });
    expect(Buffer.from(encoded.subarray(5, 13)).toString("hex")).toBe(expectedHex);
  });

  test("制御メッセージ（映像・音声以外の 12 種）は、時刻を省くと 0（ヘッダの時刻の欄は 0）", () => {
    const controlTypes = ["hello", "probe", "start", "report", "end", "accepted", "probe_result", "ack", "keyframe_request", "throttle", "status", "fatal"] as const;
    for (const type of controlTypes) {
      expect(Array.from(encodeRawFrame({ type, body: new Uint8Array(0) }).subarray(5, 13))).toEqual([0, 0, 0, 0, 0, 0, 0, 0]);
    }
  });

  test("時刻は、Number（安全整数）でも渡せる", () => {
    expect(Array.from(encodeRawFrame({ type: "hello", body: new Uint8Array(0) }).subarray(5, 13))).toEqual([0, 0, 0, 0, 0, 0, 0, 0]);
    expect(Buffer.from(encodeRawFrame({ type: "audio", timestampUs: 33_333, body: new Uint8Array(0) }).subarray(5, 13)).toString("hex")).toBe("0000000000008235");
    expect(Buffer.from(encodeRawFrame({ type: "audio", timestampUs: Number.MAX_SAFE_INTEGER, body: new Uint8Array(0) }).subarray(5, 13)).toString("hex")).toBe("001fffffffffffff");
  });
});

describe("encodeRawFrame: 拒否（黙って切り詰めたり、丸めたりしない）", () => {
  test.each([
    ["2^53（Number では 2^53 + 1 と区別できない）", Number.MAX_SAFE_INTEGER + 1],
    ["負の数", -1],
    ["小数", 1.5],
    ["NaN", Number.NaN],
    ["無限大", Number.POSITIVE_INFINITY],
    ["負の BigInt", BigInt(-1)],
    ["2^64（64 ビットに収まらない最小の値）", TWO_POW_64],
    ["文字列", "1" as unknown as number],
  ])("時刻が不正（%s）は invalid_message", (_label, timestamp) => {
    expectFrameError(() => encodeRawFrame({ type: "audio", timestampUs: timestamp, body: new Uint8Array(0) }), "invalid_message");
  });

  test.each(["video", "audio"] as const)(
    "%s は、時刻を省く（undefined・null も）と invalid_message（黙って 0 にしない。中継の TimeGuard は、2 枚目以降を時刻の逆行として破棄し、ブラウザには何も見えないため）",
    (type) => {
      expectFrameError(() => encodeRawFrame({ type, body: new Uint8Array(0) } as never), "invalid_message");
      expectFrameError(() => encodeRawFrame({ type, timestampUs: undefined, body: new Uint8Array(0) } as never), "invalid_message");
      expectFrameError(() => encodeRawFrame({ type, timestampUs: null, body: new Uint8Array(0) } as never), "invalid_message");
    },
  );

  test("型の上でも、映像・音声は時刻が必須（省いた呼び出しは、tsc で拒否される。ここは、その検査が働いていることの確認）", () => {
    // @ts-expect-error 映像には timestampUs が要る（省くと型検査で失敗する）
    const omittedVideo: Parameters<typeof encodeRawFrame>[0] = { type: "video", body: new Uint8Array(0) };
    // @ts-expect-error 音声にも timestampUs が要る
    const omittedAudio: Parameters<typeof encodeRawFrame>[0] = { type: "audio", body: new Uint8Array(0) };
    expect([omittedVideo.type, omittedAudio.type]).toEqual(["video", "audio"]);
  });

  test("全体がちょうど 2,097,152 バイト（本文 2,097,135 バイト）は符号化できる。1 バイト超えると too_large", () => {
    expect(encodeRawFrame({ type: "probe", body: new Uint8Array(MAX_MESSAGE_BYTES - HEADER_BYTES) }).length).toBe(MAX_MESSAGE_BYTES);
    expectFrameError(() => encodeRawFrame({ type: "probe", body: new Uint8Array(MAX_MESSAGE_BYTES - HEADER_BYTES + 1) }), "too_large");
  });

  test.each([
    ["未知の名前", "nope"],
    ["空", ""],
    ["大文字の名前", "HELLO"],
    ["undefined", undefined],
  ])("未知の種別（%s）は unknown_type", (_label, type) => {
    expectFrameError(() => encodeRawFrame({ type: type as never, body: new Uint8Array(0) }), "unknown_type");
  });

  test.each([
    ["配列", [1, 2, 3]],
    ["文字列", "abc"],
    ["null", null],
    ["undefined", undefined],
    ["ArrayBuffer（ビューでない）", new ArrayBuffer(3)],
    ["Uint16Array（Uint8Array でない）", new Uint16Array(2)],
  ])("本文が Uint8Array でない（%s）は invalid_message", (_label, body) => {
    expectFrameError(() => encodeRawFrame({ type: "probe", body: body as unknown as Uint8Array }), "invalid_message");
  });

  test("キーフレームの指定が真偽値でない場合は invalid_message", () => {
    expectFrameError(() => encodeRawFrame({ type: "video", keyframe: 1 as unknown as boolean, timestampUs: 0, body: new Uint8Array(0) }), "invalid_message");
  });

  test("エラーの詳細に、本文の中身を含めない（接続チケットなどが入り得る）", () => {
    try {
      encodeRawFrame({ type: "hello", timestampUs: -1, body: bodyOf(0x73, 0x65, 0x63, 0x72, 0x65, 0x74) });
    } catch (error) {
      expect(isFrameError(error) && error.message.includes("secret")).toBe(false);
    }
  });
});

describe("encodeRawFrame: 本文のコピー", () => {
  test("符号化の結果は新しい領域。結果を書き換えても本文は変わらず、本文を書き換えても結果は変わらない", () => {
    const body = bodyOf(1, 2, 3);
    const encoded = encodeRawFrame({ type: "probe", body });
    encoded[HEADER_BYTES] = 99;
    expect(Array.from(body)).toEqual([1, 2, 3]);
    body[1] = 77;
    expect(encoded[HEADER_BYTES + 1]).toBe(2);
  });

  test("本文が、より大きなバッファの一部のビュー（byteOffset がある）でも、ビューの範囲だけを符号化する", () => {
    const backing = bodyOf(9, 9, 1, 2, 3, 9);
    const encoded = encodeRawFrame({ type: "probe", body: backing.subarray(2, 5) });
    expect(Array.from(encoded.subarray(HEADER_BYTES))).toEqual([1, 2, 3]);
    expect(Array.from(encoded.subarray(13, 17))).toEqual([0, 0, 0, 3]);
  });
});

describe("decodeRawFrame: 正しいフレーム", () => {
  test.each(TYPE_TABLE)("種別 %s（符号 %i）は、方向 %s の受信側で復号できる", (name, code, direction) => {
    const body = bodyOf(1, 2, 3);
    const decoded = decodeRawFrame(rawMessage(code, 0, ZERO, body), direction);
    expect(decoded.type).toBe(name);
    expect(decoded.keyframe).toBe(false);
    expect(decoded.timestampUs).toBe(ZERO);
    expect(Array.from(decoded.body)).toEqual([1, 2, 3]);
  });

  test.each(TYPE_TABLE)("種別 %s は、反対の方向の受信側では wrong_direction", (_name, code, direction) => {
    const opposite = direction === BROWSER_TO_RELAY ? RELAY_TO_BROWSER : BROWSER_TO_RELAY;
    expectFrameError(() => decodeRawFrame(rawMessage(code, 0, ZERO, bodyOf(1)), opposite), "wrong_direction");
  });

  test.each([
    ["0", ZERO],
    ["2^32 - 1", TWO_POW_32 - ONE],
    ["2^32", TWO_POW_32],
    ["2^53 - 1", TWO_POW_53 - ONE],
    ["2^53", TWO_POW_53],
    ["2^53 + 1", TWO_POW_53 + ONE],
    ["2^63", TWO_POW_63],
    ["2^64 - 1", TWO_POW_64 - ONE],
  ])("時刻の境界 %s を、BigInt で厳密に復号する（丸めない）", (_label, timestamp) => {
    const decoded = decodeRawFrame(rawMessage(0x04, 0, timestamp, bodyOf(1)), BROWSER_TO_RELAY);
    expect(typeof decoded.timestampUs).toBe("bigint");
    expect(decoded.timestampUs).toBe(timestamp);
  });

  test("属性：bit0 だけがキーフレーム。予約のビット（bit1 から bit7）は、検査せず無視する", () => {
    const attributeTable: ReadonlyArray<readonly [number, boolean]> = [
      [0x00, false],
      [0x01, true],
      [0x02, false],
      [0xfe, false],
      [0xff, true],
      [0x81, true],
    ];
    for (const [attributes, keyframe] of attributeTable) {
      expect(decodeRawFrame(rawMessage(0x04, attributes, ZERO, bodyOf(1)), BROWSER_TO_RELAY).keyframe).toBe(keyframe);
    }
  });

  test("本文が空（本文長 0）の、ヘッダだけのフレーム（キーフレーム要求）を復号できる", () => {
    const decoded = decodeRawFrame(rawMessage(0x84, 0, ZERO, new Uint8Array(0)), RELAY_TO_BROWSER);
    expect(decoded.type).toBe("keyframe_request");
    expect(decoded.body.length).toBe(0);
  });

  test("全体がちょうど 2,097,152 バイトのフレームは、復号できる", () => {
    const message = rawMessage(0x04, 0, ZERO, new Uint8Array(MAX_MESSAGE_BYTES - HEADER_BYTES));
    expect(message.length).toBe(MAX_MESSAGE_BYTES);
    expect(decodeRawFrame(message, BROWSER_TO_RELAY).body.length).toBe(MAX_MESSAGE_BYTES - HEADER_BYTES);
  });

  test("本文は、メッセージのバッファのビュー（コピーしない）。メッセージ自体が部分ビュー（byteOffset がある）でも、正しく読む", () => {
    const frame = rawMessage(0x05, 0, BigInt(23_220), bodyOf(7, 8, 9));
    const backing = new Uint8Array(frame.length + 6);
    backing.set(frame, 4);
    const view = backing.subarray(4, 4 + frame.length);
    const decoded = decodeRawFrame(view, BROWSER_TO_RELAY);
    expect(decoded.timestampUs).toBe(BigInt(23_220));
    expect(Array.from(decoded.body)).toEqual([7, 8, 9]);
    expect(decoded.body.buffer).toBe(backing.buffer);
    expect(decoded.body.byteOffset).toBe(4 + HEADER_BYTES);
  });

  test("復号は、入力を変更しない", () => {
    const message = rawMessage(0x04, 1, TWO_POW_53, bodyOf(1, 2, 3, 4));
    const before = Array.from(message);
    decodeRawFrame(message, BROWSER_TO_RELAY);
    expect(Array.from(message)).toEqual(before);
  });
});

describe("decodeRawFrame: 検証の順（最初に該当した誤りを返す。ws-protocol.md の 4 章）", () => {
  const goodBody = bodyOf(1, 2, 3);
  // [名前, 入力, 受信側が受理する方向, 期待する符号]
  const cases: ReadonlyArray<readonly [string, Uint8Array, FrameDirection, FrameErrorCode]> = [
    ["1. 空のメッセージ", new Uint8Array(0), BROWSER_TO_RELAY, "truncated_header"],
    ["1. 1 バイト", bodyOf(0x42), BROWSER_TO_RELAY, "truncated_header"],
    ["1. 識別子の 2 バイトだけ", bodyOf(0x42, 0x4c), RELAY_TO_BROWSER, "truncated_header"],
    ["1. 16 バイト（ヘッダの 1 バイト手前）", rawHeader(0x42, 0x4c, 1, 0x04, 0, ZERO, 0).subarray(0, 16), BROWSER_TO_RELAY, "truncated_header"],
    ["2. 識別子の 1 バイト目が違う", rawMessage(0x04, 0, ZERO, goodBody).map((value, index) => (index === 0 ? 0x43 : value)), BROWSER_TO_RELAY, "invalid_magic"],
    ["2. 識別子の 2 バイト目が違う", rawMessage(0x04, 0, ZERO, goodBody).map((value, index) => (index === 1 ? 0x4d : value)), BROWSER_TO_RELAY, "invalid_magic"],
    ["2. 識別子の順が逆", Uint8Array.from([...rawHeader(0x4c, 0x42, 1, 0x04, 0, ZERO, 3), ...goodBody]), BROWSER_TO_RELAY, "invalid_magic"],
    ["2. ヘッダのすべてが 0", new Uint8Array(HEADER_BYTES), BROWSER_TO_RELAY, "invalid_magic"],
    ["3. 版 0", Uint8Array.from([...rawHeader(0x42, 0x4c, 0, 0x04, 0, ZERO, 3), ...goodBody]), BROWSER_TO_RELAY, "unsupported_version"],
    ["3. 版 2（未来の版）", Uint8Array.from([...rawHeader(0x42, 0x4c, 2, 0x04, 0, ZERO, 3), ...goodBody]), BROWSER_TO_RELAY, "unsupported_version"],
    ["3. 版 255", Uint8Array.from([...rawHeader(0x42, 0x4c, 255, 0x04, 0, ZERO, 3), ...goodBody]), BROWSER_TO_RELAY, "unsupported_version"],
    ["4. 種別 0x00", rawHeader(0x42, 0x4c, 1, 0x00, 0, ZERO, 0), BROWSER_TO_RELAY, "unknown_type"],
    ["4. 種別 0x08（ブラウザ → 中継の次）", rawHeader(0x42, 0x4c, 1, 0x08, 0, ZERO, 0), BROWSER_TO_RELAY, "unknown_type"],
    ["4. 種別 0x80（中継 → ブラウザの前）", rawHeader(0x42, 0x4c, 1, 0x80, 0, ZERO, 0), RELAY_TO_BROWSER, "unknown_type"],
    ["4. 種別 0x88（中継 → ブラウザの次）", rawHeader(0x42, 0x4c, 1, 0x88, 0, ZERO, 0), RELAY_TO_BROWSER, "unknown_type"],
    ["4. 種別 0xFF", rawHeader(0x42, 0x4c, 1, 0xff, 0, ZERO, 0), RELAY_TO_BROWSER, "unknown_type"],
    ["5. 中継が、中継 → ブラウザの種別（accepted）を受けた", rawMessage(0x81, 0, ZERO, goodBody), BROWSER_TO_RELAY, "wrong_direction"],
    ["5. ブラウザが、ブラウザ → 中継の種別（hello）を受けた", rawMessage(0x01, 0, ZERO, goodBody), RELAY_TO_BROWSER, "wrong_direction"],
    ["6. 宣言が上限を 1 バイト超える（本文長 2,097,136）。ヘッダだけ", rawHeader(0x42, 0x4c, 1, 0x04, 0, ZERO, 2_097_136), BROWSER_TO_RELAY, "too_large"],
    ["6. 本文長が符号なし 32 ビットの最大。ヘッダだけ", rawHeader(0x42, 0x4c, 1, 0x04, 0, ZERO, 0xffffffff), BROWSER_TO_RELAY, "too_large"],
    ["6. ブラウザが受ける種別（accepted）で、宣言が上限を超える", rawHeader(0x42, 0x4c, 1, 0x81, 0, ZERO, 2_097_136), RELAY_TO_BROWSER, "too_large"],
    ["7. 本文長 5 に対して、本文が 3 バイト（不足）", Uint8Array.from([...rawHeader(0x42, 0x4c, 1, 0x04, 0, ZERO, 5), ...goodBody]), BROWSER_TO_RELAY, "length_mismatch"],
    ["7. 本文長 3 に対して、本文が 5 バイト（超過）", Uint8Array.from([...rawHeader(0x42, 0x4c, 1, 0x04, 0, ZERO, 3), 1, 2, 3, 4, 5]), BROWSER_TO_RELAY, "length_mismatch"],
    ["7. 本文長 0 に対して、本文が 1 バイト", Uint8Array.from([...rawHeader(0x42, 0x4c, 1, 0x84, 0, ZERO, 0), 9]), RELAY_TO_BROWSER, "length_mismatch"],
    ["7. 本文長 1 に対して、ヘッダだけ", rawHeader(0x42, 0x4c, 1, 0x04, 0, ZERO, 1), BROWSER_TO_RELAY, "length_mismatch"],
    ["7. 宣言が、ちょうど上限（全体が 2,097,152 バイト）で、ヘッダだけ。too_large ではなく length_mismatch", rawHeader(0x42, 0x4c, 1, 0x04, 0, ZERO, 2_097_135), BROWSER_TO_RELAY, "length_mismatch"],
    // 優先順位：複数の誤りがあるときは、先の誤りで拒否する
    ["優先 1 > 2：10 バイトで識別子も誤り", Uint8Array.from([0, 0, 0, 0, 0, 0, 0, 0, 0, 0]), BROWSER_TO_RELAY, "truncated_header"],
    ["優先 2 > 3：識別子も版も誤り", Uint8Array.from([...rawHeader(0x00, 0x00, 9, 0x04, 0, ZERO, 0)]), BROWSER_TO_RELAY, "invalid_magic"],
    ["優先 3 > 4：版も種別も誤り", Uint8Array.from([...rawHeader(0x42, 0x4c, 9, 0x00, 0, ZERO, 0)]), BROWSER_TO_RELAY, "unsupported_version"],
    ["優先 4 > 7：種別も本文長も誤り", Uint8Array.from([...rawHeader(0x42, 0x4c, 1, 0x00, 0, ZERO, 5), 1]), BROWSER_TO_RELAY, "unknown_type"],
    ["優先 5 > 6：方向も本文長（2 MB 超）も誤り", rawHeader(0x42, 0x4c, 1, 0x81, 0, ZERO, 0xffffffff), BROWSER_TO_RELAY, "wrong_direction"],
    ["優先 5 > 7：方向も本文長も誤り", Uint8Array.from([...rawHeader(0x42, 0x4c, 1, 0x81, 0, ZERO, 9), 1]), BROWSER_TO_RELAY, "wrong_direction"],
    ["優先 6 > 7：2 MB 超の宣言と、不足した本文", Uint8Array.from([...rawHeader(0x42, 0x4c, 1, 0x04, 0, ZERO, 3_000_000), 1, 2]), BROWSER_TO_RELAY, "too_large"],
  ];

  test.each(cases)("%s -> %s", (_label, message, accepts, expectedCode) => {
    expectFrameError(() => decodeRawFrame(message, accepts), expectedCode);
  });

  test("受け取ったバイト数が 2,097,152 を超える（宣言と実際の本文は一致している）メッセージは too_large", () => {
    const message = rawMessage(0x04, 0, ZERO, new Uint8Array(MAX_MESSAGE_BYTES - HEADER_BYTES + 1));
    expect(message.length).toBe(MAX_MESSAGE_BYTES + 1);
    expectFrameError(() => decodeRawFrame(message, BROWSER_TO_RELAY), "too_large");
  });

  test("エラーの詳細に、本文の中身（接続チケットなど）を含めない", () => {
    const secret = Array.from("dummy-secret-ticket", (character) => character.charCodeAt(0));
    const message = Uint8Array.from([...rawHeader(0x42, 0x4c, 1, 0x01, 0, ZERO, 1), ...secret]);
    try {
      decodeRawFrame(message, BROWSER_TO_RELAY);
      throw new Error("expected a failure");
    } catch (error) {
      expect(isFrameError(error) && error.code).toBe("length_mismatch");
      expect(String((error as Error).message)).not.toContain("dummy-secret-ticket");
    }
  });

  test("入力の型が不正（Uint8Array でない）なら、推測せず invalid_message", () => {
    expectFrameError(() => decodeRawFrame("BL" as unknown as Uint8Array, BROWSER_TO_RELAY), "invalid_message");
    expectFrameError(() => decodeRawFrame(null as unknown as Uint8Array, BROWSER_TO_RELAY), "invalid_message");
  });

  test("受信側の方向が不正なら、推測せず RangeError（呼び出しの誤り）", () => {
    expect(() => decodeRawFrame(rawMessage(0x04, 0, ZERO, goodBody), "sideways" as unknown as FrameDirection)).toThrow(RangeError);
  });
});

describe("encodeRawFrame と decodeRawFrame の往復（決定的な乱数）", () => {
  test("14 種の種別・キーフレーム・64 ビットの時刻・長さ 0 から 300 の本文が、符号化して復号すると元に戻る", () => {
    const random = seededRandom(1725);
    const problems = new Problems();
    for (let round = 0; round < 1_000; round += 1) {
      const [name, , direction] = TYPE_TABLE[Math.floor(random() * TYPE_TABLE.length)];
      const keyframe = random() < 0.5;
      const high = BigInt(Math.floor(random() * 4_294_967_296));
      const low = BigInt(Math.floor(random() * 4_294_967_296));
      const timestampUs = (high << BigInt(32)) | low;
      const body = Uint8Array.from({ length: Math.floor(random() * 301) }, () => Math.floor(random() * 256));
      const decoded = decodeRawFrame(encodeRawFrame({ type: name, keyframe, timestampUs, body }), direction);
      if (decoded.type !== name || decoded.keyframe !== keyframe || decoded.timestampUs !== timestampUs || decoded.body.length !== body.length || !decoded.body.every((value, index) => value === body[index])) {
        problems.report(`round ${round}: ${name} keyframe=${String(keyframe)} timestamp=${timestampUs.toString()} body=${body.length} differs`);
      }
    }
    expect(problems.list()).toEqual([]);
  });
});
