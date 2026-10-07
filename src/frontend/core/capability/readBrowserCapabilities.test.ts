/**
 * @jest-environment node
 */
// ブラウザへの問い合わせ（requirements.md 16.6・30.1。issue #24）。環境オブジェクト（window に当たるもの）を注入して、非同期の検出の結果（report）にする。
//   - H.264：VideoEncoder.isConfigSupported（Main -> Constrained Baseline の順。両プロファイル（720p・480p）で使える最初のコーデック文字列）
//   - AAC-LC：AudioEncoder.isConfigSupported（mp4a.40.2・44.1 kHz・2 ch・128 kbps）
//   - MediaStreamTrackProcessor は Window で検査する（Chrome ではワーカー内で使えない）。ワーカー内の可否は、小さなワーカーを実際に起動して検査する
//     （typeof OffscreenCanvas・VideoFrame）。ReadableStream の転送可否は structuredClone で検査する
//   - AudioWorklet・WebSocket・getDisplayMedia・navigator.locks は、存在の検査
//   - 判定できない（例外・応答なし・不正な応答）ものは、能力なし（拒否側）として扱い、失敗の記録（failures）に、検査の名前とエラーの名前だけを残す
//
// モックの境界：実ブラウザの H.264・AAC のエンコーダ、実際の Worker・Blob URL・structuredClone は、このテストでは使わない（疑似）。
// ただし、ワーカーの検査のスクリプト（WORKER_PROBE_SOURCE）は、Node の vm で、実際に実行して検査する（疑似のワーカーが、ワーカーの大域に当たる物を与える）。
// 実ブラウザ（Playwright の Chromium）での検証は、test/ の手順（README）にある。
import vm from "node:vm";
import { LIMITS } from "../contract";
import { evaluateCapabilities } from "./evaluateCapabilities";
import { WORKER_PROBE_SOURCE, WORKER_PROBE_TIMEOUT_MS, readBrowserCapabilities } from "./readBrowserCapabilities";
import type { BrowserGlobals, CapabilityReport } from "./types";

const MAIN = LIMITS.video.codec_main;
const BASELINE = LIMITS.video.codec_constrained_baseline;

// 型の互換（コンパイル時の検査。tsc --noEmit が確かめる）：本物の window を、そのまま注入できる
const acceptsWindow = (target: Window & typeof globalThis): BrowserGlobals => target;
void acceptsWindow;

interface VideoConfig {
  readonly codec: string;
  readonly width: number;
  readonly height: number;
  readonly bitrate: number;
  readonly framerate: number;
  readonly bitrateMode: string;
  readonly latencyMode: string;
  readonly avc: { readonly format: string };
}

interface AudioConfig {
  readonly codec: string;
  readonly sampleRate: number;
  readonly numberOfChannels: number;
  readonly bitrate: number;
  readonly aac: { readonly format: string };
}

type Listener = (event: unknown) => void;

/** DOMException のように、名前で種類を示すエラー。 */
function namedError(name: string, message = name): Error {
  return Object.assign(new Error(message), { name });
}

class FakeReadableStream {
  readonly kind = "fake-readable-stream";
}

interface FakeTimer {
  readonly id: number;
  readonly callback: () => void;
  readonly milliseconds: number;
  cleared: boolean;
  fired: boolean;
}

/** 疑似のワーカー。受け取ったスクリプトを、Node の vm で、疑似のワーカーの大域（self と、与えた物）の中で実際に実行する。 */
class FakeWorker {
  terminated = false;
  private readonly listeners = new Map<string, Listener[]>();
  private readonly scope: { onmessage: ((event: { data: unknown }) => void) | null; postMessage: (data: unknown) => void };

  constructor(
    private readonly browser: FakeBrowser,
    url: string,
  ) {
    browser.createdWorkers.push(this);
    if (browser.workerStartup === "constructor_throws") {
      throw namedError("SecurityError", "the worker could not be started");
    }
    const source = browser.blobSources.get(url);
    if (source === undefined) {
      throw namedError("NetworkError", `unknown url ${url}`);
    }
    this.scope = { onmessage: null, postMessage: (data) => this.fromWorker(data) };
    vm.runInNewContext(source, { self: this.scope, ...browser.workerGlobals });
    if (browser.workerStartup === "error_event") {
      queueMicrotask(() => this.dispatch("error", { message: "worker failed" }));
    }
  }

  addEventListener(type: string, listener: Listener): void {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), listener]);
  }

  postMessage(message: unknown): void {
    this.browser.postedToWorkers.push(message);
    queueMicrotask(() => {
      if (!this.terminated && this.scope.onmessage !== null) {
        this.scope.onmessage({ data: message });
      }
    });
  }

  terminate(): void {
    this.terminated = true;
  }

  private fromWorker(data: unknown): void {
    if (this.browser.workerStartup === "silent") {
      return;
    }
    const reply = this.browser.workerReply === null ? data : this.browser.workerReply(data);
    queueMicrotask(() => {
      if (!this.terminated) {
        this.dispatch("message", { data: reply });
      }
    });
  }

  private dispatch(type: string, event: unknown): void {
    for (const listener of this.listeners.get(type) ?? []) {
      listener(event);
    }
  }
}

/** browser の疑似のワーカーを作るコンストラクタ（env.Worker）。 */
function workerConstructorOf(browser: FakeBrowser): new (url: string) => FakeWorker {
  return class extends FakeWorker {
    constructor(url: string) {
      super(browser, url);
    }
  };
}

/** browser の疑似の Blob（env.Blob）。種類（type）を記録する。 */
function blobConstructorOf(browser: FakeBrowser): new (parts: string[], options?: { type?: string }) => { readonly parts: string[] } {
  return class FakeBlob {
    constructor(
      readonly parts: string[],
      options?: { type?: string },
    ) {
      browser.blobTypes.push(options?.type);
    }
  };
}

/** 疑似のブラウザ。window に当たる環境オブジェクト（env()）と、呼び出しの記録を持つ。既定は、すべての能力がそろう。 */
class FakeBrowser {
  // ---- 構成（テストごとに変える） ----
  videoSupport: ((config: VideoConfig) => boolean | Error | { readonly supported?: unknown }) | null = () => true;
  audioSupport: ((config: AudioConfig) => boolean | Error | { readonly supported?: unknown }) | null = () => true;
  hasTrackProcessor = true;
  hasAudioWorklet = true;
  hasWebSocket = true;
  hasDisplayMedia = true;
  hasLocks = true;
  hasNavigator = true;
  hasReadableStream = true;
  streamTransfer: "ok" | "absent" | Error = "ok";
  hasWorker = true;
  hasBlob = true;
  hasUrl = true;
  hasTimers = true;
  workerGlobals: Record<string, unknown> = { OffscreenCanvas: function OffscreenCanvas() {}, VideoFrame: function VideoFrame() {} };
  workerStartup: "ok" | "constructor_throws" | "error_event" | "silent" = "ok";
  workerReply: ((reply: unknown) => unknown) | null = null;
  navigatorOverride: unknown = undefined;

  // ---- 記録 ----
  readonly videoConfigs: VideoConfig[] = [];
  readonly audioConfigs: AudioConfig[] = [];
  readonly cloneCalls: Array<{ readonly value: unknown; readonly options: unknown }> = [];
  readonly createdWorkers: FakeWorker[] = [];
  readonly postedToWorkers: unknown[] = [];
  readonly revokedUrls: string[] = [];
  readonly blobSources = new Map<string, string>();
  readonly blobTypes: Array<string | undefined> = [];
  readonly timers: FakeTimer[] = [];

  fireTimers(): void {
    for (const timer of this.timers) {
      if (!timer.cleared && !timer.fired) {
        timer.fired = true;
        timer.callback();
      }
    }
  }

  env(): BrowserGlobals {
    const env: Record<string, unknown> = {};

    if (this.videoSupport !== null) {
      const support = this.videoSupport;
      env.VideoEncoder = {
        isConfigSupported: (config: VideoConfig) => {
          this.videoConfigs.push(config);
          const answer = support(config);
          if (answer instanceof Error) {
            return Promise.reject(answer);
          }
          return Promise.resolve(typeof answer === "boolean" ? { supported: answer, config } : answer);
        },
      };
    }
    if (this.audioSupport !== null) {
      const support = this.audioSupport;
      env.AudioEncoder = {
        isConfigSupported: (config: AudioConfig) => {
          this.audioConfigs.push(config);
          const answer = support(config);
          if (answer instanceof Error) {
            return Promise.reject(answer);
          }
          return Promise.resolve(typeof answer === "boolean" ? { supported: answer, config } : answer);
        },
      };
    }
    if (this.hasTrackProcessor) {
      env.MediaStreamTrackProcessor = function MediaStreamTrackProcessor() {};
    }
    if (this.hasAudioWorklet) {
      env.AudioWorkletNode = function AudioWorkletNode() {};
    }
    if (this.hasWebSocket) {
      env.WebSocket = function WebSocket() {};
    }
    if (this.hasReadableStream) {
      env.ReadableStream = FakeReadableStream;
    }
    if (this.streamTransfer !== "absent") {
      env.structuredClone = (value: unknown, options: unknown) => {
        this.cloneCalls.push({ value, options });
        if (this.streamTransfer instanceof Error) {
          throw this.streamTransfer;
        }
        return new FakeReadableStream();
      };
    }
    if (this.hasWorker) {
      env.Worker = workerConstructorOf(this);
    }
    if (this.hasBlob) {
      env.Blob = blobConstructorOf(this);
    }
    if (this.hasUrl) {
      env.URL = {
        createObjectURL: (blob: { parts: string[] }) => {
          const url = `blob:fake/${this.blobSources.size + 1}`;
          this.blobSources.set(url, blob.parts.join(""));
          return url;
        },
        revokeObjectURL: (url: string) => {
          this.revokedUrls.push(url);
        },
      };
    }
    if (this.hasTimers) {
      env.setTimeout = (callback: () => void, milliseconds: number) => {
        const timer: FakeTimer = { id: this.timers.length + 1, callback, milliseconds, cleared: false, fired: false };
        this.timers.push(timer);
        return timer.id;
      };
      env.clearTimeout = (id: number) => {
        const timer = this.timers.find((candidate) => candidate.id === id);
        if (timer !== undefined) {
          timer.cleared = true;
        }
      };
    }
    if (this.navigatorOverride !== undefined) {
      env.navigator = this.navigatorOverride;
    } else if (this.hasNavigator) {
      env.navigator = {
        userAgent: "dummy-user-agent",
        mediaDevices: this.hasDisplayMedia ? { getDisplayMedia: () => undefined } : {},
        ...(this.hasLocks ? { locks: { request: () => undefined } } : {}),
      };
    }
    return env as BrowserGlobals;
  }
}

describe("WORKER_PROBE_SOURCE: ワーカーの中で実行されるスクリプト（Node の vm で、実際に実行して検査）", () => {
  function runInWorkerScope(globals: Record<string, unknown>): { posted: unknown[]; onmessage: ((event: { data: unknown }) => void) | null } {
    const posted: unknown[] = [];
    const scope: { onmessage: ((event: { data: unknown }) => void) | null; postMessage: (data: unknown) => void } = {
      onmessage: null,
      postMessage: (data) => posted.push(data),
    };
    vm.runInNewContext(WORKER_PROBE_SOURCE, { self: scope, ...globals });
    return { posted, onmessage: scope.onmessage };
  }

  test("読み込んだだけでは、何も送らない。メッセージを受けたら、OffscreenCanvas と VideoFrame の typeof を、1 回だけ返す", () => {
    const { posted, onmessage } = runInWorkerScope({ OffscreenCanvas: function OffscreenCanvas() {}, VideoFrame: function VideoFrame() {} });
    expect(posted).toEqual([]);
    expect(typeof onmessage).toBe("function");
    onmessage?.({ data: "probe" });
    expect(posted).toHaveLength(1);
    expect(JSON.parse(JSON.stringify(posted[0]))).toEqual({ offscreenCanvas: "function", videoFrame: "function" });
  });

  test.each([
    ["OffscreenCanvas が無い", { VideoFrame: function VideoFrame() {} }, { offscreenCanvas: "undefined", videoFrame: "function" }],
    ["VideoFrame が無い", { OffscreenCanvas: function OffscreenCanvas() {} }, { offscreenCanvas: "function", videoFrame: "undefined" }],
    ["どちらも無い", {}, { offscreenCanvas: "undefined", videoFrame: "undefined" }],
    ["MediaStreamTrackProcessor があっても（Chrome では、ワーカー内には無い）、報告に含めない", { MediaStreamTrackProcessor: function MediaStreamTrackProcessor() {} }, { offscreenCanvas: "undefined", videoFrame: "undefined" }],
  ])("%s", (_label, globals, expected) => {
    const { posted, onmessage } = runInWorkerScope(globals);
    onmessage?.({ data: "probe" });
    expect(JSON.parse(JSON.stringify(posted[0]))).toEqual(expected);
  });

  test("スクリプトは ASCII だけ（日本語・絵文字を含まない）で、DOM・ネットワークを使わない", () => {
    expect(WORKER_PROBE_SOURCE).toMatch(/^[\x20-\x7e\n]+$/);
    for (const word of ["fetch", "XMLHttpRequest", "importScripts", "document", "window", "eval"]) {
      expect(WORKER_PROBE_SOURCE).not.toContain(word);
    }
  });
});

describe("readBrowserCapabilities: すべての能力がそろう環境", () => {
  test("検出の結果（report）：Main のコーデック文字列・AAC・フレーム取得の 4 条件・AudioWorklet・WebSocket・画面共有・タブ間の排他。失敗は無い。凍結されている", async () => {
    const browser = new FakeBrowser();
    const report = await readBrowserCapabilities(browser.env());
    expect(report).toEqual({
      videoCodec: MAIN,
      aacEncode: true,
      frameCapture: {
        trackProcessorInWindow: true,
        readableStreamTransfer: true,
        offscreenCanvasInWorker: true,
        videoFrameInWorker: true,
      },
      audioWorklet: true,
      webSocket: true,
      screenCapture: true,
      tabLock: true,
      failures: [],
    });
    expect(Object.isFrozen(report)).toBe(true);
    expect(Object.isFrozen(report.frameCapture)).toBe(true);
    expect(Object.isFrozen(report.failures)).toBe(true);
    expect(evaluateCapabilities(report)).toMatchObject({ canStart: true, canShareScreen: true, tabLock: true, videoCodec: MAIN, missingRequired: [] });
  });

  test("H.264 は、Main を、両プロファイル（720p・480p）の設定（11.7）で問い合わせる：avc 形式・低遅延・固定ビットレート・初期ビットレート。Main が使えれば、Constrained Baseline は問い合わせない", async () => {
    const browser = new FakeBrowser();
    await readBrowserCapabilities(browser.env());
    expect(browser.videoConfigs).toEqual([
      { codec: "avc1.4D401F", width: 1280, height: 720, bitrate: 4_500_000, framerate: 30, bitrateMode: "constant", latencyMode: "realtime", avc: { format: "avc" } },
      { codec: "avc1.4D401F", width: 854, height: 480, bitrate: 1_500_000, framerate: 30, bitrateMode: "constant", latencyMode: "realtime", avc: { format: "avc" } },
    ]);
  });

  test("AAC は、AAC-LC（mp4a.40.2）・44,100 Hz・2 ch・128 kbps・aac 形式（ADTS なし）で問い合わせる", async () => {
    const browser = new FakeBrowser();
    await readBrowserCapabilities(browser.env());
    expect(browser.audioConfigs).toEqual([{ codec: "mp4a.40.2", sampleRate: 44_100, numberOfChannels: 2, bitrate: 128_000, aac: { format: "aac" } }]);
  });

  test("ワーカーは 1 つだけ起動し、検査が済んだら終了し、Blob URL を解放する。ワーカーのスクリプトは text/javascript の Blob。タイマーは取り消す", async () => {
    const browser = new FakeBrowser();
    await readBrowserCapabilities(browser.env());
    expect(browser.createdWorkers).toHaveLength(1);
    expect(browser.createdWorkers[0].terminated).toBe(true);
    expect(browser.blobSources.size).toBe(1);
    expect(browser.revokedUrls).toEqual([...browser.blobSources.keys()]);
    expect(browser.blobSources.values().next().value).toBe(WORKER_PROBE_SOURCE);
    expect(browser.blobTypes).toEqual(["text/javascript"]);
    expect(browser.postedToWorkers).toHaveLength(1);
    expect(browser.timers).toHaveLength(1);
    expect(browser.timers[0].milliseconds).toBe(WORKER_PROBE_TIMEOUT_MS);
    expect(browser.timers[0].cleared).toBe(true);
    expect(WORKER_PROBE_TIMEOUT_MS).toBeGreaterThan(0);
  });

  test("ReadableStream の転送は、structuredClone(stream, { transfer: [stream] }) で検査する", async () => {
    const browser = new FakeBrowser();
    await readBrowserCapabilities(browser.env());
    expect(browser.cloneCalls).toHaveLength(1);
    const { value, options } = browser.cloneCalls[0];
    expect(value).toBeInstanceOf(FakeReadableStream);
    expect(options).toEqual({ transfer: [value] });
  });
});

describe("readBrowserCapabilities: Linux の Chromium の実測の再現（AAC が使えない。設計どおり canStart は偽）", () => {
  test("H.264（Main・Constrained Baseline）は使え、AAC は使えず、MediaStreamTrackProcessor は Window にあるがワーカーには無い。ワーカーには OffscreenCanvas と VideoFrame がある", async () => {
    const browser = new FakeBrowser();
    browser.audioSupport = () => false; // 実測：AAC（mp4a.40.2）は isConfigSupported が偽（Opus は真）
    browser.workerGlobals = { OffscreenCanvas: function OffscreenCanvas() {}, VideoFrame: function VideoFrame() {} }; // MediaStreamTrackProcessor はワーカーに無い
    const report = await readBrowserCapabilities(browser.env());
    expect(report.videoCodec).toBe(MAIN);
    expect(report.aacEncode).toBe(false);
    expect(report.frameCapture).toEqual({ trackProcessorInWindow: true, readableStreamTransfer: true, offscreenCanvasInWorker: true, videoFrameInWorker: true });

    const evaluation = evaluateCapabilities(report);
    expect(evaluation.canStart).toBe(false);
    expect(evaluation.missingRequired).toEqual(["aac_encode"]);
    expect(evaluation.canShareScreen).toBe(true);
  });
});

describe("readBrowserCapabilities: H.264（Main -> Constrained Baseline。両プロファイルで使える最初のコーデック文字列）", () => {
  test.each<[string, (config: VideoConfig) => boolean, string | null, number]>([
    ["Main が使える：Main", () => true, MAIN, 2],
    ["Main が使えず、Constrained Baseline のみ使える：Baseline（利用可。使うコーデック文字列を返す）", (config) => config.codec === BASELINE, BASELINE, 4],
    ["Main は 720p のみ使える（480p は不可）：Main は使わず、Baseline が両方使えれば Baseline", (config) => (config.codec === MAIN ? config.height === 720 : true), BASELINE, 4],
    ["Main も、480p の Baseline も使えない：使えない", (config) => config.codec === BASELINE && config.height === 720, null, 4],
    ["どちらも使えない：使えない", () => false, null, 4],
  ])("%s", async (_label, support, expectedCodec, expectedCalls) => {
    const browser = new FakeBrowser();
    browser.videoSupport = support;
    const report = await readBrowserCapabilities(browser.env());
    expect(report.videoCodec).toBe(expectedCodec);
    expect(browser.videoConfigs).toHaveLength(expectedCalls);
    expect(report.failures).toEqual([]);
  });

  test("Main の問い合わせが例外（NotSupportedError）なら、Main は使えないとして、Baseline を試す。失敗の記録に、検査の名前とエラーの名前だけを残す", async () => {
    const browser = new FakeBrowser();
    browser.videoSupport = (config) => (config.codec === MAIN ? namedError("NotSupportedError", "secret details must not be recorded") : true);
    const report = await readBrowserCapabilities(browser.env());
    expect(report.videoCodec).toBe(BASELINE);
    expect(report.failures).toEqual([{ probe: "h264_encode", errorName: "NotSupportedError" }]);
    expect(JSON.stringify(report)).not.toContain("secret details");
  });

  test("どちらのコーデックの問い合わせも例外なら、使えない（判定不能は拒否側）。コーデックごとに 1 件の失敗", async () => {
    const browser = new FakeBrowser();
    browser.videoSupport = () => new TypeError("bad config");
    const report = await readBrowserCapabilities(browser.env());
    expect(report.videoCodec).toBeNull();
    expect(report.failures).toEqual([
      { probe: "h264_encode", errorName: "TypeError" },
      { probe: "h264_encode", errorName: "TypeError" },
    ]);
  });

  test("VideoEncoder が無い：使えない。問い合わせず、失敗でもない（能力が無いという結果）", async () => {
    const browser = new FakeBrowser();
    browser.videoSupport = null;
    const report = await readBrowserCapabilities(browser.env());
    expect(report.videoCodec).toBeNull();
    expect(report.failures).toEqual([]);
  });

  test("supported が真偽値の true でない応答（undefined・\"true\"・1）は、使えない（厳密に true だけを使える）", async () => {
    for (const answer of [{}, { supported: undefined }, { supported: "true" }, { supported: 1 }, { supported: null }]) {
      const browser = new FakeBrowser();
      browser.videoSupport = () => answer;
      const report = await readBrowserCapabilities(browser.env());
      expect(report.videoCodec).toBeNull();
    }
  });
});

describe("readBrowserCapabilities: AAC-LC", () => {
  test.each<[string, ((config: AudioConfig) => boolean | Error | { readonly supported?: unknown }) | null, boolean, readonly { probe: string; errorName: string }[]]>([
    ["使える", () => true, true, []],
    ["使えない（Linux・ChromeOS・Firefox の Chrome 系）", () => false, false, []],
    ["supported が無い応答", () => ({}), false, []],
    ["AudioEncoder が無い", null, false, []],
    ["問い合わせが例外：使えない（判定不能は拒否側）。失敗を記録", () => namedError("NotSupportedError"), false, [{ probe: "aac_encode", errorName: "NotSupportedError" }]],
  ])("%s", async (_label, support, expected, expectedFailures) => {
    const browser = new FakeBrowser();
    browser.audioSupport = support;
    const report = await readBrowserCapabilities(browser.env());
    expect(report.aacEncode).toBe(expected);
    expect(report.failures).toEqual(expectedFailures);
  });
});

describe("readBrowserCapabilities: MediaStreamTrackProcessor は Window で検査する", () => {
  test("Window に無ければ、ワーカー内にあっても、フレーム取得は不可（ワーカー内の MediaStreamTrackProcessor は、検査も利用もしない）", async () => {
    const browser = new FakeBrowser();
    browser.hasTrackProcessor = false;
    browser.workerGlobals = { OffscreenCanvas: function OffscreenCanvas() {}, VideoFrame: function VideoFrame() {}, MediaStreamTrackProcessor: function MediaStreamTrackProcessor() {} };
    const report = await readBrowserCapabilities(browser.env());
    expect(report.frameCapture.trackProcessorInWindow).toBe(false);
    expect(evaluateCapabilities(report).missingRequired).toEqual(["worker_frame_capture"]);
  });

  test("Window にあれば、ワーカー内に無くても（Chrome の実測）、条件を満たす", async () => {
    const browser = new FakeBrowser();
    browser.workerGlobals = { OffscreenCanvas: function OffscreenCanvas() {}, VideoFrame: function VideoFrame() {} };
    const report = await readBrowserCapabilities(browser.env());
    expect(report.frameCapture.trackProcessorInWindow).toBe(true);
  });

  test("constructor でない値（オブジェクト）が置かれていても、存在とは認めない（関数だけを存在とする）", async () => {
    const browser = new FakeBrowser();
    const env = browser.env() as Record<string, unknown>;
    env.MediaStreamTrackProcessor = {};
    env.AudioWorkletNode = "yes";
    env.WebSocket = 1;
    const report = await readBrowserCapabilities(env as BrowserGlobals);
    expect(report.frameCapture.trackProcessorInWindow).toBe(false);
    expect(report.audioWorklet).toBe(false);
    expect(report.webSocket).toBe(false);
  });
});

describe("readBrowserCapabilities: Window の API の存在", () => {
  test.each<[string, (browser: FakeBrowser) => void, keyof CapabilityReport]>([
    ["AudioWorklet が無い", (browser) => { browser.hasAudioWorklet = false; }, "audioWorklet"],
    ["WebSocket が無い", (browser) => { browser.hasWebSocket = false; }, "webSocket"],
    ["getDisplayMedia が無い（画面共有 API）", (browser) => { browser.hasDisplayMedia = false; }, "screenCapture"],
    ["navigator.locks が無い（タブ間の排他）", (browser) => { browser.hasLocks = false; }, "tabLock"],
    ["navigator が無い：画面共有もタブ間の排他も無い", (browser) => { browser.hasNavigator = false; }, "screenCapture"],
  ])("%s", async (_label, change, key) => {
    const browser = new FakeBrowser();
    change(browser);
    const report = await readBrowserCapabilities(browser.env());
    expect(report[key]).toBe(false);
    // ほかの能力は、影響を受けない
    expect(report.videoCodec).toBe(MAIN);
    expect(report.aacEncode).toBe(true);
    expect(report.failures).toEqual([]);
  });

  test("navigator が無ければ、画面共有もタブ間の排他も偽（どちらも）", async () => {
    const browser = new FakeBrowser();
    browser.hasNavigator = false;
    const report = await readBrowserCapabilities(browser.env());
    expect(report.screenCapture).toBe(false);
    expect(report.tabLock).toBe(false);
  });

  test("navigator の取得が例外を投げても（アクセスできない環境）、能力なし（拒否側）として扱い、全体は続く", async () => {
    const browser = new FakeBrowser();
    const env = browser.env() as Record<string, unknown>;
    Object.defineProperty(env, "navigator", {
      get() {
        throw namedError("SecurityError");
      },
    });
    const report = await readBrowserCapabilities(env as BrowserGlobals);
    expect(report.screenCapture).toBe(false);
    expect(report.tabLock).toBe(false);
    expect(report.videoCodec).toBe(MAIN);
  });

  test("画面共有 API だけが欠けても、他は影響を受けず、canStart は真（画面共有のみ提供しない）", async () => {
    const browser = new FakeBrowser();
    browser.hasDisplayMedia = false;
    const evaluation = evaluateCapabilities(await readBrowserCapabilities(browser.env()));
    expect(evaluation).toMatchObject({ canStart: true, canShareScreen: false, tabLock: true });
  });
});

describe("readBrowserCapabilities: ReadableStream の転送（structuredClone）", () => {
  test.each<[string, (browser: FakeBrowser) => void, boolean, readonly { probe: string; errorName: string }[]]>([
    ["転送できる", () => undefined, true, []],
    ["DataCloneError：転送できない（能力が無いという結果。失敗の記録ではない）", (browser) => { browser.streamTransfer = namedError("DataCloneError"); }, false, []],
    ["想定外のエラー（TypeError）：転送できない。失敗を記録", (browser) => { browser.streamTransfer = new TypeError("unexpected"); }, false, [{ probe: "readable_stream_transfer", errorName: "TypeError" }]],
    ["structuredClone が無い", (browser) => { browser.streamTransfer = "absent"; }, false, []],
    ["ReadableStream が無い", (browser) => { browser.hasReadableStream = false; }, false, []],
  ])("%s", async (_label, change, expected, expectedFailures) => {
    const browser = new FakeBrowser();
    change(browser);
    const report = await readBrowserCapabilities(browser.env());
    expect(report.frameCapture.readableStreamTransfer).toBe(expected);
    expect(report.failures).toEqual(expectedFailures);
  });
});

describe("readBrowserCapabilities: ワーカーの検査（小さなワーカーを実際に起動する）", () => {
  test.each([
    ["OffscreenCanvas が無い", { VideoFrame: function VideoFrame() {} }, false, true],
    ["VideoFrame が無い", { OffscreenCanvas: function OffscreenCanvas() {} }, true, false],
    ["どちらも無い", {}, false, false],
  ])("ワーカー内に %s", async (_label, globals, offscreenCanvas, videoFrame) => {
    const browser = new FakeBrowser();
    browser.workerGlobals = globals;
    const report = await readBrowserCapabilities(browser.env());
    expect(report.frameCapture.offscreenCanvasInWorker).toBe(offscreenCanvas);
    expect(report.frameCapture.videoFrameInWorker).toBe(videoFrame);
    expect(report.failures).toEqual([]);
    expect(evaluateCapabilities(report).missingRequired).toEqual(["worker_frame_capture"]);
  });

  test("ワーカーが応答しなければ、タイムアウトで、能力なし（拒否側）。失敗を記録し、ワーカーを終了し、Blob URL を解放する", async () => {
    const browser = new FakeBrowser();
    browser.workerStartup = "silent";
    const pending = readBrowserCapabilities(browser.env());
    await new Promise<void>((resolve) => setImmediate(resolve));
    expect(browser.timers).toHaveLength(1);
    expect(browser.timers[0].fired).toBe(false);
    browser.fireTimers();
    const report = await pending;
    expect(report.frameCapture.offscreenCanvasInWorker).toBe(false);
    expect(report.frameCapture.videoFrameInWorker).toBe(false);
    expect(report.failures).toEqual([{ probe: "worker_probe", errorName: "ProbeTimeout" }]);
    expect(browser.createdWorkers[0].terminated).toBe(true);
    expect(browser.revokedUrls).toHaveLength(1);
  });

  test("ワーカーが error イベントを出したら、能力なし。失敗を記録し、ワーカーを終了する", async () => {
    const browser = new FakeBrowser();
    browser.workerStartup = "error_event";
    const report = await readBrowserCapabilities(browser.env());
    expect(report.frameCapture.offscreenCanvasInWorker).toBe(false);
    expect(report.frameCapture.videoFrameInWorker).toBe(false);
    expect(report.failures).toEqual([{ probe: "worker_probe", errorName: "ProbeWorkerError" }]);
    expect(browser.createdWorkers[0].terminated).toBe(true);
    expect(browser.timers[0].cleared).toBe(true);
  });

  test("ワーカーの起動が例外（CSP などで禁止：SecurityError）なら、能力なし。失敗を記録し、Blob URL を解放する", async () => {
    const browser = new FakeBrowser();
    browser.workerStartup = "constructor_throws";
    const report = await readBrowserCapabilities(browser.env());
    expect(report.frameCapture.offscreenCanvasInWorker).toBe(false);
    expect(report.frameCapture.videoFrameInWorker).toBe(false);
    expect(report.failures).toEqual([{ probe: "worker_probe", errorName: "SecurityError" }]);
    expect(browser.revokedUrls).toHaveLength(1);
  });

  test.each([
    ["文字列", "nonsense"],
    ["null", null],
    ["キーが無い", {}],
    ["値が文字列でない", { offscreenCanvas: 1, videoFrame: true }],
    ["片方だけ", { offscreenCanvas: "function" }],
  ])("ワーカーの応答が不正（%s）なら、能力なし。失敗（ProbeMalformedReply）を記録する", async (_label, reply) => {
    const browser = new FakeBrowser();
    browser.workerReply = () => reply;
    const report = await readBrowserCapabilities(browser.env());
    expect(report.frameCapture.offscreenCanvasInWorker).toBe(false);
    expect(report.frameCapture.videoFrameInWorker).toBe(false);
    expect(report.failures).toEqual([{ probe: "worker_probe", errorName: "ProbeMalformedReply" }]);
  });

  test.each<[string, (browser: FakeBrowser) => void]>([
    ["Worker が無い", (browser) => { browser.hasWorker = false; }],
    ["Blob が無い", (browser) => { browser.hasBlob = false; }],
    ["URL が無い", (browser) => { browser.hasUrl = false; }],
  ])("%s：ワーカーを起動できない環境。能力なし（失敗の記録ではない）。ワーカーを作らない", async (_label, change) => {
    const browser = new FakeBrowser();
    change(browser);
    const report = await readBrowserCapabilities(browser.env());
    expect(report.frameCapture.offscreenCanvasInWorker).toBe(false);
    expect(report.frameCapture.videoFrameInWorker).toBe(false);
    expect(report.failures).toEqual([]);
    expect(browser.createdWorkers).toHaveLength(0);
  });

  test("タイマー（setTimeout・clearTimeout）が注入されていなければ、応答の期限を設けられないため、ワーカーを起動せず、能力なし。失敗を記録する", async () => {
    const browser = new FakeBrowser();
    browser.hasTimers = false;
    const report = await readBrowserCapabilities(browser.env());
    expect(report.frameCapture.offscreenCanvasInWorker).toBe(false);
    expect(report.failures).toEqual([{ probe: "worker_probe", errorName: "ProbeTimerUnavailable" }]);
    expect(browser.createdWorkers).toHaveLength(0);
  });

  test("ワーカーの検査が失敗しても、他の検査（H.264・AAC・Window の API）は、そのまま結果になる", async () => {
    const browser = new FakeBrowser();
    browser.workerStartup = "constructor_throws";
    const report = await readBrowserCapabilities(browser.env());
    expect(report.videoCodec).toBe(MAIN);
    expect(report.aacEncode).toBe(true);
    expect(report.audioWorklet).toBe(true);
    expect(report.webSocket).toBe(true);
  });
});

describe("readBrowserCapabilities: window を直接参照せず、ブラウザの名称・版で判断しない", () => {
  test("何も無い環境（空のオブジェクト）では、すべて能力なし。Node の大域（navigator・WebSocket・structuredClone・Worker 等）を、環境の代わりに使わない", async () => {
    const report = await readBrowserCapabilities({});
    expect(report).toEqual({
      videoCodec: null,
      aacEncode: false,
      frameCapture: {
        trackProcessorInWindow: false,
        readableStreamTransfer: false,
        offscreenCanvasInWorker: false,
        videoFrameInWorker: false,
      },
      audioWorklet: false,
      webSocket: false,
      screenCapture: false,
      tabLock: false,
      failures: [],
    });
    const evaluation = evaluateCapabilities(report);
    expect(evaluation.canStart).toBe(false);
    expect(evaluation.missingRequired).toEqual(["h264_encode", "aac_encode", "worker_frame_capture", "audio_processing", "websocket"]);
  });

  test("navigator の userAgent・userAgentData・platform・appVersion・vendor を、読まない（読めば失敗する疑似の navigator で検査）", async () => {
    const touched: string[] = [];
    const guarded = new Proxy(
      {
        mediaDevices: { getDisplayMedia: () => undefined },
        locks: { request: () => undefined },
        userAgent: "dummy",
        userAgentData: { brands: [] },
        platform: "dummy",
        appVersion: "dummy",
        vendor: "dummy",
      },
      {
        get(target, property, receiver) {
          if (["userAgent", "userAgentData", "platform", "appVersion", "vendor", "appName", "product"].includes(String(property))) {
            touched.push(String(property));
          }
          return Reflect.get(target, property, receiver);
        },
      },
    );
    const browser = new FakeBrowser();
    browser.navigatorOverride = guarded;
    const report = await readBrowserCapabilities(browser.env());
    expect(touched).toEqual([]);
    expect(report.screenCapture).toBe(true);
    expect(report.tabLock).toBe(true);
  });

  test("同じ環境の結果は、ユーザーエージェントの文字列が違っても、同じ", async () => {
    const results: string[] = [];
    for (const userAgent of ["Chrome/153 Linux", "Firefox/130 Windows", "Safari/26 Macintosh", ""]) {
      const browser = new FakeBrowser();
      browser.navigatorOverride = { userAgent, mediaDevices: { getDisplayMedia: () => undefined }, locks: { request: () => undefined } };
      results.push(JSON.stringify(await readBrowserCapabilities(browser.env())));
    }
    expect(new Set(results).size).toBe(1);
  });
});

describe("readBrowserCapabilities: 失敗の記録に、機密・ユーザーの情報を残さない", () => {
  test("失敗の記録は、検査の名前とエラーの名前だけ（メッセージ・スタック・URL を含まない）", async () => {
    const browser = new FakeBrowser();
    browser.audioSupport = () => namedError("NotSupportedError", "https://example.invalid/secret?token=dummy-token");
    browser.workerStartup = "constructor_throws";
    const report = await readBrowserCapabilities(browser.env());
    expect(report.failures.length).toBeGreaterThan(0);
    for (const failure of report.failures) {
      expect(Object.keys(failure).sort()).toEqual(["errorName", "probe"]);
    }
    const serialized = JSON.stringify(report);
    expect(serialized).not.toContain("example.invalid");
    expect(serialized).not.toContain("dummy-token");
    expect(serialized).not.toContain("blob:");
  });

  test("エラーでない値（文字列・null）を投げられても、名前は固定の語（NonErrorThrown）にする（投げられた値を残さない）", async () => {
    const browser = new FakeBrowser();
    const env = browser.env() as Record<string, unknown>;
    const thrown: unknown = "secret thrown string"; // エラーでない値が投げられた場合の検査
    env.AudioEncoder = {
      isConfigSupported: () => {
        throw thrown;
      },
    };
    const report = await readBrowserCapabilities(env as BrowserGlobals);
    expect(report.failures).toEqual([{ probe: "aac_encode", errorName: "NonErrorThrown" }]);
    expect(JSON.stringify(report)).not.toContain("secret thrown string");
  });
});

describe("readBrowserCapabilities: 並行と独立", () => {
  test("2 つの検出を同時に走らせても、互いに影響しない（結果が同じ）", async () => {
    const first = new FakeBrowser();
    const second = new FakeBrowser();
    second.audioSupport = () => false;
    const [reportFirst, reportSecond] = await Promise.all([readBrowserCapabilities(first.env()), readBrowserCapabilities(second.env())]);
    expect(reportFirst.aacEncode).toBe(true);
    expect(reportSecond.aacEncode).toBe(false);
    expect(reportFirst.videoCodec).toBe(reportSecond.videoCodec);
  });

  test("環境がオブジェクトでなければ、推測せず TypeError（注入の誤り）", async () => {
    await expect(readBrowserCapabilities(undefined as never)).rejects.toThrow(TypeError);
    await expect(readBrowserCapabilities(null as never)).rejects.toThrow(TypeError);
    await expect(readBrowserCapabilities("window" as never)).rejects.toThrow(TypeError);
  });

  test("環境オブジェクトを変更しない", async () => {
    const browser = new FakeBrowser();
    const env = browser.env();
    const keysBefore = Object.keys(env).sort();
    await readBrowserCapabilities(env);
    expect(Object.keys(env).sort()).toEqual(keysBefore);
  });
});
