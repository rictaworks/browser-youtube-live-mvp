// ブラウザへの問い合わせ（requirements.md 16.6・30.1。実測と事前確認は WORK/factcheck/20261007_external-facts.md の項目 10〜12）。
// 環境オブジェクト（window に当たるもの）を注入して、非同期の検出の結果（CapabilityReport）にする。window・navigator などの大域を直接参照しない。
//
//   - H.264：VideoEncoder.isConfigSupported。Main（avc1.4D401F）を先に、使えなければ Constrained Baseline（avc1.42E01F）。
//     プロファイルは配信の開始時に回線計測で決まるため、両プロファイル（720p・480p）の設定が使えるコーデック文字列だけを「使える」とする
//   - AAC-LC：AudioEncoder.isConfigSupported（mp4a.40.2・44.1 kHz・2 ch・128 kbps・aac 形式）。
//     Chrome の AAC エンコードは Windows（N エディションを除く）・macOS・Android のみで、Linux・ChromeOS・Firefox では使えない（canStart が偽になるのが設計どおり）
//   - ワーカー上でのフレーム取得と描画：MediaStreamTrackProcessor は Window で検査する（Chrome ではワーカー内で使えず、MediaStreamTrack も転送できない）。
//     ReadableStream の転送可否は structuredClone で検査し、ワーカー内の OffscreenCanvas・VideoFrame の有無は、小さなワーカーを実際に起動して検査する
//   - AudioWorklet・WebSocket・画面共有 API（getDisplayMedia）・タブ間の排他（navigator.locks）は、存在の検査
//   - 判定できない（例外・応答なし・不正な応答）ものは、能力なし（拒否側。9.3）として扱い、失敗の記録に、検査の名前とエラーの名前だけを残す
//   - ブラウザの名称・版（userAgent など）は読まない
//
// 注意（CSP）：検査用のワーカーは、Blob URL で起動する。サイトに Content-Security-Policy を設けるときは、worker-src（なければ child-src・script-src・
// default-src）が blob: を許す必要がある。許さないと、ワーカーの起動が禁じられ、ワーカー内の可否は「能力なし」になる（canStart が偽になる）。
// 実ブラウザの確認は、test/ の probe_capabilities.cjs（worker-src 'self' のページで、検出が終わり、拒否側になること）。

import { LIMITS, PROFILE_VALUES } from "../contract";
import type { Profile } from "../contract";
import { callMember, construct, errorNameOf, isFunction, isObjectLike, readMember, readPath } from "./featureDetect";
import type { BrowserGlobals, CapabilityReport, FrameCaptureReport, ProbeFailure } from "./types";

/** ワーカーが応答しないときの期限（ミリ秒）。超えたら、ワーカーの検査は、能力なしとして終える。 */
export const WORKER_PROBE_TIMEOUT_MS = 5_000;

const WORKER_PROBE_REQUEST = "probe";

/**
 * ワーカーの中で実行する、小さなスクリプト（ASCII のみ）。メッセージを受けたら、ワーカー内の OffscreenCanvas と VideoFrame の typeof を 1 回返す。
 * MediaStreamTrackProcessor は、Window で検査するため、ここでは調べない。
 */
export const WORKER_PROBE_SOURCE = [
  "self.onmessage = function () {",
  "  self.postMessage({ offscreenCanvas: typeof OffscreenCanvas, videoFrame: typeof VideoFrame });",
  "};",
].join("\n");

/** 検査の結果と、その検査の失敗の記録。 */
interface ProbeOutcome<T> {
  readonly value: T;
  readonly failures: readonly ProbeFailure[];
}

type ProbeErrorName = "ProbeTimeout" | "ProbeWorkerError" | "ProbeMalformedReply" | "ProbeTimerUnavailable";

/** この検出が自ら起こす失敗（ワーカーの応答なし・エラー・不正な応答・タイマーが無い）。名前が、失敗の記録に残る。 */
class ProbeError extends Error {
  constructor(name: ProbeErrorName) {
    super(name);
    this.name = name;
  }
}

function failure(probe: ProbeFailure["probe"], error: unknown): ProbeFailure {
  return { probe, errorName: errorNameOf(error) };
}

// ---------------------------------------------------------------------------
// エンコーダ（isConfigSupported）
// ---------------------------------------------------------------------------

const VIDEO_CODEC_CANDIDATES = [LIMITS.video.codec_main, LIMITS.video.codec_constrained_baseline] as const;

function hasConfigSupportedMethod(encoder: unknown): boolean {
  return isObjectLike(encoder) && isFunction(readMember(encoder, "isConfigSupported"));
}

/** 11.7 の映像エンコードの設定：avc 形式（AVCC）・低遅延（並べ替えフレームを作らない）・固定ビットレート・初期ビットレート。 */
function videoConfig(codec: string, profile: Profile): Record<string, unknown> {
  const limits = LIMITS.profiles[profile];
  return {
    codec,
    width: limits.width,
    height: limits.height,
    bitrate: limits.video_bitrate_initial_kbps * 1_000,
    framerate: limits.framerate,
    bitrateMode: "constant",
    latencyMode: "realtime",
    avc: { format: "avc" },
  };
}

function audioConfig(): Record<string, unknown> {
  return {
    codec: LIMITS.audio.codec,
    sampleRate: LIMITS.audio.sample_rate_hz,
    numberOfChannels: LIMITS.audio.channels,
    bitrate: LIMITS.audio.bitrate_kbps * 1_000,
    aac: { format: "aac" },
  };
}

/** 応答の supported が、真偽値の true のときだけ「使える」。 */
function isSupportedAnswer(answer: unknown): boolean {
  return readMember(answer, "supported") === true;
}

async function probeVideoCodec(env: BrowserGlobals): Promise<ProbeOutcome<string | null>> {
  const encoder = readMember(env, "VideoEncoder");
  if (!hasConfigSupportedMethod(encoder)) {
    return { value: null, failures: [] };
  }
  const failures: ProbeFailure[] = [];
  for (const codec of VIDEO_CODEC_CANDIDATES) {
    try {
      const answers = await Promise.all(PROFILE_VALUES.map((profile) => callMember(encoder, "isConfigSupported", [videoConfig(codec, profile)])));
      if (answers.every(isSupportedAnswer)) {
        return { value: codec, failures };
      }
    } catch (error) {
      // このコーデックは判定できない（使えないものとして、次の候補へ）。失敗は記録する
      failures.push(failure("h264_encode", error));
    }
  }
  return { value: null, failures };
}

async function probeAac(env: BrowserGlobals): Promise<ProbeOutcome<boolean>> {
  const encoder = readMember(env, "AudioEncoder");
  if (!hasConfigSupportedMethod(encoder)) {
    return { value: false, failures: [] };
  }
  try {
    const answer = await callMember(encoder, "isConfigSupported", [audioConfig()]);
    return { value: isSupportedAnswer(answer), failures: [] };
  } catch (error) {
    return { value: false, failures: [failure("aac_encode", error)] };
  }
}

// ---------------------------------------------------------------------------
// ReadableStream の転送（structuredClone）
// ---------------------------------------------------------------------------

/** ReadableStream を、transfer 付きの structuredClone で転送できるか。DataCloneError は「転送できない」という結果で、失敗の記録ではない。 */
function probeReadableStreamTransfer(env: BrowserGlobals): ProbeOutcome<boolean> {
  const streamConstructor = readMember(env, "ReadableStream");
  if (!isFunction(streamConstructor) || !isFunction(readMember(env, "structuredClone"))) {
    return { value: false, failures: [] };
  }
  try {
    const stream = construct(streamConstructor, []);
    callMember(env, "structuredClone", [stream, { transfer: [stream] }]);
    return { value: true, failures: [] };
  } catch (error) {
    const name = errorNameOf(error);
    return { value: false, failures: name === "DataCloneError" ? [] : [failure("readable_stream_transfer", error)] };
  }
}

// ---------------------------------------------------------------------------
// ワーカー（小さなワーカーを実際に起動して、ワーカー内の可否を検査する）
// ---------------------------------------------------------------------------

interface WorkerFacts {
  readonly offscreenCanvas: boolean;
  readonly videoFrame: boolean;
}

const NO_WORKER_FACTS: WorkerFacts = Object.freeze({ offscreenCanvas: false, videoFrame: false });

function parseWorkerReply(reply: unknown): WorkerFacts {
  const offscreenCanvas = readMember(reply, "offscreenCanvas");
  const videoFrame = readMember(reply, "videoFrame");
  if (typeof offscreenCanvas !== "string" || typeof videoFrame !== "string") {
    throw new ProbeError("ProbeMalformedReply");
  }
  return { offscreenCanvas: offscreenCanvas === "function", videoFrame: videoFrame === "function" };
}

/** ワーカーを起動できる環境か（Worker・Blob・URL.createObjectURL がある）。無ければ、ワーカー内の能力は無い（失敗ではなく、能力が無いという結果）。 */
function canStartProbeWorker(env: BrowserGlobals): boolean {
  return (
    isFunction(readMember(env, "Worker")) &&
    isFunction(readMember(env, "Blob")) &&
    isFunction(readPath(env, ["URL", "createObjectURL"])) &&
    isFunction(readPath(env, ["URL", "revokeObjectURL"]))
  );
}

/** 起動したものの後始末の記録。後始末に失敗しても、検査の結果は変えず、失敗の記録に加える。 */
interface WorkerProbeResources {
  timer?: unknown;
  worker?: unknown;
  objectUrl?: unknown;
}

function cleanUp(env: BrowserGlobals, resources: WorkerProbeResources): ProbeFailure[] {
  const failures: ProbeFailure[] = [];
  const attempt = (step: () => unknown): void => {
    try {
      step();
    } catch (error) {
      failures.push(failure("worker_probe", error));
    }
  };
  if (resources.timer !== undefined) {
    attempt(() => callMember(env, "clearTimeout", [resources.timer]));
  }
  if (resources.worker !== undefined) {
    attempt(() => callMember(resources.worker, "terminate", []));
  }
  if (resources.objectUrl !== undefined) {
    attempt(() => callMember(readMember(env, "URL"), "revokeObjectURL", [resources.objectUrl]));
  }
  return failures;
}

async function probeWorker(env: BrowserGlobals): Promise<ProbeOutcome<WorkerFacts>> {
  if (!canStartProbeWorker(env)) {
    return { value: NO_WORKER_FACTS, failures: [] };
  }
  if (!isFunction(readMember(env, "setTimeout")) || !isFunction(readMember(env, "clearTimeout"))) {
    // 応答の期限を設けられないまま、ワーカーを起動しない（応答が無ければ、検出が終わらなくなるため）
    return { value: NO_WORKER_FACTS, failures: [failure("worker_probe", new ProbeError("ProbeTimerUnavailable"))] };
  }

  const resources: WorkerProbeResources = {};
  let outcome: ProbeOutcome<WorkerFacts>;
  try {
    const blob = construct(readMember(env, "Blob"), [[WORKER_PROBE_SOURCE], { type: "text/javascript" }]);
    resources.objectUrl = callMember(readMember(env, "URL"), "createObjectURL", [blob]);
    resources.worker = construct(readMember(env, "Worker"), [resources.objectUrl]);
    const worker = resources.worker;
    const reply = await new Promise<unknown>((resolve, reject) => {
      callMember(worker, "addEventListener", ["message", (event: unknown) => resolve(readMember(event, "data"))]);
      callMember(worker, "addEventListener", ["error", () => reject(new ProbeError("ProbeWorkerError"))]);
      callMember(worker, "addEventListener", ["messageerror", () => reject(new ProbeError("ProbeWorkerError"))]);
      resources.timer = callMember(env, "setTimeout", [() => reject(new ProbeError("ProbeTimeout")), WORKER_PROBE_TIMEOUT_MS]);
      callMember(worker, "postMessage", [WORKER_PROBE_REQUEST]);
    });
    outcome = { value: parseWorkerReply(reply), failures: [] };
  } catch (error) {
    outcome = { value: NO_WORKER_FACTS, failures: [failure("worker_probe", error)] };
  }
  return { value: outcome.value, failures: [...outcome.failures, ...cleanUp(env, resources)] };
}

// ---------------------------------------------------------------------------
// 検出
// ---------------------------------------------------------------------------

/**
 * ブラウザの能力を検出して、結果（CapabilityReport）にする。
 * 注入する環境（BrowserGlobals）は、window に当たるオブジェクト。検査は並行して行い、1 つの検査の失敗が、他の検査を妨げない。
 * 環境がオブジェクトでなければ TypeError（注入の誤り）。
 */
export async function readBrowserCapabilities(env: BrowserGlobals): Promise<CapabilityReport> {
  if (!isObjectLike(env)) {
    throw new TypeError("env must be an object (the browser's global scope)");
  }
  const [video, aac, transfer, worker] = await Promise.all([probeVideoCodec(env), probeAac(env), probeReadableStreamTransfer(env), probeWorker(env)]);

  const frameCapture: FrameCaptureReport = Object.freeze({
    trackProcessorInWindow: isFunction(readMember(env, "MediaStreamTrackProcessor")),
    readableStreamTransfer: transfer.value,
    offscreenCanvasInWorker: worker.value.offscreenCanvas,
    videoFrameInWorker: worker.value.videoFrame,
  });
  return Object.freeze({
    videoCodec: video.value,
    aacEncode: aac.value,
    frameCapture,
    audioWorklet: isFunction(readMember(env, "AudioWorkletNode")),
    webSocket: isFunction(readMember(env, "WebSocket")),
    screenCapture: isFunction(readPath(env, ["navigator", "mediaDevices", "getDisplayMedia"])),
    tabLock: isFunction(readPath(env, ["navigator", "locks", "request"])),
    failures: Object.freeze([...video.failures, ...aac.failures, ...transfer.failures, ...worker.failures]),
  });
}
