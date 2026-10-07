/**
 * @jest-environment node
 */
// 能力検出の評価（requirements.md 30.1・15 章「能力検出」・16.6）。ブラウザの名称や版ではなく、検出の結果（report）だけで決める。
//   開始に必須（欠ける場合は配信の開始を提供しない）：H.264 エンコード・AAC-LC エンコード・ワーカー上でのフレーム取得と描画・
//     音声の処理周期での信号取得・WebSocket。すべてそろう場合のみ canStart
//   画面共有 API が欠ける場合は、画面共有の操作のみを提供しない（canShareScreen: false）
//   タブ間の排他が欠ける場合は、サーバー側の排他のみで運用する（tabLock: false）
//   「ワーカー上でのフレーム取得と描画」= MediaStreamTrackProcessor が Window にあり、その readable（VideoFrame のストリーム）をワーカーへ転送でき、
//     ワーカー内に OffscreenCanvas と VideoFrame がある（Chrome では、MediaStreamTrackProcessor はワーカー内で使えず、MediaStreamTrack も転送できない）
import { LIMITS } from "../contract";
import { evaluateCapabilities } from "./evaluateCapabilities";
import { CAPABILITY_IDS, REQUIRED_CAPABILITY_IDS } from "./types";
import type { CapabilityReport, RequiredCapabilityId } from "./types";

const MAIN = LIMITS.video.codec_main;
const BASELINE = LIMITS.video.codec_constrained_baseline;

/** すべてそろった検出の結果。 */
function fullReport(overrides: Partial<Omit<CapabilityReport, "frameCapture">> & { frameCapture?: Partial<CapabilityReport["frameCapture"]> } = {}): CapabilityReport {
  const { frameCapture, ...rest } = overrides;
  return {
    videoCodec: MAIN,
    aacEncode: true,
    frameCapture: {
      trackProcessorInWindow: true,
      readableStreamTransfer: true,
      offscreenCanvasInWorker: true,
      videoFrameInWorker: true,
      ...frameCapture,
    },
    audioWorklet: true,
    webSocket: true,
    screenCapture: true,
    tabLock: true,
    failures: [],
    ...rest,
  };
}

describe("evaluateCapabilities: すべてそろう", () => {
  test("開始できる。画面共有もタブ間の排他も使える。不足は無い。使うコーデック文字列を返す", () => {
    expect(evaluateCapabilities(fullReport())).toEqual({
      canStart: true,
      canShareScreen: true,
      tabLock: true,
      videoCodec: MAIN,
      missingRequired: [],
    });
  });

  test("Main が使えず Constrained Baseline のみ使える場合も「利用可」で、使うコーデック文字列（avc1.42E01F）を返す（11.7）", () => {
    const result = evaluateCapabilities(fullReport({ videoCodec: BASELINE }));
    expect(result.canStart).toBe(true);
    expect(result.videoCodec).toBe("avc1.42E01F");
    expect(result.missingRequired).toEqual([]);
  });
});

describe("evaluateCapabilities: 開始に必須の能力が 1 つ欠ける -> canStart は偽（配信の開始を提供しない）", () => {
  test.each<[string, CapabilityReport, readonly RequiredCapabilityId[]]>([
    ["H.264 のエンコードが使えない", fullReport({ videoCodec: null }), ["h264_encode"]],
    ["AAC-LC のエンコードが使えない（Linux・ChromeOS・Firefox の Chrome 系で、設計どおり）", fullReport({ aacEncode: false }), ["aac_encode"]],
    ["MediaStreamTrackProcessor が Window に無い", fullReport({ frameCapture: { trackProcessorInWindow: false } }), ["worker_frame_capture"]],
    ["ReadableStream をワーカーへ転送できない", fullReport({ frameCapture: { readableStreamTransfer: false } }), ["worker_frame_capture"]],
    ["ワーカー内に OffscreenCanvas が無い", fullReport({ frameCapture: { offscreenCanvasInWorker: false } }), ["worker_frame_capture"]],
    ["ワーカー内に VideoFrame が無い", fullReport({ frameCapture: { videoFrameInWorker: false } }), ["worker_frame_capture"]],
    ["音声の処理周期での信号取得（AudioWorklet）が無い", fullReport({ audioWorklet: false }), ["audio_processing"]],
    ["WebSocket が無い", fullReport({ webSocket: false }), ["websocket"]],
  ])("%s", (_label, report, expectedMissing) => {
    const result = evaluateCapabilities(report);
    expect(result.canStart).toBe(false);
    expect(result.missingRequired).toEqual(expectedMissing);
  });

  test("ワーカー上のフレーム取得と描画は、4 つの条件がすべてそろって初めて満たす（1 つでも欠ければ不足として 1 回だけ数える）", () => {
    const allFalse = fullReport({
      frameCapture: { trackProcessorInWindow: false, readableStreamTransfer: false, offscreenCanvasInWorker: false, videoFrameInWorker: false },
    });
    expect(evaluateCapabilities(allFalse).missingRequired).toEqual(["worker_frame_capture"]);
  });

  test("すべて欠ける：不足は、30.1 の表の順に、重複なしで並ぶ。タブ間の排他と画面共有は、不足に含めない（開始を妨げない）", () => {
    const nothing = fullReport({
      videoCodec: null,
      aacEncode: false,
      frameCapture: { trackProcessorInWindow: false, readableStreamTransfer: false, offscreenCanvasInWorker: false, videoFrameInWorker: false },
      audioWorklet: false,
      webSocket: false,
      screenCapture: false,
      tabLock: false,
    });
    expect(evaluateCapabilities(nothing)).toEqual({
      canStart: false,
      canShareScreen: false,
      tabLock: false,
      videoCodec: null,
      missingRequired: ["h264_encode", "aac_encode", "worker_frame_capture", "audio_processing", "websocket"],
    });
  });

  test("H.264 が使えても、他が欠けていれば、使うコーデック文字列は返す（開始はできない）", () => {
    const result = evaluateCapabilities(fullReport({ aacEncode: false }));
    expect(result.canStart).toBe(false);
    expect(result.videoCodec).toBe(MAIN);
  });
});

describe("evaluateCapabilities: 開始を妨げない能力（画面共有・タブ間の排他）", () => {
  test("画面共有 API が欠けても、開始できる。画面共有のみ提供しない（canShareScreen: false）", () => {
    expect(evaluateCapabilities(fullReport({ screenCapture: false }))).toMatchObject({
      canStart: true,
      canShareScreen: false,
      tabLock: true,
      missingRequired: [],
    });
  });

  test("タブ間の排他が欠けても、開始できる。サーバー側の排他のみで運用する（tabLock: false）", () => {
    expect(evaluateCapabilities(fullReport({ tabLock: false }))).toMatchObject({
      canStart: true,
      canShareScreen: true,
      tabLock: false,
      missingRequired: [],
    });
  });

  test("両方が欠けても、開始できる", () => {
    expect(evaluateCapabilities(fullReport({ screenCapture: false, tabLock: false }))).toMatchObject({
      canStart: true,
      canShareScreen: false,
      tabLock: false,
    });
  });
});

describe("evaluateCapabilities: 全組み合わせ（10 項目の真偽 = 1,024 通り）", () => {
  test("canStart は、必須の 8 項目（H.264・AAC・フレーム取得の 4 条件・AudioWorklet・WebSocket）がすべて真のときだけ。画面共有・タブ間の排他は、canStart に影響しない", () => {
    const mismatches: string[] = [];
    for (let bits = 0; bits < 1_024; bits += 1) {
      const flag = (index: number): boolean => (bits & (1 << index)) !== 0;
      const report = fullReport({
        videoCodec: flag(0) ? MAIN : null,
        aacEncode: flag(1),
        frameCapture: {
          trackProcessorInWindow: flag(2),
          readableStreamTransfer: flag(3),
          offscreenCanvasInWorker: flag(4),
          videoFrameInWorker: flag(5),
        },
        audioWorklet: flag(6),
        webSocket: flag(7),
        screenCapture: flag(8),
        tabLock: flag(9),
      });
      const requiredAllTrue = [0, 1, 2, 3, 4, 5, 6, 7].every(flag);
      const expectedMissing: string[] = [];
      if (!flag(0)) expectedMissing.push("h264_encode");
      if (!flag(1)) expectedMissing.push("aac_encode");
      if (![2, 3, 4, 5].every(flag)) expectedMissing.push("worker_frame_capture");
      if (!flag(6)) expectedMissing.push("audio_processing");
      if (!flag(7)) expectedMissing.push("websocket");

      const result = evaluateCapabilities(report);
      if (
        result.canStart !== requiredAllTrue ||
        result.canShareScreen !== flag(8) ||
        result.tabLock !== flag(9) ||
        JSON.stringify(result.missingRequired) !== JSON.stringify(expectedMissing) ||
        result.canStart !== (result.missingRequired.length === 0)
      ) {
        mismatches.push(`bits ${bits.toString(2).padStart(10, "0")}`);
      }
    }
    expect(mismatches).toEqual([]);
  });
});

describe("evaluateCapabilities: 能力の識別子と純粋さ", () => {
  test("30.1 の表の 7 行（必須 5 + 画面共有・タブ間の排他）。識別子は ASCII の snake_case で、凍結されている", () => {
    expect([...CAPABILITY_IDS]).toEqual(["h264_encode", "aac_encode", "worker_frame_capture", "audio_processing", "websocket", "screen_capture", "tab_lock"]);
    expect([...REQUIRED_CAPABILITY_IDS]).toEqual(["h264_encode", "aac_encode", "worker_frame_capture", "audio_processing", "websocket"]);
    expect(Object.isFrozen(CAPABILITY_IDS)).toBe(true);
    expect(Object.isFrozen(REQUIRED_CAPABILITY_IDS)).toBe(true);
    for (const id of CAPABILITY_IDS) {
      expect(id).toMatch(/^[a-z0-9]+(_[a-z0-9]+)*$/);
    }
  });

  test("結果は変更できない（凍結されている）。入力を変更しない。同じ入力に、いつも同じ出力", () => {
    const report = fullReport({ aacEncode: false });
    const frozenCopy = JSON.stringify(report);
    const first = evaluateCapabilities(report);
    expect(Object.isFrozen(first)).toBe(true);
    expect(Object.isFrozen(first.missingRequired)).toBe(true);
    expect(JSON.stringify(report)).toBe(frozenCopy);
    expect(evaluateCapabilities(report)).toEqual(first);
  });

  test("検出の失敗の記録（failures）は、判定に影響しない（結果は、各能力の真偽だけで決まる）", () => {
    const withFailures = fullReport({ failures: [{ probe: "worker_probe", errorName: "TimeoutError" }] });
    expect(evaluateCapabilities(withFailures)).toEqual(evaluateCapabilities(fullReport()));
  });

  test("ブラウザの名称・版を入力に持たない（報告の型に、UA に当たる項目が無い）", () => {
    const keys = Object.keys(fullReport()).sort();
    expect(keys).toEqual(["aacEncode", "audioWorklet", "failures", "frameCapture", "screenCapture", "tabLock", "videoCodec", "webSocket"]);
    expect(Object.keys(evaluateCapabilities(fullReport())).sort()).toEqual(["canShareScreen", "canStart", "missingRequired", "tabLock", "videoCodec"]);
  });
});
