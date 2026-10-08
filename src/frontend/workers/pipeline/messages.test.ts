/**
 * @jest-environment node
 */
// メインスレッド <-> ワーカーの型付きメッセージ（issue #27）。境界を越える値は信用せず、決められた形でなければ invalid_message で拒否する。
//   メインスレッド -> ワーカー: プレビューの canvas・ソースの追加／解除（映像フレームの readable の転送）・設定（開始）・音声のポート（ブロックの受け渡し）・
//                              音声の停止／再開・ビットレート変更・キーフレーム要求・送出の開始／一時停止・設定の再取得・統計・終了
//   ワーカー -> メインスレッド: 準備完了・応答・符号化結果（ArrayBuffer の転送）・復号器設定の変化・レイアウトの変化・ソースの終了・故障
import { createDecoderConfigChunk, createEncodedChunk } from "@/lib/pipeline/chunks";
import { PipelineError } from "@/lib/pipeline/errors";
import { FAKE_AUDIO_SPECIFIC_CONFIG, FAKE_AVCC_DESCRIPTION, FakePort } from "./test-support";
import { COMMAND_TYPES, EVENT_TYPES, parseCommand, parseEvent, prepareEventForPost, transferablesOfCommand } from "./messages";
import type { PipelineEvent, PipelineStats } from "./messages";

function codeOf(action: () => unknown): string {
  try {
    action();
  } catch (error) {
    return error instanceof PipelineError ? error.code : `not a PipelineError: ${String(error)}`;
  }
  return "no error";
}

const canvas = { getContext: () => null, width: 1280, height: 720 };
const readable = { getReader: () => ({}) };
const video = createDecoderConfigChunk({ kind: "video", codec: "avc1.4D401F", description: FAKE_AVCC_DESCRIPTION });
const audio = createDecoderConfigChunk({ kind: "audio", codec: "mp4a.40.2", description: FAKE_AUDIO_SPECIFIC_CONFIG });

const STATS: PipelineStats = {
  mode: "clock",
  profile: "720p",
  videoBitrateKbps: 4500,
  layout: "camera_only",
  composedFrames: 10,
  composeFailures: 0,
  skippedForLag: 0,
  audioBacklogMs: 0,
  encodedVideoFrames: 9,
  droppedBeforeEncode: 1,
  deliveredVideoChunks: 8,
  deliveredAudioChunks: 20,
  gateOpen: true,
  gate: { closedDiscardedVideo: 1, closedDiscardedAudio: 2, skippedBeforeKeyframe: 3 },
  framesReceived: 100,
  framesClosed: 98,
  framesRetained: 2,
  videoEncodeQueueSize: 1,
  videoFaulted: false,
  audioFaulted: false,
  clock: { sampleCount: 14_700, frameIndex: 10, stalled: false },
};

describe("コマンド（メインスレッド -> ワーカー）", () => {
  const valid: Array<[string, unknown]> = [
    ["attach_preview", { type: "attach_preview", canvas }],
    ["detach_preview", { type: "detach_preview" }],
    ["add_source（画面共有）", { type: "add_source", kind: "screen", readable }],
    ["add_source（カメラ）", { type: "add_source", kind: "camera", readable }],
    ["remove_source", { type: "remove_source", kind: "camera" }],
    ["configure", { type: "configure", requestId: 1, profile: "720p", videoCodec: "avc1.4D401F", videoBitrateKbps: 4500 }],
    ["configure（480p・Constrained Baseline）", { type: "configure", requestId: 2, profile: "480p", videoCodec: "avc1.42E01F", videoBitrateKbps: 1500 }],
    ["connect_audio", { type: "connect_audio", port: new FakePort() }],
    ["audio_stalled", { type: "audio_stalled" }],
    ["audio_resumed", { type: "audio_resumed" }],
    ["set_bitrate", { type: "set_bitrate", kbps: 3150 }],
    ["request_keyframe", { type: "request_keyframe" }],
    ["begin_delivery", { type: "begin_delivery" }],
    ["pause_delivery", { type: "pause_delivery" }],
    ["get_config", { type: "get_config", requestId: 3 }],
    ["get_stats", { type: "get_stats", requestId: 4 }],
    ["end_session", { type: "end_session", requestId: 5 }],
    ["shutdown", { type: "shutdown" }],
  ];

  it.each(valid)("正しい形を受理する: %s", (_name, data) => {
    expect(parseCommand(data)).toMatchObject({ type: (data as { type: string }).type });
  });

  it("要件のコマンド（開始・停止・ソースの追加／解除・ビットレート変更・キーフレーム要求・プレビューの canvas・音声ブロックの受け渡し）が、すべて型にある", () => {
    expect(COMMAND_TYPES).toEqual(
      expect.arrayContaining(["configure", "end_session", "add_source", "remove_source", "set_bitrate", "request_keyframe", "attach_preview", "connect_audio", "begin_delivery", "pause_delivery"]),
    );
    expect(new Set(COMMAND_TYPES).size).toBe(COMMAND_TYPES.length);
  });

  it("正しい形の例が、全種類のコマンドを網羅している（受理の試験の抜けを防ぐ）", () => {
    const covered = new Set(valid.map(([, data]) => (data as { type: string }).type));

    expect(Array.from(covered).sort()).toEqual([...COMMAND_TYPES].sort());
  });

  it.each([
    ["オブジェクトでない", "configure"],
    ["null", null],
    ["type が無い", {}],
    ["未知の type", { type: "explode" }],
    ["attach_preview: canvas が無い", { type: "attach_preview" }],
    ["attach_preview: canvas が getContext を持たない", { type: "attach_preview", canvas: {} }],
    ["add_source: 未知のソース（マイク）", { type: "add_source", kind: "microphone", readable }],
    ["add_source: readable が無い", { type: "add_source", kind: "screen" }],
    ["add_source: readable が getReader を持たない", { type: "add_source", kind: "screen", readable: {} }],
    ["remove_source: 未知のソース", { type: "remove_source", kind: "slate" }],
    ["configure: requestId が無い", { type: "configure", profile: "720p", videoCodec: "avc1.4D401F", videoBitrateKbps: 4500 }],
    ["configure: requestId が 0", { type: "configure", requestId: 0, profile: "720p", videoCodec: "avc1.4D401F", videoBitrateKbps: 4500 }],
    ["configure: requestId が小数", { type: "configure", requestId: 1.5, profile: "720p", videoCodec: "avc1.4D401F", videoBitrateKbps: 4500 }],
    ["configure: 未知のプロファイル", { type: "configure", requestId: 1, profile: "1080p", videoCodec: "avc1.4D401F", videoBitrateKbps: 4500 }],
    ["configure: 未知のコーデック（High）", { type: "configure", requestId: 1, profile: "720p", videoCodec: "avc1.640028", videoBitrateKbps: 4500 }],
    ["configure: ビットレートが文字列", { type: "configure", requestId: 1, profile: "720p", videoCodec: "avc1.4D401F", videoBitrateKbps: "4500" }],
    ["configure: ビットレートが小数", { type: "configure", requestId: 1, profile: "720p", videoCodec: "avc1.4D401F", videoBitrateKbps: 4500.5 }],
    ["connect_audio: port が無い", { type: "connect_audio" }],
    ["connect_audio: port が close を持たない", { type: "connect_audio", port: { postMessage: () => undefined } }],
    ["set_bitrate: 数でない", { type: "set_bitrate", kbps: "high" }],
    ["set_bitrate: NaN", { type: "set_bitrate", kbps: Number.NaN }],
    ["get_stats: requestId が負", { type: "get_stats", requestId: -1 }],
    ["end_session: requestId が無い", { type: "end_session" }],
  ])("決められた形でないものは invalid_message: %s", (_name, data) => {
    expect(codeOf(() => parseCommand(data))).toBe("invalid_message");
  });

  it("未知のキー（前方互換の追加）は無視する。結果に含めない", () => {
    const parsed = parseCommand({ type: "set_bitrate", kbps: 3000, extra: "ignored" });

    expect(parsed).toEqual({ type: "set_bitrate", kbps: 3000 });
  });
});

describe("コマンドの転送対象（Transferable）", () => {
  it("canvas・readable・ポートは、転送する（コピーしない）。他は転送しない", () => {
    const port = new FakePort();

    expect(transferablesOfCommand({ type: "attach_preview", canvas: canvas as unknown as OffscreenCanvas })).toEqual([canvas]);
    expect(transferablesOfCommand({ type: "add_source", kind: "screen", readable: readable as unknown as ReadableStream<VideoFrame> })).toEqual([readable]);
    expect(transferablesOfCommand({ type: "connect_audio", port: port.asMessagePort() })).toEqual([port]);
    expect(transferablesOfCommand({ type: "set_bitrate", kbps: 3000 })).toEqual([]);
    expect(transferablesOfCommand({ type: "shutdown" })).toEqual([]);
  });
});

describe("イベント（ワーカー -> メインスレッド）", () => {
  const chunk = createEncodedChunk({ kind: "video", timestampUs: 33_333, keyframe: false, data: new Uint8Array([0, 0, 0, 1, 0x41]) });
  const fault = { code: "video_encoder_error", detail: "EncodingError" };
  const valid: Array<[string, unknown]> = [
    ["ready", { type: "ready" }],
    ["chunk", { type: "chunk", chunk }],
    ["decoder_config（映像）", { type: "decoder_config", config: video }],
    ["layout", { type: "layout", layout: "screen_with_wipe" }],
    ["source_ended", { type: "source_ended", kind: "camera" }],
    ["fault", { type: "fault", fault }],
    ["reply: configured", { type: "reply", requestId: 1, ok: true, result: { kind: "configured", video, audio } }],
    ["reply: config", { type: "reply", requestId: 2, ok: true, result: { kind: "config", video, audio: null } }],
    ["reply: stats", { type: "reply", requestId: 3, ok: true, result: { kind: "stats", stats: STATS } }],
    ["reply: ended", { type: "reply", requestId: 4, ok: true, result: { kind: "ended" } }],
    ["reply: 失敗", { type: "reply", requestId: 5, ok: false, fault }],
  ];

  it.each(valid)("正しい形を受理する: %s", (_name, data) => {
    expect(parseEvent(data)).toMatchObject({ type: (data as { type: string }).type });
  });

  it("イベントの種類が、重複なく定義されている", () => {
    expect(new Set(EVENT_TYPES).size).toBe(EVENT_TYPES.length);
    expect(EVENT_TYPES).toEqual(expect.arrayContaining(["ready", "reply", "chunk", "decoder_config", "layout", "source_ended", "fault"]));
  });

  it.each([
    ["オブジェクトでない", 42],
    ["未知の type", { type: "boom" }],
    ["chunk: 符号化結果の形でない", { type: "chunk", chunk: { kind: "video" } }],
    ["chunk: 時刻が負", { type: "chunk", chunk: { kind: "video", timestampUs: -1, keyframe: false, byteLength: 1, data: new Uint8Array(1) } }],
    ["decoder_config: 形でない", { type: "decoder_config", config: { kind: "video" } }],
    ["layout: 未知のレイアウト", { type: "layout", layout: "grid" }],
    ["source_ended: 未知のソース", { type: "source_ended", kind: "microphone" }],
    ["fault: 未知の符号", { type: "fault", fault: { code: "boom", detail: null } }],
    ["fault: detail が数", { type: "fault", fault: { code: "unexpected", detail: 3 } }],
    ["reply: requestId が無い", { type: "reply", ok: true, result: { kind: "ended" } }],
    ["reply: ok が真偽値でない", { type: "reply", requestId: 1, ok: "yes", result: { kind: "ended" } }],
    ["reply: 未知の結果", { type: "reply", requestId: 1, ok: true, result: { kind: "mystery" } }],
    ["reply: configured に音声の設定が無い", { type: "reply", requestId: 1, ok: true, result: { kind: "configured", video } }],
    ["reply: 失敗に fault が無い", { type: "reply", requestId: 1, ok: false }],
    ["reply: stats の項目が数でない", { type: "reply", requestId: 1, ok: true, result: { kind: "stats", stats: { ...STATS, composedFrames: "10" } } }],
    ["reply: stats の audioBacklogMs が負", { type: "reply", requestId: 1, ok: true, result: { kind: "stats", stats: { ...STATS, audioBacklogMs: -1 } } }],
    ["reply: stats の audioBacklogMs が小数", { type: "reply", requestId: 1, ok: true, result: { kind: "stats", stats: { ...STATS, audioBacklogMs: 1.5 } } }],
    ["reply: stats に audioBacklogMs が無い", { type: "reply", requestId: 1, ok: true, result: { kind: "stats", stats: { ...STATS, audioBacklogMs: undefined } } }],
    ["reply: stats の clock が不正", { type: "reply", requestId: 1, ok: true, result: { kind: "stats", stats: { ...STATS, clock: { sampleCount: -1, frameIndex: 0, stalled: false } } } }],
  ])("決められた形でないものは invalid_message: %s", (_name, data) => {
    expect(codeOf(() => parseEvent(data))).toBe("invalid_message");
  });

  it("stats の clock は null でもよい（音声のクロックが無い間）", () => {
    const parsed = parseEvent({ type: "reply", requestId: 1, ok: true, result: { kind: "stats", stats: { ...STATS, clock: null, layout: null, profile: null, videoBitrateKbps: null, mode: "preview" } } });

    expect(parsed).toMatchObject({ type: "reply", ok: true });
  });
});

describe("イベントの送り出し（prepareEventForPost）", () => {
  it("符号化結果は、ArrayBuffer を転送する（コピーしない）", () => {
    const data = new Uint8Array([1, 2, 3, 4]);
    const event: PipelineEvent = { type: "chunk", chunk: createEncodedChunk({ kind: "audio", timestampUs: 0, keyframe: false, data }) };

    const prepared = prepareEventForPost(event);

    expect(prepared.message).toBe(event);
    expect(prepared.transfer).toEqual([data.buffer]);
  });

  it("バッファの一部だけを指すビューは、転送すると他のデータを巻き込むので、正確な大きさの新しいバッファへ複写してから転送する", () => {
    const whole = new Uint8Array([9, 9, 1, 2, 3, 9]);
    const view = whole.subarray(2, 5);
    const event: PipelineEvent = { type: "chunk", chunk: createEncodedChunk({ kind: "video", timestampUs: 0, keyframe: true, data: view }) };

    const prepared = prepareEventForPost(event);

    const chunk = (prepared.message as Extract<PipelineEvent, { type: "chunk" }>).chunk;
    expect(Array.from(chunk.data)).toEqual([1, 2, 3]);
    expect(chunk.data.buffer.byteLength).toBe(3);
    expect(prepared.transfer).toEqual([chunk.data.buffer]);
    expect(whole.buffer.byteLength).toBe(6);
  });

  it("符号化結果以外は、転送しない", () => {
    expect(prepareEventForPost({ type: "ready" })).toEqual({ message: { type: "ready" }, transfer: [] });
    expect(prepareEventForPost({ type: "layout", layout: "slate" }).transfer).toEqual([]);
  });
});
