// 本文（JSON）の検証と正規化（ws-protocol.md の 5 章）。
//
// 各 parse 関数は、受け取った値（unknown。JSON.parse の結果、または送ろうとする内容）から、既知の項目だけを、契約の順に取り出した、
// 新しいオブジェクトを返す（入力と共有しない。JSON.stringify すると、共有テストベクタと同じ並びになる）。
//   - 未知のキー（x_ で始まる拡張のキーを含む）は無視する（前方互換。5.5）。結果にも含めない（余計な項目を送らない）
//   - 必須の項目が無い（null を許す項目も、省略はできない）・型や値が不正は、FrameError（invalid_body）。詳細は、項目の名前と期待する形だけで、値を含めない
//   - 項目は、自分のプロパティだけを読む（継承されたプロパティを、項目として読まない）
// 受信（中継 → ブラウザ）の検証と、送信（ブラウザ → 中継）の検証は、同じ関数を使う。

import { BROADCAST_STATE_VALUES, BROWSER_EVENT_KIND_VALUES, END_REASON_VALUES, FATAL_CODE_VALUES, LIMITS, PROFILE_VALUES } from "../contract";
import { decodeBase64 } from "./base64";
import { FrameError } from "./errors";
import {
  BROWSER_END_REASON_VALUES,
  REPORT_STATE_VALUES,
  STATUS_WARNING_VALUES,
  WATCH_URL_HOSTS,
} from "./messages";
import type {
  AcceptedBody,
  AckBody,
  EndBody,
  EventDetail,
  EventDetailValue,
  FatalBody,
  ProbeResultBody,
  ReportBody,
  ReportEvent,
  StartBody,
  StatusBody,
  ThrottleBody,
} from "./messages";

type JsonObject = { readonly [key: string]: unknown };
type Validator<T> = (value: unknown, path: string) => T;

/** 出来事の detail の、キー・値（符号）の形と、組の数の上限（ws-protocol.md の 5.6）。 */
const DETAIL_KEY = /^[a-z][a-z0-9_]{0,31}$/;
const DETAIL_CODE = /^[a-z0-9_]{1,32}$/;
const DETAIL_MAX_ENTRIES = 4;

/** 接続チケット：URL 安全な文字列（印字できる ASCII。空白・制御文字を含まない）。 */
const TICKET_PATTERN = /^[\x21-\x7e]+$/;

/**
 * 視聴 URL の形：https:// + ホスト（半角の英数字・ドット・ハイフンだけ。ユーザー情報（@）・ポート（:）を持たない）+ 省略できる残り（/ ? # から始まる）。
 * 残りは、印字できる ASCII（空白・制御文字・DEL・ASCII 以外を含まない）で、バックスラッシュを含まない（ブラウザが / として扱い、ホストの読みが分かれるため）。
 * ホストは、WATCH_URL_HOSTS のどれかと完全に一致すること（大文字・末尾のドット・サブドメインは拒否する）。
 */
const WATCH_URL_PATTERN = /^https:\/\/([a-z0-9.-]+)(?:[/?#][\x21-\x5b\x5d-\x7e]*)?$/;

function fail(path: string, expectation: string): never {
  throw new FrameError("invalid_body", `${path}: ${expectation}`);
}

function asObject(value: unknown, path: string): JsonObject {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return fail(path, "must be an object");
  }
  return value as JsonObject;
}

function hasOwn(object: JsonObject, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(object, key);
}

function fieldOf(object: JsonObject, key: string, path: string): unknown {
  if (!hasOwn(object, key)) {
    return fail(`${path}.${key}`, "is required");
  }
  return object[key];
}

/** 必須の項目を読み、検証する。 */
function required<T>(object: JsonObject, key: string, path: string, validate: Validator<T>): T {
  return validate(fieldOf(object, key, path), `${path}.${key}`);
}

/** 必須の項目（null を許す。省略はできない）を読み、null でなければ検証する。 */
function requiredOrNull<T>(object: JsonObject, key: string, path: string, validate: Validator<T>): T | null {
  const value = fieldOf(object, key, path);
  return value === null ? null : validate(value, `${path}.${key}`);
}

const booleanValue: Validator<boolean> = (value, path) => {
  if (typeof value !== "boolean") {
    return fail(path, "must be a boolean");
  }
  return value;
};

const stringValue: Validator<string> = (value, path) => {
  if (typeof value !== "string") {
    return fail(path, "must be a string");
  }
  return value;
};

/** 視聴 URL：https の YouTube のホスト（WATCH_URL_HOSTS）だけ。検査した文字列を、そのまま返す。詳細に値（ホスト・パス・資格情報）を含めない。 */
const watchUrlValue: Validator<string> = (value, path) => {
  const text = stringValue(value, path);
  const match = WATCH_URL_PATTERN.exec(text);
  if (match === null || !(WATCH_URL_HOSTS as readonly string[]).includes(match[1])) {
    return fail(path, `must be an https URL on one of these hosts: ${WATCH_URL_HOSTS.join(", ")}`);
  }
  return text;
};

/** minimum 以上の安全整数（小数・NaN・無限大・安全整数を超える値は拒否する）。 */
function integerAtLeast(minimum: number): Validator<number> {
  return (value, path) => {
    if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum) {
      return fail(path, `must be a safe integer of at least ${minimum}`);
    }
    return value;
  };
}

function integerBetween(minimum: number, maximum: number): Validator<number> {
  const atLeast = integerAtLeast(minimum);
  return (value, path) => {
    const number = atLeast(value, path);
    if (number > maximum) {
      return fail(path, `must be a safe integer from ${minimum} to ${maximum}`);
    }
    return number;
  };
}

function oneOf<T extends string>(values: readonly T[]): Validator<T> {
  return (value, path) => {
    if (typeof value !== "string" || !(values as readonly string[]).includes(value)) {
      return fail(path, `must be one of ${values.join(", ")}`);
    }
    return value as T;
  };
}

/** 契約が固定する値（コーデック・サンプルレートなど）と、完全に一致すること。 */
function exactly<T extends string | number>(expected: T): Validator<T> {
  return (value, path) => {
    if (value !== expected) {
      return fail(path, `must equal ${String(expected)}`);
    }
    return expected;
  };
}

/** 復号器設定：空でない、正規形の base64。 */
const decoderConfigBase64: Validator<string> = (value, path) => {
  const text = stringValue(value, path);
  if (text.length === 0) {
    return fail(path, "must not be empty");
  }
  try {
    decodeBase64(text);
  } catch {
    return fail(path, "must be canonical base64 (standard alphabet, with padding)");
  }
  return text;
};

/** 接続チケット（hello の本文）。送る内容の不備なので invalid_message。値は、エラーに含めない。 */
export function parseHelloTicket(value: unknown): string {
  if (typeof value !== "string" || !TICKET_PATTERN.test(value)) {
    throw new FrameError("invalid_message", "ticket must be a non-empty string of printable ASCII characters without spaces");
  }
  return value;
}

/** 開始通知（5.3）。プロファイルを決めると、映像の幅・高さ・フレームレートと、ビットレートの範囲も決まる（契約の LIMITS.profiles）。 */
export function parseStartBody(value: unknown): StartBody {
  const root = asObject(value, "start");
  const profile = required(root, "profile", "start", oneOf(PROFILE_VALUES));
  const limits = LIMITS.profiles[profile];

  const video = asObject(fieldOf(root, "video", "start"), "start.video");
  const audio = asObject(fieldOf(root, "audio", "start"), "start.audio");
  const videoPath = "start.video";
  const audioPath = "start.audio";

  return {
    profile,
    video: {
      codec: required(video, "codec", videoPath, oneOf([LIMITS.video.codec_main, LIMITS.video.codec_constrained_baseline])),
      width: required(video, "width", videoPath, exactly(limits.width)),
      height: required(video, "height", videoPath, exactly(limits.height)),
      framerate: required(video, "framerate", videoPath, exactly(limits.framerate)),
      bitrate_kbps: required(video, "bitrate_kbps", videoPath, integerBetween(limits.video_bitrate_min_kbps, limits.video_bitrate_max_kbps)),
      description_b64: required(video, "description_b64", videoPath, decoderConfigBase64),
    },
    audio: {
      codec: required(audio, "codec", audioPath, exactly(LIMITS.audio.codec)),
      sample_rate: required(audio, "sample_rate", audioPath, exactly(LIMITS.audio.sample_rate_hz)),
      channels: required(audio, "channels", audioPath, exactly(LIMITS.audio.channels)),
      bitrate_kbps: required(audio, "bitrate_kbps", audioPath, exactly(LIMITS.audio.bitrate_kbps)),
      description_b64: required(audio, "description_b64", audioPath, decoderConfigBase64),
    },
  };
}

/** 出来事の detail：符号と数値のみ。自由記述・デバイス名・ラベル・入れ子・配列・null を載せない（5.6）。 */
function parseEventDetail(value: unknown, path: string): EventDetail {
  const object = asObject(value, path);
  const keys = Object.keys(object);
  if (keys.length > DETAIL_MAX_ENTRIES) {
    return fail(path, `must have at most ${DETAIL_MAX_ENTRIES} entries`);
  }
  const detail: Record<string, EventDetailValue> = {};
  for (const key of keys) {
    if (!DETAIL_KEY.test(key)) {
      return fail(path, "has a key that is not a code (^[a-z][a-z0-9_]{0,31}$)");
    }
    const entry = object[key];
    const isInteger = typeof entry === "number" && Number.isSafeInteger(entry);
    const isCode = typeof entry === "string" && DETAIL_CODE.test(entry);
    if (!isInteger && !isCode) {
      return fail(`${path}.${key}`, "must be a safe integer or a code (^[a-z0-9_]{1,32}$)");
    }
    detail[key] = entry as EventDetailValue;
  }
  return detail;
}

function parseReportEvents(value: unknown, path: string): ReportEvent[] {
  if (!Array.isArray(value)) {
    return fail(path, "must be an array");
  }
  return value.map((item: unknown, index: number): ReportEvent => {
    const itemPath = `${path}[${index}]`;
    const event = asObject(item, itemPath);
    const kind = required(event, "kind", itemPath, oneOf(BROWSER_EVENT_KIND_VALUES));
    if (!hasOwn(event, "detail")) {
      return { kind };
    }
    return { kind, detail: parseEventDetail(event.detail, `${itemPath}.detail`) };
  });
}

/** 状態報告（5.6）。 */
export function parseReportBody(value: unknown): ReportBody {
  const root = asObject(value, "report");
  return {
    backlog_ms: required(root, "backlog_ms", "report", integerAtLeast(0)),
    dropped_video_frames: required(root, "dropped_video_frames", "report", integerAtLeast(0)),
    target_kbps: required(root, "target_kbps", "report", integerAtLeast(1)),
    state: required(root, "state", "report", oneOf(REPORT_STATE_VALUES)),
    events: parseReportEvents(fieldOf(root, "events", "report"), "report.events"),
  };
}

/** 終了通知（5.7）。ブラウザが伝えられる 3 つの理由だけ。 */
export function parseEndBody(value: unknown): EndBody {
  const root = asObject(value, "end");
  return { reason: required(root, "reason", "end", oneOf(BROWSER_END_REASON_VALUES)) };
}

/** 接続受理（5.8）。 */
export function parseAcceptedBody(value: unknown): AcceptedBody {
  const root = asObject(value, "accepted");
  const limits = asObject(fieldOf(root, "limits", "accepted"), "accepted.limits");
  return {
    state: required(root, "state", "accepted", oneOf(BROADCAST_STATE_VALUES)),
    resume: required(root, "resume", "accepted", booleanValue),
    profile: requiredOrNull(root, "profile", "accepted", oneOf(PROFILE_VALUES)),
    limits: { time_limit_seconds: required(limits, "time_limit_seconds", "accepted.limits", integerAtLeast(0)) },
  };
}

/** 計測結果（5.9）。 */
export function parseProbeResultBody(value: unknown): ProbeResultBody {
  const root = asObject(value, "probe_result");
  return { throughput_kbps: required(root, "throughput_kbps", "probe_result", integerAtLeast(0)) };
}

/** 受領応答（5.10）。 */
export function parseAckBody(value: unknown): AckBody {
  const root = asObject(value, "ack");
  return {
    video_us: required(root, "video_us", "ack", integerAtLeast(0)),
    audio_us: required(root, "audio_us", "ack", integerAtLeast(0)),
  };
}

/** 抑制指示（5.12）。目標ビットレートは正の整数。 */
export function parseThrottleBody(value: unknown): ThrottleBody {
  const root = asObject(value, "throttle");
  return { target_kbps: required(root, "target_kbps", "throttle", integerAtLeast(1)) };
}

/** 状態通知（5.13）。毎回、状態の全体（スナップショット）。null の項目も、省略はできない。 */
export function parseStatusBody(value: unknown): StatusBody {
  const root = asObject(value, "status");
  return {
    state: required(root, "state", "status", oneOf(BROADCAST_STATE_VALUES)),
    watch_url: requiredOrNull(root, "watch_url", "status", watchUrlValue),
    warning: requiredOrNull(root, "warning", "status", oneOf(STATUS_WARNING_VALUES)),
    time_limit_notice_seconds: requiredOrNull(root, "time_limit_notice_seconds", "status", integerAtLeast(0)),
    end_reason: requiredOrNull(root, "end_reason", "status", oneOf(END_REASON_VALUES)),
  };
}

/** 致命通知（5.14）。 */
export function parseFatalBody(value: unknown): FatalBody {
  const root = asObject(value, "fatal");
  return { code: required(root, "code", "fatal", oneOf(FATAL_CODE_VALUES)) };
}
