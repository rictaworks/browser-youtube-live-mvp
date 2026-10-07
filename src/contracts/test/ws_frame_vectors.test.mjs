// WebSocket 転送フレームの共有テストベクタ（ws-frame-vectors.json）の自己整合。
//
// 独立した参照実装（ws_reference.mjs）で、各ベクタのヘッダの欄と本文長を再計算し、16 進文字列・期待される復号結果・
// エラー符号と一致することを確かめる。あわせて、14 種の網羅・64 ビットの境界・本文長 0・日本語を含む JSON 本文・
// 7 種の無効（識別子・版・未知の種別・方向・本文長の不一致・切り詰め・2 MB 超）を含むことを確かめる。
// フロントエンド（#25）と中継（#18）のコーデックは、このベクタをそのまま通す。
import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { bytesToHex, hexToBytes, isDocumentKey, loadContracts } from "./helpers.mjs";
import {
  HEADER_BYTES,
  INCOMING_DIRECTION,
  MAX_MESSAGE_BYTES,
  REFERENCE_TYPES,
  U64_MAX,
  decodeFrame,
  encodeFrame,
} from "./ws_reference.mjs";

const { vectors, enums, limits } = loadContracts();
const valuesOf = (name) => enums.enums[name].values;

const ERROR_CODES = [
  "invalid_magic",
  "unsupported_version",
  "unknown_type",
  "wrong_direction",
  "length_mismatch",
  "truncated_header",
  "too_large",
];
const RECEIVERS = ["relay", "browser"];
const RECEIVER_OF_DIRECTION = { browser_to_relay: "relay", relay_to_browser: "browser" };
const OTHER_RECEIVER = { relay: "browser", browser: "relay" };
/** 本文が UTF-8 の JSON であるメッセージ。 */
const JSON_TYPES = ["start", "report", "end", "accepted", "probe_result", "ack", "throttle", "status", "fatal"];
/** 時刻（メディアクロック）を持つメッセージ。制御メッセージの時刻は 0。 */
const MEDIA_TYPES = ["video", "audio"];

const decoder = new TextDecoder("utf-8", { fatal: true });
const parseUtf8 = (bytes) => decoder.decode(bytes);

function bodyOf(vector) {
  return hexToBytes(vector.decoded.body_hex);
}

describe("ws-frame-vectors.json の構造", () => {
  test("トップレベルは、$comment・valid・invalid だけ", () => {
    assert.deepEqual(Object.keys(vectors).sort(), ["$comment", "invalid", "valid"]);
    assert.ok(Array.isArray(vectors.valid) && Array.isArray(vectors.invalid));
  });

  test("ベクタの名前は、valid と invalid を通して一意で、英小文字・数字・アンダースコア", () => {
    const names = [...vectors.valid, ...vectors.invalid].map((vector) => vector.name);
    for (const name of names) {
      assert.match(name, /^[a-z0-9_]+$/);
    }
    assert.equal(new Set(names).size, names.length, "ベクタの名前が重複しています");
  });

  test("ファイルが大きくなりすぎない（2 MB 超を、本文を巨大にせず表現している）", () => {
    const bytes = Buffer.byteLength(JSON.stringify(vectors));
    assert.ok(bytes < 100_000, `${bytes} バイト`);
  });

  test("有効は 14 種を網羅し、無効は 7 種のエラーを網羅する", () => {
    assert.deepEqual(
      [...new Set(vectors.valid.map((vector) => vector.decoded.type))].sort(),
      [...valuesOf("ws_message_type")].sort(),
    );
    assert.deepEqual([...new Set(vectors.invalid.map((vector) => vector.error))].sort(), [...ERROR_CODES].sort());
  });
});

describe("有効なフレーム", () => {
  for (const vector of vectors.valid) {
    describe(vector.name, () => {
      const { decoded } = vector;
      const bytes = hexToBytes(vector.hex);
      const body = bodyOf(vector);

      test("キーは name・direction・hex・decoded（と任意の note・body_text・decode_only）だけ", () => {
        const allowed = new Set(["name", "direction", "hex", "decoded", "body_text", "decode_only", "note"]);
        for (const key of Object.keys(vector)) {
          assert.ok(allowed.has(key), `未知のキー: ${key}`);
        }
        assert.deepEqual(Object.keys(decoded).sort(), ["body_hex", "keyframe", "timestamp_us", "type", "type_code"]);
      });

      test("種別符号と方向は、limits.json の ws_frame と一致する", () => {
        assert.equal(decoded.type_code, limits.ws_frame.types[decoded.type].code);
        assert.equal(vector.direction, limits.ws_frame.types[decoded.type].direction);
        assert.equal(bytes[3], decoded.type_code);
      });

      test("時刻は 10 進数の文字列で、符号なし 64 ビットの範囲にある（JSON の数値は 2^53 を超えると厳密に表せない）", () => {
        assert.equal(typeof decoded.timestamp_us, "string");
        assert.match(decoded.timestamp_us, /^(?:0|[1-9][0-9]*)$/);
        assert.ok(BigInt(decoded.timestamp_us) <= U64_MAX);
      });

      test("制御メッセージの時刻は 0。映像・音声だけが時刻を持つ", () => {
        if (!MEDIA_TYPES.includes(decoded.type)) {
          assert.equal(decoded.timestamp_us, "0");
        }
      });

      test("キーフレームの属性は映像だけに付く", () => {
        if (decoded.keyframe) {
          assert.equal(decoded.type, "video");
        }
      });

      test("ヘッダの各欄と本文長を、独立に再計算して、16 進文字列と一致する", () => {
        if (vector.decode_only === true) {
          return; // 属性の予約ビットを立てたもの。エンコーダは作らない形なので、復号だけを検査する
        }
        const rebuilt = encodeFrame({
          typeCode: REFERENCE_TYPES[decoded.type].code,
          attributes: decoded.keyframe ? 1 : 0,
          timestampUs: BigInt(decoded.timestamp_us),
          body,
        });
        assert.equal(bytesToHex(rebuilt), vector.hex);
        assert.equal(vector.hex.length, 2 * (HEADER_BYTES + body.length));
      });

      test("ヘッダの本文長は、本文のバイト数（文字数ではない）に一致する", () => {
        const declared = new DataView(bytes.buffer).getUint32(13, false);
        assert.equal(declared, body.length);
        assert.equal(bytes.length - HEADER_BYTES, body.length);
      });

      test("方向の受信側は、期待される復号結果を得る", () => {
        const receiver = RECEIVER_OF_DIRECTION[vector.direction];
        const result = decodeFrame(bytes, receiver);
        assert.equal(result.error, undefined, `${receiver}: ${result.error}`);
        assert.equal(result.frame.type, decoded.type);
        assert.equal(result.frame.typeCode, decoded.type_code);
        assert.equal(result.frame.keyframe, decoded.keyframe);
        assert.equal(result.frame.timestampUs, BigInt(decoded.timestamp_us));
        assert.equal(bytesToHex(result.frame.body), decoded.body_hex);
      });

      test("反対側の受信側は、wrong_direction で拒否する", () => {
        const other = OTHER_RECEIVER[RECEIVER_OF_DIRECTION[vector.direction]];
        assert.deepEqual(decodeFrame(bytes, other), { error: "wrong_direction" });
      });

      test("予約ビット（属性の bit1〜bit7）を立てたベクタは decode_only で、復号は bit0 だけで決まる", () => {
        const attributes = bytes[4];
        if ((attributes & 0xfe) !== 0) {
          assert.equal(vector.decode_only, true);
        } else {
          assert.notEqual(vector.decode_only, true);
        }
        assert.equal(decoded.keyframe, (attributes & 0x01) === 0x01);
      });

      test("本文の読みやすい写し（body_text）は、本文を UTF-8 として読んだ内容と一致する。JSON の本文は、JSON として読める", () => {
        if (JSON_TYPES.includes(decoded.type) || decoded.type === "hello") {
          assert.equal(typeof vector.body_text, "string", "body_text がありません");
        }
        if (vector.body_text !== undefined) {
          assert.equal(parseUtf8(body), vector.body_text);
          if (JSON_TYPES.includes(decoded.type)) {
            const parsed = JSON.parse(vector.body_text);
            assert.ok(parsed !== null && typeof parsed === "object" && !Array.isArray(parsed));
          }
        } else {
          assert.ok(!JSON_TYPES.includes(decoded.type));
        }
      });
    });
  }
});

describe("有効なフレームの本文（JSON の項目）", () => {
  const validators = {
    hello(vector) {
      assert.match(vector.body_text, /^[A-Za-z0-9_.~-]{16,}$/, "接続チケットは URL 安全な文字の、16 文字以上の文字列");
    },
    start(vector) {
      const body = JSON.parse(vector.body_text);
      assertKeys(body, ["profile", "video", "audio"]);
      assert.ok(valuesOf("profile").includes(body.profile));
      const profile = limits.profiles[body.profile];
      assertKeys(body.video, ["codec", "width", "height", "framerate", "bitrate_kbps", "description_b64"]);
      assert.ok([limits.video.codec_main, limits.video.codec_constrained_baseline].includes(body.video.codec));
      assert.equal(body.video.width, profile.width);
      assert.equal(body.video.height, profile.height);
      assert.equal(body.video.framerate, profile.framerate);
      assert.ok(body.video.bitrate_kbps >= profile.video_bitrate_min_kbps && body.video.bitrate_kbps <= profile.video_bitrate_max_kbps);
      assertBase64(body.video.description_b64);
      assertKeys(body.audio, ["codec", "sample_rate", "channels", "bitrate_kbps", "description_b64"]);
      assert.equal(body.audio.codec, limits.audio.codec);
      assert.equal(body.audio.sample_rate, limits.audio.sample_rate_hz);
      assert.equal(body.audio.channels, limits.audio.channels);
      assert.equal(body.audio.bitrate_kbps, limits.audio.bitrate_kbps);
      assertBase64(body.audio.description_b64);
    },
    report(vector) {
      const body = JSON.parse(vector.body_text);
      assertKeys(body, ["backlog_ms", "dropped_video_frames", "target_kbps", "state", "events"], { extensionPrefix: "x_" });
      assertNonNegativeInteger(body.backlog_ms);
      assertNonNegativeInteger(body.dropped_video_frames);
      assertNonNegativeInteger(body.target_kbps);
      assert.ok(["live", "degraded"].includes(body.state));
      assert.ok(Array.isArray(body.events));
      for (const event of body.events) {
        assertKeys(event, ["kind"], { optional: ["detail"] });
        assert.ok(valuesOf("browser_event_kind").includes(event.kind));
        if (event.detail !== undefined) {
          assertEventDetail(event.detail);
        }
      }
    },
    end(vector) {
      const body = JSON.parse(vector.body_text);
      assertKeys(body, ["reason"]);
      assert.ok(["user_stop", "user_cancel", "insufficient_bandwidth"].includes(body.reason));
    },
    accepted(vector) {
      const body = JSON.parse(vector.body_text);
      assertKeys(body, ["state", "resume", "profile", "limits"]);
      assert.ok(valuesOf("broadcast_state").includes(body.state));
      assert.equal(typeof body.resume, "boolean");
      assert.ok(body.profile === null || valuesOf("profile").includes(body.profile));
      assert.equal(body.resume, body.profile !== null, "再開のときだけ、確定済みのプロファイルを持つ");
      assertKeys(body.limits, ["time_limit_seconds"]);
      assert.ok(Number.isInteger(body.limits.time_limit_seconds) && body.limits.time_limit_seconds > 0);
    },
    probe_result(vector) {
      const body = JSON.parse(vector.body_text);
      assertKeys(body, ["throughput_kbps"]);
      assertNonNegativeInteger(body.throughput_kbps);
    },
    ack(vector) {
      const body = JSON.parse(vector.body_text);
      assertKeys(body, ["video_us", "audio_us"]);
      assertNonNegativeInteger(body.video_us);
      assertNonNegativeInteger(body.audio_us);
    },
    throttle(vector) {
      const body = JSON.parse(vector.body_text);
      assertKeys(body, ["target_kbps"]);
      assert.ok(Number.isInteger(body.target_kbps) && body.target_kbps > 0);
    },
    status(vector) {
      const body = JSON.parse(vector.body_text);
      assertKeys(body, ["state", "watch_url", "warning", "time_limit_notice_seconds", "end_reason"]);
      assert.ok(valuesOf("broadcast_state").includes(body.state));
      assert.ok(body.watch_url === null || /^https:\/\/\S+$/.test(body.watch_url));
      assert.ok(body.warning === null || body.warning === "youtube_stream_unhealthy");
      assert.ok(body.time_limit_notice_seconds === null || Number.isInteger(body.time_limit_notice_seconds));
      assert.ok(body.end_reason === null || valuesOf("end_reason").includes(body.end_reason));
      assert.equal(body.state === "ended", body.end_reason !== null, "終了のときだけ、終了理由を持つ");
    },
    fatal(vector) {
      const body = JSON.parse(vector.body_text);
      assertKeys(body, ["code"]);
      assert.ok(valuesOf("fatal_code").includes(body.code));
    },
  };

  function assertKeys(object, required, { optional = [], extensionPrefix = null } = {}) {
    assert.ok(object !== null && typeof object === "object" && !Array.isArray(object));
    const keys = Object.keys(object);
    for (const key of required) {
      assert.ok(keys.includes(key), `必須のキーがありません: ${key}`);
    }
    for (const key of keys) {
      const known = required.includes(key) || optional.includes(key) || (extensionPrefix !== null && key.startsWith(extensionPrefix));
      assert.ok(known, `未知のキー: ${key}`);
    }
  }
  function assertNonNegativeInteger(value) {
    assert.ok(Number.isInteger(value) && value >= 0, `0 以上の整数ではありません: ${value}`);
  }
  function assertBase64(value) {
    assert.match(value, /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/);
    assert.ok(value.length > 0);
  }
  /** 出来事の detail は、符号と数値のみ（文字列の自由記述・入れ子を載せない）。 */
  function assertEventDetail(detail) {
    assert.ok(detail !== null && typeof detail === "object" && !Array.isArray(detail));
    const entries = Object.entries(detail);
    assert.ok(entries.length >= 1 && entries.length <= 4);
    for (const [key, value] of entries) {
      assert.match(key, /^[a-z][a-z0-9_]{0,31}$/);
      assert.ok(Number.isInteger(value) || (typeof value === "string" && /^[a-z0-9_]{1,32}$/.test(value)), `${key}: 符号と数値のみ`);
    }
  }

  for (const vector of vectors.valid) {
    const { type } = vector.decoded;
    if (type in validators) {
      test(`${vector.name}: ${type} の本文の項目が、ws-protocol.md の定めと一致する`, () => {
        validators[type](vector);
      });
    }
  }
});

describe("有効なフレームの網羅（受け入れ条件）", () => {
  const types = (predicate = () => true) => vectors.valid.filter(predicate).map((vector) => vector.decoded.type);

  test("14 種の各 1 例以上", () => {
    for (const type of valuesOf("ws_message_type")) {
      assert.ok(types().includes(type), `${type} の例がありません`);
    }
  });

  test("ブラウザ → 中継の 7 種と、中継 → ブラウザの 7 種の両方向", () => {
    assert.equal(new Set(types((vector) => vector.direction === "browser_to_relay")).size, 7);
    assert.equal(new Set(types((vector) => vector.direction === "relay_to_browser")).size, 7);
  });

  test("キーフレーム（属性 bit0 = 1）の映像と、そうでない映像", () => {
    const videos = vectors.valid.filter((vector) => vector.decoded.type === "video");
    assert.ok(videos.some((vector) => vector.decoded.keyframe === true));
    assert.ok(videos.some((vector) => vector.decoded.keyframe === false));
  });

  const boundaryTimestamps = [
    ["0", "0"],
    ["2^32 - 1", "4294967295"],
    ["2^32", "4294967296"],
    ["2^53 - 1", "9007199254740991"],
    ["2^53", "9007199254740992"],
    ["2^53 + 1", "9007199254740993"],
    ["2^63", "9223372036854775808"],
    ["2^64 - 1", "18446744073709551615"],
  ];
  for (const [label, decimal] of boundaryTimestamps) {
    test(`時刻の境界 ${label}（${decimal}）の例がある`, () => {
      assert.ok(vectors.valid.some((vector) => vector.decoded.timestamp_us === decimal));
    });
  }

  test("時刻の境界の値の検算（2^53 と 2^64 - 1 は、数値のままでは JavaScript で厳密に表せない）", () => {
    assert.equal(String(2n ** 53n), "9007199254740992");
    assert.equal(String(2n ** 64n - 1n), "18446744073709551615");
    assert.notEqual(BigInt(Number(2n ** 53n + 1n)), 2n ** 53n + 1n);
  });

  test("本文長 0 の例（キーフレーム要求）", () => {
    const empty = vectors.valid.filter((vector) => vector.decoded.body_hex === "");
    assert.ok(empty.length >= 1);
    assert.ok(empty.some((vector) => vector.decoded.type === "keyframe_request"));
    for (const vector of empty) {
      assert.equal(vector.hex.length, 2 * HEADER_BYTES);
    }
  });

  test("日本語（UTF-8 の多バイト文字）を含む JSON 本文の例。本文長はバイト数で、文字数より大きい", () => {
    const found = vectors.valid.filter((vector) => {
      if (!JSON_TYPES.includes(vector.decoded.type) || vector.body_text === undefined) {
        return false;
      }
      return /[^\u0000-\u007f]/u.test(vector.body_text);
    });
    assert.ok(found.length >= 1, "日本語を含む JSON 本文がありません");
    for (const vector of found) {
      assert.ok(Buffer.byteLength(vector.body_text, "utf8") > [...vector.body_text].length);
      assert.equal(Buffer.byteLength(vector.body_text, "utf8"), vector.decoded.body_hex.length / 2);
    }
  });

  test("開始通知の例は、2 つのプロファイル（720p・480p）の両方", () => {
    const profiles = vectors.valid
      .filter((vector) => vector.decoded.type === "start")
      .map((vector) => JSON.parse(vector.body_text).profile)
      .sort();
    assert.deepEqual([...new Set(profiles)], ["480p", "720p"]);
  });

  test("映像の時刻は フレーム番号 × 1,000,000 ÷ 30（丸め）、音声の時刻は 累積サンプル数 × 1,000,000 ÷ 44,100（丸め）の例を含む", () => {
    const roundDiv = (numerator, denominator) => (2n * numerator + denominator) / (2n * denominator);
    const videoTimes = new Set(vectors.valid.filter((v) => v.decoded.type === "video").map((v) => v.decoded.timestamp_us));
    const audioTimes = new Set(vectors.valid.filter((v) => v.decoded.type === "audio").map((v) => v.decoded.timestamp_us));
    for (const frame of [0n, 1n, 2n, 30n, 60n]) {
      assert.ok(videoTimes.has(String(roundDiv(frame * 1_000_000n, 30n))), `映像のフレーム ${frame}`);
    }
    for (const samples of [0n, 1024n, 441_000n]) {
      assert.ok(audioTimes.has(String(roundDiv(samples * 1_000_000n, 44_100n))), `音声の累積 ${samples} サンプル`);
    }
    assert.equal(roundDiv(1n * 1_000_000n, 30n), 33_333n);
    assert.equal(roundDiv(2n * 1_000_000n, 30n), 66_667n);
    assert.equal(roundDiv(1024n * 1_000_000n, 44_100n), 23_220n);
  });
});

describe("無効なフレーム", () => {
  for (const vector of vectors.invalid) {
    describe(vector.name, () => {
      test("キーは name・receivers・hex・error（と任意の note）だけ。エラー符号は 7 種のいずれか", () => {
        const allowed = new Set(["name", "receivers", "hex", "error", "note"]);
        for (const key of Object.keys(vector)) {
          assert.ok(allowed.has(key), `未知のキー: ${key}`);
        }
        assert.ok(ERROR_CODES.includes(vector.error), vector.error);
      });

      test("receivers は、relay・browser の空でない部分集合（重複なし）", () => {
        assert.ok(Array.isArray(vector.receivers) && vector.receivers.length >= 1);
        assert.equal(new Set(vector.receivers).size, vector.receivers.length);
        for (const receiver of vector.receivers) {
          assert.ok(RECEIVERS.includes(receiver), receiver);
        }
      });

      test("receivers の受信側は、期待されるエラー符号を得る（検証の順は ws-protocol.md のとおり）", () => {
        const bytes = hexToBytes(vector.hex);
        for (const receiver of vector.receivers) {
          assert.deepEqual(decodeFrame(bytes, receiver), { error: vector.error }, `${receiver} が受信したとき`);
        }
      });

      test("ベクタは短い（2 MB 超も、ヘッダの本文長の欄だけで表す）", () => {
        assert.ok(vector.hex.length <= 2 * 200, `${vector.hex.length / 2} バイト`);
      });
    });
  }
});

describe("無効なフレームの網羅（受け入れ条件）", () => {
  const byError = (error) => vectors.invalid.filter((vector) => vector.error === error);

  for (const error of ERROR_CODES) {
    test(`${error} の例が 1 つ以上ある`, () => {
      assert.ok(byError(error).length >= 1);
    });
  }

  test("方向の誤りは、中継が受けた例と、ブラウザが受けた例の両方がある", () => {
    const receivers = byError("wrong_direction").flatMap((vector) => vector.receivers);
    assert.ok(receivers.includes("relay") && receivers.includes("browser"));
  });

  test("本文長の不一致と 2 MB 超は、どちらの受信側の例もある（種別の方向が受信側に合うものを使う）", () => {
    for (const error of ["length_mismatch", "too_large"]) {
      const receivers = new Set(byError(error).flatMap((vector) => vector.receivers));
      assert.deepEqual([...receivers].sort(), ["browser", "relay"], error);
    }
  });

  test("識別子の誤り・版の誤り・未知の種別・切り詰めは、どちらの受信側でも同じエラーになる例がある", () => {
    for (const error of ["invalid_magic", "unsupported_version", "unknown_type", "truncated_header"]) {
      assert.ok(
        byError(error).some((vector) => vector.receivers.length === 2),
        error,
      );
    }
  });

  test("切り詰めは、空のメッセージ・1 バイト・ヘッダの 1 バイト手前（16 バイト）を含む", () => {
    const lengths = byError("truncated_header").map((vector) => vector.hex.length / 2);
    for (const length of [0, 1, HEADER_BYTES - 1]) {
      assert.ok(lengths.includes(length), `${length} バイトの例`);
    }
  });

  test("2 MB 超は、ヘッダだけ（17 バイト）で、本文長の欄が上限を超える。上限ちょうどは too_large にならない", () => {
    const declaredOf = (vector) => new DataView(hexToBytes(vector.hex).buffer).getUint32(13, false);
    const tooLarge = byError("too_large");
    assert.ok(tooLarge.length >= 2);
    for (const vector of tooLarge) {
      assert.equal(vector.hex.length / 2, HEADER_BYTES, "ヘッダだけではありません");
      assert.ok(HEADER_BYTES + declaredOf(vector) > MAX_MESSAGE_BYTES);
    }
    const declared = tooLarge.map(declaredOf);
    assert.ok(declared.includes(MAX_MESSAGE_BYTES - HEADER_BYTES + 1), "上限を 1 バイト超える例（本文長 2,097,136）");
    assert.ok(declared.includes(0xffffffff), "本文長が符号なし 32 ビットの最大の例");

    // 全体がちょうど上限（本文長 2,097,135）のヘッダだけの例は、too_large ではなく length_mismatch（本文が足りない）
    const atLimit = byError("length_mismatch").filter((vector) => vector.hex.length / 2 === HEADER_BYTES && declaredOf(vector) === MAX_MESSAGE_BYTES - HEADER_BYTES);
    assert.ok(atLimit.length >= 2, "上限ちょうどの境界の例（2 つの受信側）");
  });

  test("本文長の不一致は、本文が足りない・多い・余分な 1 バイトの例を含む", () => {
    const shape = (vector) => {
      const bytes = hexToBytes(vector.hex);
      const declared = new DataView(bytes.buffer).getUint32(13, false);
      const actual = bytes.length - HEADER_BYTES;
      if (actual < declared) return "short";
      if (actual > declared) return declared === 0 ? "trailing_on_empty" : "long";
      return "equal";
    };
    const shapes = new Set(byError("length_mismatch").map(shape));
    for (const expected of ["short", "long", "trailing_on_empty"]) {
      assert.ok(shapes.has(expected), expected);
    }
  });

  test("検証の順の例（先に該当する誤りを返す）が、名前 precedence_ で含まれる", () => {
    const names = vectors.invalid.map((vector) => vector.name).filter((name) => name.startsWith("precedence_"));
    assert.ok(names.length >= 5, names.join(", "));
  });

  test("受信側が受理する方向の表（INCOMING_DIRECTION）は、中継 = ブラウザ → 中継、ブラウザ = 中継 → ブラウザ", () => {
    assert.deepEqual(INCOMING_DIRECTION, { relay: "browser_to_relay", browser: "relay_to_browser" });
  });
});

describe("文書用のキー", () => {
  test("ベクタのキーに、文書用のキー（note）を使うのは、各ベクタの note だけ", () => {
    for (const vector of [...vectors.valid, ...vectors.invalid]) {
      for (const key of Object.keys(vector)) {
        if (isDocumentKey(key)) {
          assert.equal(key, "note");
          assert.equal(typeof vector[key], "string");
        }
      }
    }
  });
});
