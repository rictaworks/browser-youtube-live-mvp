/**
 * @jest-environment node
 */
// 共有テストベクタ（src/contracts/ws-frame-vectors.json。ws-protocol.md の 10 章）の、全件の検査。
// 中継（Go。src/relay/core/frame/vectors_test.go）と、同じベクタ・同じ検査の観点で通し、フレームの互換を保証する。
//   - 契約のディレクトリは、/contracts・../contracts・../../contracts・このファイルから src/contracts へ上る相対パスの順に探す。見つからなければ、
//     探した場所を並べて失敗する（黙ってスキップしない）
//   - valid：方向の受信側が decoded のとおりに復号でき、反対側の受信側は wrong_direction で拒否する。decoded の欄から符号化すると hex と一致する
//     （decode_only は、復号だけ。エンコーダは、属性の予約ビットを 0 にする）。ブラウザが送る 7 種は、型付きの encode でも hex と一致する
//     （本文に x_ の拡張のキーを持つものを除く。型付きの encode は、未知の項目を送らないため）。ブラウザが受ける 7 種は、型付きの decode が、本文の JSON と一致する
//   - invalid：receivers に挙げた受信側が、error の符号で拒否する（ブラウザの入口 FrameCodec.decode も）
import fs from "node:fs";
import path from "node:path";

import { LIMITS, WS_MESSAGE_TYPE_VALUES } from "../contract";
import { FrameCodec } from "./FrameCodec";
import { FRAME_ERROR_CODES, isFrameError } from "./errors";
import type { FrameErrorCode } from "./errors";
import { decodeRawFrame, encodeRawFrame } from "./frameLayout";
import type { FrameDirection, RawFrame } from "./frameLayout";
import type { OutboundMessage } from "./messages";

// ---------------------------------------------------------------------------
// 契約のディレクトリの探し方（core/contract/contract.test.ts と同じ規則）
// ---------------------------------------------------------------------------

const MARKER_FILE = "enums.json";
const VECTORS_FILE = "ws-frame-vectors.json";
/** このテストのあるディレクトリ（src/frontend/core/transport）から、src/contracts へ上る相対パス */
const RELATIVE_FROM_TEST_DIR = "../../../contracts";

/** 候補を、探す順に返す。同じ場所を指す候補は、最初の 1 つだけを残す。 */
function candidateDirs(cwd: string, testDir: string): string[] {
  const candidates = ["/contracts", path.resolve(cwd, "../contracts"), path.resolve(cwd, "../../contracts"), path.resolve(testDir, RELATIVE_FROM_TEST_DIR)];
  return [...new Set(candidates)];
}

/** 候補を順に探し、最初に見つかったディレクトリを返す。1 つも無ければ、探した場所を並べた例外（黙ってスキップしない）。 */
function locateContractsDir(candidates: string[], markerExists: (dir: string) => boolean): string {
  const found = candidates.find((dir) => markerExists(dir));
  if (found !== undefined) {
    return found;
  }
  throw new Error(
    [
      "契約のディレクトリ（src/contracts）が見つかりません。黙ってスキップせず、失敗します。",
      "探した場所（この順）:",
      ...candidates.map((dir) => `  - ${dir}（${MARKER_FILE} が無い）`),
      "対処: docker compose の環境では scripts/test_frontend.sh を使ってください（/contracts へ読み取り専用でマウントされます）。",
    ].join("\n"),
  );
}

// ---------------------------------------------------------------------------
// ベクタの読み込み
// ---------------------------------------------------------------------------

interface DecodedVector {
  readonly type: string;
  readonly type_code: number;
  readonly keyframe: boolean;
  /** 10 進数の文字列（JSON の数値は、2^53 を超えると JavaScript で厳密に表せない） */
  readonly timestamp_us: string;
  readonly body_hex: string;
}

interface ValidVector {
  readonly name: string;
  readonly direction: FrameDirection;
  readonly hex: string;
  readonly decoded: DecodedVector;
  readonly body_text?: string;
  readonly decode_only?: boolean;
}

interface InvalidVector {
  readonly name: string;
  readonly receivers: readonly ("relay" | "browser")[];
  readonly hex: string;
  readonly error: FrameErrorCode;
}

interface VectorFile {
  readonly valid: readonly ValidVector[];
  readonly invalid: readonly InvalidVector[];
}

function loadVectors(): VectorFile {
  const dir = locateContractsDir(candidateDirs(process.cwd(), __dirname), (candidate) => fs.existsSync(path.join(candidate, MARKER_FILE)));
  const parsed = JSON.parse(fs.readFileSync(path.join(dir, VECTORS_FILE), "utf8")) as VectorFile;
  if (parsed.valid.length === 0 || parsed.invalid.length === 0) {
    throw new Error(`${VECTORS_FILE} has no vectors (valid=${parsed.valid.length} invalid=${parsed.invalid.length})`);
  }
  return parsed;
}

/** 16 進文字列を、バイト列にする。不正な文字・奇数の長さは、黙って切り詰めず失敗する（Buffer.from は、不正な位置で切り詰める）。 */
function hexToBytes(hex: string): Uint8Array {
  if (!/^([0-9a-f]{2})*$/.test(hex)) {
    throw new Error(`invalid hex string: ${hex.slice(0, 40)}`);
  }
  return Uint8Array.from(Buffer.from(hex, "hex"));
}

function bytesToText(bytes: Uint8Array): string {
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}

const VECTORS = loadVectors();
const codec = new FrameCodec();
const RECEIVER_DIRECTION: Record<"relay" | "browser", FrameDirection> = { relay: "browser_to_relay", browser: "relay_to_browser" };

/** 型付きの encode が、同じバイト列を作れない（本文に、未知の拡張のキーを持つ）ベクタ。理由を、下の検査で確かめる。 */
const EXTENSION_KEY_VECTORS: readonly string[] = ["report_with_multibyte_text"];

function expectedFrame(vector: ValidVector): RawFrame {
  return { type: vector.decoded.type as RawFrame["type"], keyframe: vector.decoded.keyframe, timestampUs: BigInt(vector.decoded.timestamp_us), body: hexToBytes(vector.decoded.body_hex) };
}

function expectSameFrame(actual: RawFrame, expected: RawFrame): void {
  expect({ type: actual.type, keyframe: actual.keyframe, timestampUs: actual.timestampUs.toString() }).toEqual({
    type: expected.type,
    keyframe: expected.keyframe,
    timestampUs: expected.timestampUs.toString(),
  });
  expect(Array.from(actual.body)).toEqual(Array.from(expected.body));
}

function errorCodeOf(action: () => unknown): FrameErrorCode | string {
  try {
    action();
  } catch (error) {
    return isFrameError(error) ? error.code : `not a FrameError: ${String(error)}`;
  }
  return "no error";
}

/** ベクタの valid（ブラウザ → 中継）から、型付きの送信メッセージを作る。JSON の本文は、そのまま JSON.parse の値を渡す（検証・正規化は encode）。 */
function outboundFromVector(vector: ValidVector): OutboundMessage {
  const body = hexToBytes(vector.decoded.body_hex);
  const timestampUs = BigInt(vector.decoded.timestamp_us);
  switch (vector.decoded.type) {
    case "hello":
      return { type: "hello", ticket: bytesToText(body) };
    case "probe":
      return { type: "probe", payload: body };
    case "start":
      return { type: "start", body: JSON.parse(bytesToText(body)) };
    case "video":
      return { type: "video", timestampUs, keyframe: vector.decoded.keyframe, payload: body };
    case "audio":
      return { type: "audio", timestampUs, payload: body };
    case "report":
      return { type: "report", body: JSON.parse(bytesToText(body)) };
    case "end":
      return { type: "end", body: JSON.parse(bytesToText(body)) };
    default:
      throw new Error(`vector ${vector.name} is not a browser-to-relay type: ${vector.decoded.type}`);
  }
}

describe("契約のディレクトリの探し方（黙ってスキップしない）", () => {
  test("候補は /contracts・../contracts・../../contracts・テストの隣からの相対パスの順（同じ場所は 1 つにまとめる）", () => {
    expect(candidateDirs("/work/src/frontend", "/repo/src/frontend/core/transport")).toEqual(["/contracts", "/work/src/contracts", "/work/contracts", "/repo/src/contracts"]);
    expect(candidateDirs("/app", "/app/core/transport")).toEqual(["/contracts"]);
  });

  test("目印（enums.json）が、どの候補にも無ければ、探した場所をすべて並べて失敗する", () => {
    const candidates = ["/contracts", "/x/contracts", "/y/contracts"];
    expect(() => locateContractsDir(candidates, () => false)).toThrow(/黙ってスキップせず/);
    for (const dir of candidates) {
      expect(() => locateContractsDir(candidates, () => false)).toThrow(dir);
    }
  });

  test("最初に見つかった場所を返す", () => {
    expect(locateContractsDir(["/contracts", "/x/contracts"], (dir) => dir !== "/contracts")).toBe("/x/contracts");
  });

  test("hexToBytes は、不正な文字・奇数の長さを、切り詰めずに失敗する（検査の道具の自己検査）", () => {
    expect(() => hexToBytes("4g")).toThrow();
    expect(() => hexToBytes("424")).toThrow();
    expect(Array.from(hexToBytes(""))).toEqual([]);
    expect(Array.from(hexToBytes("424c"))).toEqual([0x42, 0x4c]);
  });
});

describe("共有ベクタが、契約を網羅している（空振りしていない）", () => {
  test("有効なフレームは、14 種の種別をすべて持ち、符号と方向が契約（LIMITS.ws_frame.types）と一致する", () => {
    const seen = new Set<string>();
    for (const vector of VECTORS.valid) {
      const contractEntry = LIMITS.ws_frame.types[vector.decoded.type as keyof typeof LIMITS.ws_frame.types];
      expect(contractEntry).toBeDefined();
      expect({ name: vector.name, code: vector.decoded.type_code, direction: vector.direction }).toEqual({
        name: vector.name,
        code: contractEntry.code,
        direction: contractEntry.direction,
      });
      seen.add(vector.decoded.type);
    }
    expect([...seen].sort()).toEqual([...WS_MESSAGE_TYPE_VALUES].sort());
  });

  test("有効なフレームは、ブラウザが送る 7 種のすべてと、ブラウザが受ける 7 種のすべての例を持つ", () => {
    const sent = new Set(VECTORS.valid.filter((vector) => vector.direction === "browser_to_relay").map((vector) => vector.decoded.type));
    const received = new Set(VECTORS.valid.filter((vector) => vector.direction === "relay_to_browser").map((vector) => vector.decoded.type));
    expect(sent.size).toBe(7);
    expect(received.size).toBe(7);
  });

  test("64 ビットの時刻の境界（2^32 - 1・2^32・2^53 - 1・2^53・2^53 + 1・2^63・2^64 - 1）の例を持つ", () => {
    const timestamps = new Set(VECTORS.valid.map((vector) => vector.decoded.timestamp_us));
    const one = BigInt(1);
    const boundaries = [(one << BigInt(32)) - one, one << BigInt(32), (one << BigInt(53)) - one, one << BigInt(53), (one << BigInt(53)) + one, one << BigInt(63), (one << BigInt(64)) - one];
    for (const boundary of boundaries) {
      expect(timestamps.has(boundary.toString())).toBe(true);
    }
  });

  test("無効なフレームは、7 種のエラーのすべてを、中継とブラウザの両方を受信側として持つ", () => {
    const structural = FRAME_ERROR_CODES.slice(0, 7);
    for (const receiver of ["relay", "browser"] as const) {
      const codes = new Set(VECTORS.invalid.filter((vector) => vector.receivers.includes(receiver)).map((vector) => vector.error));
      expect([...structural].filter((code) => !codes.has(code))).toEqual([]);
    }
  });

  test("decode_only のベクタ（属性の予約ビットを立てた例）がある", () => {
    expect(VECTORS.valid.filter((vector) => vector.decode_only === true).length).toBeGreaterThanOrEqual(1);
  });
});

describe("valid：復号（両方の受信側）", () => {
  test.each(VECTORS.valid.map((vector) => [vector.name, vector] as const))("%s", (_name, vector) => {
    const message = hexToBytes(vector.hex);
    const expected = expectedFrame(vector);
    for (const receiver of ["relay", "browser"] as const) {
      const accepts = RECEIVER_DIRECTION[receiver];
      if (accepts === vector.direction) {
        expectSameFrame(decodeRawFrame(message, accepts), expected);
      } else {
        expect(errorCodeOf(() => decodeRawFrame(message, accepts))).toBe("wrong_direction");
      }
    }
  });
});

describe("valid：符号化（decoded の欄から作ったフレームが、hex と一致する）", () => {
  test.each(VECTORS.valid.map((vector) => [vector.name, vector] as const))("%s", (_name, vector) => {
    const expectedBytes = hexToBytes(vector.hex);
    const encoded = encodeRawFrame(expectedFrame(vector));
    if (vector.decode_only === true) {
      // 属性の予約ビットを立てた例。エンコーダは予約ビットを 0 にするので、同じ並びにはならない（復号だけを検査する）
      expect(Array.from(encoded)).not.toEqual(Array.from(expectedBytes));
      expect(encoded[4]).toBe(expectedBytes[4] & 1);
      return;
    }
    expect(Buffer.from(encoded).toString("hex")).toBe(vector.hex);
  });
});

describe("valid：ブラウザが送る 7 種は、型付きの encode でも、hex と一致する", () => {
  const sent = VECTORS.valid.filter((vector) => vector.direction === "browser_to_relay" && vector.decode_only !== true);

  test("検査の対象は、ブラウザが送る 7 種のすべてを含む", () => {
    expect(new Set(sent.map((vector) => vector.decoded.type)).size).toBe(7);
  });

  test.each(sent.filter((vector) => !EXTENSION_KEY_VECTORS.includes(vector.name)).map((vector) => [vector.name, vector] as const))("%s", (_name, vector) => {
    expect(Buffer.from(codec.encode(outboundFromVector(vector))).toString("hex")).toBe(vector.hex);
  });

  test.each(sent.filter((vector) => EXTENSION_KEY_VECTORS.includes(vector.name)).map((vector) => [vector.name, vector] as const))(
    "%s は、本文に x_ の拡張のキーを持つので、型付きの encode は、そのキーを送らない（既知の項目だけの本文になる）",
    (_name, vector) => {
      const original = JSON.parse(bytesToText(hexToBytes(vector.decoded.body_hex))) as Record<string, unknown>;
      expect(Object.keys(original).some((key) => key.startsWith("x_"))).toBe(true);
      const raw = decodeRawFrame(codec.encode(outboundFromVector(vector)), "browser_to_relay");
      const sentBody = JSON.parse(bytesToText(raw.body)) as Record<string, unknown>;
      expect(Object.keys(sentBody).some((key) => key.startsWith("x_"))).toBe(false);
      expect(sentBody).toEqual(Object.fromEntries(Object.entries(original).filter(([key]) => !key.startsWith("x_"))));
    },
  );

  test("型付きの encode で再現できないベクタは、理由つきの一覧（EXTENSION_KEY_VECTORS）のものだけ", () => {
    const names = new Set(sent.map((vector) => vector.name));
    for (const name of EXTENSION_KEY_VECTORS) {
      expect(names.has(name)).toBe(true);
    }
  });
});

describe("valid：ブラウザが受ける 7 種は、型付きの decode が、本文の JSON と一致する", () => {
  const received = VECTORS.valid.filter((vector) => vector.direction === "relay_to_browser");

  test.each(received.map((vector) => [vector.name, vector] as const))("%s", (_name, vector) => {
    const message = codec.decode(hexToBytes(vector.hex));
    expect(message.type).toBe(vector.decoded.type);
    const body = hexToBytes(vector.decoded.body_hex);
    if (vector.decoded.type === "keyframe_request") {
      expect(body.length).toBe(0);
      expect(message).toEqual({ type: "keyframe_request" });
      return;
    }
    if (vector.body_text !== undefined) {
      expect(bytesToText(body)).toBe(vector.body_text);
    }
    // 本文は、既知の項目だけ（ベクタの JSON に、未知のキーは無い）。型付きの decode の結果は、JSON と同じ値になる
    expect(message).toEqual({ type: vector.decoded.type, body: JSON.parse(bytesToText(body)) });
  });
});

describe("invalid：receivers に挙げた受信側が、error の符号で拒否する", () => {
  test.each(VECTORS.invalid.map((vector) => [vector.name, vector] as const))("%s", (_name, vector) => {
    const message = hexToBytes(vector.hex);
    for (const receiver of vector.receivers) {
      expect({ receiver, code: errorCodeOf(() => decodeRawFrame(message, RECEIVER_DIRECTION[receiver])) }).toEqual({ receiver, code: vector.error });
      if (receiver === "browser") {
        // ブラウザの入口（型付きの decode）も、同じ符号
        expect({ receiver, code: errorCodeOf(() => codec.decode(message)) }).toEqual({ receiver, code: vector.error });
      }
    }
  });
});
