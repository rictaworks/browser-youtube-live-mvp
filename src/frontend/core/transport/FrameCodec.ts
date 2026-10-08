// FrameCodec：ブラウザの、WebSocket 転送フレームの符号化・復号（ws-protocol.md の 2〜5 章、requirements.md 11.9）。
//   encode  ブラウザが送る 7 種（hello・probe・start・video・audio・report・end）。型付きのメッセージを検証し、17 バイトのヘッダのフレームにする
//   decode  ブラウザが受ける 7 種（accepted・probe_result・ack・keyframe_request・throttle・status・fatal）。ws-protocol.md の 4 章の順に検証し、
//           JSON の本文を型付きにする
// 失敗は、FrameError（符号つき）で返す。受信の不備は、そのメッセージを破棄するための印で、接続は維持する（4.1）。黙って捨てない。
// 本文の JSON は、UTF-8。契約のキーの順で出す（共有テストベクタと、バイト列まで一致する）。知らない項目は、送らない（余計な項目・デバイス名などが
// 紛れ込まない）。中の判定は、受け取ったバイト列だけで行い、時刻・乱数・環境を参照しない。

import type { WsMessageType } from "../contract";
import { parseAcceptedBody, parseAckBody, parseEndBody, parseFatalBody, parseHelloTicket, parseProbeResultBody, parseReportBody, parseStartBody, parseStatusBody, parseThrottleBody } from "./bodies";
import { decodeUtf8, encodeUtf8 } from "./bytes";
import { FrameError } from "./errors";
import { decodeRawFrame, directionOfType, encodeRawFrame } from "./frameLayout";
import type { InboundMessage, OutboundMessage } from "./messages";

type JsonBodyType = "start" | "report" | "end";

/** 本文（JSON）の正規化した値を、UTF-8 の本文にして、フレームにする。 */
function encodeJsonFrame(type: JsonBodyType, body: object): Uint8Array {
  return encodeRawFrame({ type, body: encodeUtf8(JSON.stringify(body)) });
}

/** 受け取ったバイナリ（ArrayBuffer・その部分ビュー・Node の Buffer など）を、Uint8Array のビューにする。バイナリでなければ invalid_message。 */
function toBytes(data: unknown): Uint8Array {
  if (Object.prototype.toString.call(data) === "[object ArrayBuffer]") {
    return new Uint8Array(data as ArrayBuffer);
  }
  if (ArrayBuffer.isView(data)) {
    return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  }
  throw new FrameError("invalid_message", `a received message must be binary (an ArrayBuffer or a view of one): ${Object.prototype.toString.call(data)}`);
}

/** JSON の本文を解釈する。UTF-8 でない・JSON でない（BOM 付き・空を含む）は invalid_body。内容は、エラーに含めない。 */
function parseJson(body: Uint8Array): unknown {
  const text = decodeUtf8(body);
  try {
    return JSON.parse(text);
  } catch {
    throw new FrameError("invalid_body", "body is not valid JSON");
  }
}

export class FrameCodec {
  /**
   * ブラウザが送る 7 種のメッセージを、1 メッセージのバイト列（WebSocket のバイナリメッセージ 1 つ）にする。
   *  - 中継 → ブラウザの種別は wrong_direction、未知の種別は unknown_type（呼び出しの誤り）
   *  - JSON の本文（start・report・end）は、契約のキーの順に正規化し、検証する（不備は invalid_body）。detail は、符号と数値のみ
   *  - video・audio の時刻は、BigInt（または、0 以上の安全整数の Number）。2^53 を超える値も、厳密に符号化する
   *  - 全体が 2,097,152 バイトを超えれば too_large
   * 入力は変更しない。結果は、毎回、新しいバイト列。
   */
  encode(message: OutboundMessage): Uint8Array {
    if (typeof message !== "object" || message === null) {
      throw new FrameError("invalid_message", `a message must be an object: ${message === null ? "null" : typeof message}`);
    }
    const type = (message as { readonly type?: unknown }).type;
    const direction = typeof type === "string" ? directionOfType(type as WsMessageType) : undefined;
    if (direction === undefined) {
      throw new FrameError("unknown_type", `unknown message type: ${String(type).slice(0, 32)}`);
    }
    if (direction !== "browser_to_relay") {
      throw new FrameError("wrong_direction", `type ${String(type)} is sent by the relay; the browser sends only browser-to-relay types`);
    }

    switch (message.type) {
      case "hello":
        return encodeRawFrame({ type: "hello", body: encodeUtf8(parseHelloTicket(message.ticket)) });
      case "probe":
        return encodeRawFrame({ type: "probe", body: message.payload });
      case "start":
        return encodeJsonFrame("start", parseStartBody(message.body));
      case "video":
        if (typeof message.keyframe !== "boolean") {
          throw new FrameError("invalid_message", `keyframe must be a boolean: ${typeof message.keyframe}`);
        }
        return encodeRawFrame({ type: "video", keyframe: message.keyframe, timestampUs: message.timestampUs, body: message.payload });
      case "audio":
        return encodeRawFrame({ type: "audio", timestampUs: message.timestampUs, body: message.payload });
      case "report":
        return encodeJsonFrame("report", parseReportBody(message.body));
      case "end":
        return encodeJsonFrame("end", parseEndBody(message.body));
      default:
        throw new FrameError("unknown_type", `unknown message type: ${String((message as { readonly type?: unknown }).type).slice(0, 32)}`);
    }
  }

  /**
   * ブラウザが受けた 1 メッセージ（WebSocket のバイナリメッセージ 1 つ）を、検証して復号する。
   * 検証は、ws-protocol.md の 4 章の順（truncated_header・invalid_magic・unsupported_version・unknown_type・wrong_direction・too_large・
   * length_mismatch）。続けて、JSON の本文（UTF-8・JSON・必須の項目・値）を検証し、型付きにする（不備は invalid_body。未知のキーは無視する）。
   * バイナリでない入力（テキストのメッセージなど）は invalid_message。
   * 呼び出し側は、FrameError を受けたら、そのメッセージを破棄し、理由を記録にだけ残す（接続は維持する。4.1）。入力は変更しない。
   */
  decode(data: ArrayBuffer | ArrayBufferView): InboundMessage {
    const frame = decodeRawFrame(toBytes(data), "relay_to_browser");
    switch (frame.type) {
      case "accepted":
        return { type: "accepted", body: parseAcceptedBody(parseJson(frame.body)) };
      case "probe_result":
        return { type: "probe_result", body: parseProbeResultBody(parseJson(frame.body)) };
      case "ack":
        return { type: "ack", body: parseAckBody(parseJson(frame.body)) };
      case "keyframe_request":
        if (frame.body.length !== 0) {
          throw new FrameError("invalid_body", `a keyframe_request body must be empty: ${frame.body.length} bytes`);
        }
        return { type: "keyframe_request" };
      case "throttle":
        return { type: "throttle", body: parseThrottleBody(parseJson(frame.body)) };
      case "status":
        return { type: "status", body: parseStatusBody(parseJson(frame.body)) };
      case "fatal":
        return { type: "fatal", body: parseFatalBody(parseJson(frame.body)) };
      default:
        // ブラウザ → 中継の種別は、decodeRawFrame が wrong_direction で拒否している。ここへ来るのは、契約の表と、この switch の食い違い
        throw new FrameError("unknown_type", `no decoder for message type: ${frame.type}`);
    }
  }
}
