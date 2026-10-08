/**
 * @jest-environment node
 */
// PipelineClient（メインスレッド側のワーカーのクライアント。issue #27）。
//   - 映像ソース: メインスレッドで MediaStreamTrackProcessor を作り、その readable をワーカーへ転送する（Chrome では、ワーカー内で processor は使えず、
//     MediaStreamTrack も転送できない）。プレビュー: <canvas> を transferControlToOffscreen してワーカーへ渡す
//   - 音声: #26 のミキサーの出力先（MessagePort）を作り、ワーカーへ渡す（ブロックは、メインスレッドを経由せず、ワーカーへ直接届く）。停止・再開は転送する
//   - 型付きのメッセージ。応答のある要求は、requestId で対応づけ、期限を持つ（有限時間で終端へ進む）
//   - ワーカーの異常終了（error イベント）を検知して通知する。terminate で資源を解放する。メッセージ・例外に機密を載せない
import { createDecoderConfigChunk, createEncodedChunk } from "./chunks";
import { PIPELINE_REQUEST_TIMEOUT_MS, PIPELINE_START_TIMEOUT_MS } from "./config";
import { PipelineError } from "./errors";
import type { PipelineFault } from "./errors";
import { PipelineClient } from "./PipelineClient";
import type { TrackReadable } from "./trackReadable";
import { FakePreviewCanvas, FakeTimers, FakeVideoTrack, FakeWorker } from "./test-support";
import type { DecoderConfigChunk, EncodedChunk } from "./chunks";
import type { Layout } from "@/core/contract";
import type { PipelineStats } from "@/workers/pipeline/messages";
import { FAKE_AUDIO_SPECIFIC_CONFIG, FAKE_AVCC_DESCRIPTION } from "@/workers/pipeline/test-support";

const channels: MessageChannel[] = [];

afterEach(() => {
  for (const channel of channels.splice(0)) {
    channel.port1.close();
    channel.port2.close();
  }
});

interface Setup {
  readonly worker: FakeWorker;
  readonly timers: FakeTimers;
  readonly client: PipelineClient;
  readonly chunks: EncodedChunk[];
  readonly faults: PipelineFault[];
  readonly configChanges: DecoderConfigChunk[];
  readonly layouts: Layout[];
  readonly ended: string[];
  readonly createdReadables: Array<{ track: MediaStreamTrack; readable: ReadableStream<VideoFrame> }>;
  readonly channel: MessageChannel;
  readonly workersCreated: () => number;
}

function setup(options: { createWorker?: () => FakeWorker } = {}): Setup {
  const worker = new FakeWorker();
  const timers = new FakeTimers();
  const chunks: EncodedChunk[] = [];
  const faults: PipelineFault[] = [];
  const configChanges: DecoderConfigChunk[] = [];
  const layouts: Layout[] = [];
  const ended: string[] = [];
  const createdReadables: Array<{ track: MediaStreamTrack; readable: ReadableStream<VideoFrame> }> = [];
  const channel = new MessageChannel();
  channels.push(channel);
  let created = 0;
  const client = new PipelineClient({
    createWorker:
      options.createWorker ??
      (() => {
        created += 1;
        return worker;
      }),
    createTrackReadable: (track): TrackReadable => {
      const readable = new ReadableStream<VideoFrame>();
      createdReadables.push({ track, readable });
      return { readable, processor: { track } };
    },
    createMessageChannel: () => channel,
    timers,
    onChunk: (chunk) => chunks.push(chunk),
    onFault: (fault) => faults.push(fault),
    onDecoderConfigChanged: (config) => configChanges.push(config),
    onLayoutChanged: (layout) => layouts.push(layout),
    onSourceEnded: (kind) => ended.push(kind),
  });
  return { worker, timers, client, chunks, faults, configChanges, layouts, ended, createdReadables, channel, workersCreated: () => created };
}

async function started(context: Setup = setup()): Promise<Setup> {
  const starting = context.client.start();
  context.worker.emit({ type: "ready" });
  await starting;
  return context;
}

async function codeOf(promise: Promise<unknown>): Promise<string> {
  try {
    await promise;
  } catch (error) {
    return error instanceof PipelineError ? error.code : `not a PipelineError: ${String(error)}`;
  }
  return "resolved";
}

function codeOfSync(action: () => unknown): string {
  try {
    action();
  } catch (error) {
    return error instanceof PipelineError ? error.code : `not a PipelineError: ${String(error)}`;
  }
  return "no error";
}

const video = createDecoderConfigChunk({ kind: "video", codec: "avc1.4D401F", description: FAKE_AVCC_DESCRIPTION });
const audio = createDecoderConfigChunk({ kind: "audio", codec: "mp4a.40.2", description: FAKE_AUDIO_SPECIFIC_CONFIG });

describe("起動", () => {
  it("ワーカーを 1 つ作り、準備完了（ready）の通知で start が解決する。2 回目の start は invalid_state", async () => {
    const context = setup();
    const starting = context.client.start();
    expect(context.workersCreated()).toBe(1);
    expect(context.worker.onmessage).not.toBeNull();

    context.worker.emit({ type: "ready" });
    await starting;

    expect(await codeOf(context.client.start())).toBe("invalid_state");
    expect(context.workersCreated()).toBe(1);
  });

  it("期限内に ready が無ければ worker_start_timeout。ワーカーを終了する（待ち続けない）", async () => {
    const context = setup();
    const starting = context.client.start();

    context.timers.advance(PIPELINE_START_TIMEOUT_MS + 1);

    expect(await codeOf(starting)).toBe("worker_start_timeout");
    expect(context.worker.terminateCount).toBe(1);
  });

  it("ready の前に、ワーカーが故障（起動の失敗）を知らせたら、その符号で start が拒否される。ワーカーを終了する", async () => {
    const context = setup();
    const starting = context.client.start();

    context.worker.emit({ type: "fault", fault: { code: "environment_unsupported", detail: null } });

    expect(await codeOf(starting)).toBe("environment_unsupported");
    expect(context.worker.terminateCount).toBe(1);
  });

  it("ready の前に、ワーカーのスクリプトの読み込みが失敗（error イベント）したら worker_crashed", async () => {
    const context = setup();
    const starting = context.client.start();

    context.worker.crash();

    expect(await codeOf(starting)).toBe("worker_crashed");
    expect(context.worker.terminateCount).toBe(1);
  });

  it("ワーカーを作れなければ（createWorker が例外）worker_crashed。元のエラーの名前を残す", async () => {
    const context = setup({
      createWorker: () => {
        throw new DOMException("blocked by CSP", "SecurityError");
      },
    });

    try {
      await context.client.start();
      throw new Error("should have thrown");
    } catch (error) {
      expect((error as PipelineError).code).toBe("worker_crashed");
      expect((error as PipelineError).detail).toBe("SecurityError");
    }
  });

  it("start の前の操作は invalid_state", () => {
    const { client } = setup();

    expect(codeOfSync(() => client.requestKeyframe())).toBe("invalid_state");
    expect(codeOfSync(() => client.detachPreview())).toBe("invalid_state");
  });
});

describe("プレビュー（transferControlToOffscreen）", () => {
  it("<canvas> を OffscreenCanvas にして、ワーカーへ転送する（コピーしない）", async () => {
    const { client, worker } = await started();
    const canvas = new FakePreviewCanvas();

    client.attachPreview(canvas);

    const posted = worker.commands("attach_preview");
    expect(posted).toHaveLength(1);
    expect(posted[0].message.canvas).toBe(canvas.offscreen);
    expect(posted[0].transfer).toEqual([canvas.offscreen]);
  });

  it("同じ <canvas> を 2 回渡すと preview_already_transferred（transferControlToOffscreen は 1 回だけ。2 回目は呼ばない）", async () => {
    const { client, worker } = await started();
    const canvas = new FakePreviewCanvas();
    client.attachPreview(canvas);

    expect(codeOfSync(() => client.attachPreview(canvas))).toBe("preview_already_transferred");

    expect(canvas.transferCount).toBe(1);
    expect(worker.commands("attach_preview")).toHaveLength(1);
  });

  it("別の <canvas>（画面の作り直し）なら、渡せる", async () => {
    const { client, worker } = await started();

    client.attachPreview(new FakePreviewCanvas());
    client.detachPreview();
    client.attachPreview(new FakePreviewCanvas());

    expect(worker.commands("attach_preview")).toHaveLength(2);
    expect(worker.commands("detach_preview")).toHaveLength(1);
  });

  it("transferControlToOffscreen が失敗したら（すでに getContext した <canvas> など）preview_unavailable。元のエラーの名前を残す", async () => {
    const { client, worker } = await started();
    const canvas = new FakePreviewCanvas();
    canvas.failWith = new DOMException("context already created", "InvalidStateError");

    try {
      client.attachPreview(canvas);
      throw new Error("should have thrown");
    } catch (error) {
      expect((error as PipelineError).code).toBe("preview_unavailable");
      expect((error as PipelineError).detail).toBe("InvalidStateError");
    }
    expect(worker.commands("attach_preview")).toHaveLength(0);
  });
});

describe("映像ソース（MediaStreamTrackProcessor の readable を転送する）", () => {
  it("トラックから readable を作り、ワーカーへ転送する。トラック自体は転送しない（転送できない）", async () => {
    const { client, worker, createdReadables } = await started();
    const track = new FakeVideoTrack();

    client.addVideoSource("camera", track.asTrack());

    expect(createdReadables).toHaveLength(1);
    expect(createdReadables[0].track).toBe(track);
    const posted = worker.commands("add_source");
    expect(posted).toHaveLength(1);
    expect(posted[0].message.kind).toBe("camera");
    expect(posted[0].message.readable).toBe(createdReadables[0].readable);
    expect(posted[0].transfer).toEqual([createdReadables[0].readable]);
    expect(JSON.stringify(Object.keys(posted[0].message))).not.toContain("track");
  });

  it("未知のソースの種類・映像でないトラック は RangeError、終了したトラックは invalid_state（readable を作らない）", async () => {
    const { client, createdReadables } = await started();
    const audioTrack = new FakeVideoTrack();
    audioTrack.kind = "audio";
    const endedTrack = new FakeVideoTrack();
    endedTrack.readyState = "ended";

    expect(() => client.addVideoSource("microphone" as never, new FakeVideoTrack().asTrack())).toThrow(RangeError);
    expect(() => client.addVideoSource("camera", audioTrack.asTrack())).toThrow(RangeError);
    expect(codeOfSync(() => client.addVideoSource("camera", endedTrack.asTrack()))).toBe("invalid_state");
    expect(createdReadables).toHaveLength(0);
  });

  it("removeVideoSource: ワーカーへ知らせ、processor の参照を手放す。同じ種類を追加し直すと、前の参照を手放して、置き換える（保持は 1 つ）", async () => {
    const { client, worker } = await started();
    client.addVideoSource("camera", new FakeVideoTrack().asTrack());
    client.addVideoSource("camera", new FakeVideoTrack().asTrack());
    expect(client.heldSourceCount).toBe(1);

    client.removeVideoSource("camera");

    expect(worker.commands("remove_source")).toHaveLength(1);
    expect(client.heldSourceCount).toBe(0);
  });

  it("ワーカーが source_ended（トラックの終了）を知らせたら、processor の参照を手放し、通知先へ伝える", async () => {
    const { client, worker, ended } = await started();
    client.addVideoSource("screen", new FakeVideoTrack().asTrack());
    expect(client.heldSourceCount).toBe(1);

    worker.emit({ type: "source_ended", kind: "screen" });

    expect(client.heldSourceCount).toBe(0);
    expect(ended).toEqual(["screen"]);
  });
});

describe("音声（#26 のミキサーの出力先）", () => {
  it("openAudioSink: MessageChannel の片方をワーカーへ転送し、もう片方を返す（ミキサーの start({ sink }) へ渡す）", async () => {
    const { client, worker, channel } = await started();

    const sink = client.openAudioSink();

    expect(sink).toBe(channel.port2);
    const posted = worker.commands("connect_audio");
    expect(posted).toHaveLength(1);
    expect(posted[0].message.port).toBe(channel.port1);
    expect(posted[0].transfer).toEqual([channel.port1]);
  });

  it("audioListener: AudioContext の停止・再開を、ワーカーへ転送する（メディアクロックの停止・再開へつながる）", async () => {
    const { client, worker } = await started();

    client.audioListener.onStall?.();
    client.audioListener.onResume?.();

    expect(worker.commands("audio_stalled")).toHaveLength(1);
    expect(worker.commands("audio_resumed")).toHaveLength(1);
  });

  it("終了したクライアントの audioListener は、例外を投げず、何もしない（ミキサーの購読者の例外は、混合を止めないが、握りつぶさず投げ直されるため）", async () => {
    const { client, worker } = await started();
    client.terminate();

    expect(() => client.audioListener.onStall?.()).not.toThrow();
    expect(worker.commands("audio_stalled")).toHaveLength(0);
  });
});

describe("応答のある要求", () => {
  it("configure: 設定を送り、ワーカーの応答（映像・音声の復号器設定）で解決する。requestId で対応づける", async () => {
    const { client, worker } = await started();

    const configuring = client.configure({ profile: "720p", videoCodec: "avc1.4D401F", videoBitrateKbps: 4500 });
    const requestId = worker.lastRequestId("configure");
    worker.emit({ type: "reply", requestId, ok: true, result: { kind: "configured", video, audio } });

    const result = await configuring;
    expect(result.video.kind).toBe("video");
    expect(result.audio.kind).toBe("audio");
    expect(worker.commands("configure")[0].message).toMatchObject({ profile: "720p", videoCodec: "avc1.4D401F", videoBitrateKbps: 4500 });
  });

  it("失敗の応答は、その符号の PipelineError で拒否される（AAC が使えない環境の audio_config_unsupported など）", async () => {
    const { client, worker } = await started();

    const configuring = client.configure({ profile: "720p", videoCodec: "avc1.4D401F", videoBitrateKbps: 4500 });
    worker.emit({ type: "reply", requestId: worker.lastRequestId("configure"), ok: false, fault: { code: "audio_config_unsupported", detail: null } });

    expect(await codeOf(configuring)).toBe("audio_config_unsupported");
  });

  it("範囲外のビットレートは、ワーカーへ送る前に bitrate_out_of_range（往復を待たない）", async () => {
    const { client, worker } = await started();

    expect(await codeOf(client.configure({ profile: "720p", videoCodec: "avc1.4D401F", videoBitrateKbps: 9000 }))).toBe("bitrate_out_of_range");
    expect(worker.commands("configure")).toHaveLength(0);
  });

  it("期限内に応答が無ければ request_timeout（待ち続けない）。遅れて届いた応答は、無視する", async () => {
    const { client, worker, timers } = await started();
    const configuring = client.configure({ profile: "720p", videoCodec: "avc1.4D401F", videoBitrateKbps: 4500 });
    const requestId = worker.lastRequestId("configure");

    timers.advance(PIPELINE_REQUEST_TIMEOUT_MS + 1);
    expect(await codeOf(configuring)).toBe("request_timeout");
    expect(() => worker.emit({ type: "reply", requestId, ok: true, result: { kind: "ended" } })).not.toThrow();
  });

  it("応答が届いたら、期限のタイマを止める（タイマが残らない）", async () => {
    const { client, worker, timers } = await started();
    const before = timers.activeCount;

    const stats = client.getStats();
    expect(timers.activeCount).toBe(before + 1);
    worker.emit({
      type: "reply",
      requestId: worker.lastRequestId("get_stats"),
      ok: true,
      result: { kind: "stats", stats: STATS },
    });
    await stats;

    expect(timers.activeCount).toBe(before);
  });

  it("getConfig・getStats・endSession: それぞれ、応答の中身で解決する", async () => {
    const { client, worker } = await started();

    const config = client.getConfig();
    worker.emit({ type: "reply", requestId: worker.lastRequestId("get_config"), ok: true, result: { kind: "config", video, audio: null } });
    const stats = client.getStats();
    worker.emit({ type: "reply", requestId: worker.lastRequestId("get_stats"), ok: true, result: { kind: "stats", stats: STATS } });
    const ending = client.endSession();
    worker.emit({ type: "reply", requestId: worker.lastRequestId("end_session"), ok: true, result: { kind: "ended" } });

    expect((await config).video?.kind).toBe("video");
    expect((await config).audio).toBeNull();
    expect((await stats).droppedBeforeEncode).toBe(2);
    await expect(ending).resolves.toBeUndefined();
  });

  it("応答の種類が要求と違えば invalid_message（取り違えて続けない）", async () => {
    const { client, worker } = await started();

    const stats = client.getStats();
    worker.emit({ type: "reply", requestId: worker.lastRequestId("get_stats"), ok: true, result: { kind: "ended" } });

    expect(await codeOf(stats)).toBe("invalid_message");
  });

  it("requestId は要求ごとに異なる。知らない requestId の応答は無視する", async () => {
    const { client, worker, faults } = await started();
    void client.getStats();
    void client.getStats();
    const ids = worker.commands("get_stats").map((entry) => entry.message.requestId);

    worker.emit({ type: "reply", requestId: 9999, ok: true, result: { kind: "ended" } });

    expect(new Set(ids).size).toBe(2);
    expect(faults).toEqual([]);
  });
});

describe("コマンド（応答のないもの）", () => {
  it("setBitrate・requestKeyframe・beginDelivery・pauseDelivery を、型付きのメッセージで送る", async () => {
    const { client, worker } = await started();

    client.setBitrate(3150);
    client.requestKeyframe();
    client.beginDelivery();
    client.pauseDelivery();

    expect(worker.commands("set_bitrate")[0].message).toEqual({ type: "set_bitrate", kbps: 3150 });
    expect(worker.commands("request_keyframe")).toHaveLength(1);
    expect(worker.commands("begin_delivery")).toHaveLength(1);
    expect(worker.commands("pause_delivery")).toHaveLength(1);
  });

  it("目標ビットレートが有限の数でなければ RangeError（送らない）", async () => {
    const { client, worker } = await started();

    expect(() => client.setBitrate(Number.NaN)).toThrow(RangeError);
    expect(() => client.setBitrate(Number.POSITIVE_INFINITY)).toThrow(RangeError);
    expect(worker.commands("set_bitrate")).toHaveLength(0);
  });

  it("postMessage が失敗したら（転送できないものを渡した、など）unexpected。元のエラーの名前を残す", async () => {
    const { client, worker } = await started();
    worker.failPost = new DOMException("could not be cloned", "DataCloneError");

    try {
      client.beginDelivery();
      throw new Error("should have thrown");
    } catch (error) {
      expect((error as PipelineError).code).toBe("unexpected");
      expect((error as PipelineError).detail).toBe("DataCloneError");
    }
  });
});

describe("ワーカーからのイベント", () => {
  it("符号化結果・復号器設定の変化・レイアウトの変化・ソースの終了・故障を、通知先へ伝える", async () => {
    const { worker, chunks, configChanges, layouts, ended, faults } = await started();
    const chunk = createEncodedChunk({ kind: "video", timestampUs: 33_333, keyframe: false, data: new Uint8Array([0, 0, 0, 1, 0x41]) });

    worker.emit({ type: "chunk", chunk });
    worker.emit({ type: "decoder_config", config: video });
    worker.emit({ type: "layout", layout: "camera_only" });
    worker.emit({ type: "source_ended", kind: "camera" });
    worker.emit({ type: "fault", fault: { code: "video_encoder_error", detail: "EncodingError" } });

    expect(chunks).toEqual([chunk]);
    expect(configChanges).toEqual([video]);
    expect(layouts).toEqual(["camera_only"]);
    expect(ended).toEqual(["camera"]);
    expect(faults).toEqual([{ code: "video_encoder_error", detail: "EncodingError" }]);
  });

  it("決められた形でないメッセージは、invalid_message の故障として知らせる（例外にせず、以後のメッセージは受け付ける）", async () => {
    const { worker, faults, layouts } = await started();

    worker.emitRaw({ type: "boom" });
    worker.emitRaw("text");
    worker.emit({ type: "layout", layout: "slate" });

    expect(faults).toEqual([
      { code: "invalid_message", detail: null },
      { code: "invalid_message", detail: null },
    ]);
    expect(layouts).toEqual(["slate"]);
  });

  it("デシリアライズに失敗したメッセージ（messageerror）も、invalid_message の故障として知らせる", async () => {
    const { worker, faults } = await started();

    worker.onmessageerror?.({} as MessageEvent);

    expect(faults).toEqual([{ code: "invalid_message", detail: null }]);
  });
});

describe("ワーカーの異常終了を検知して通知する", () => {
  it("error イベントで、worker_crashed の故障を 1 回だけ通知する。ワーカーを終了し、待っていた要求を拒否する。エラーの文面（URL などを含み得る）は載せない", async () => {
    const { client, worker, faults } = await started();
    const pending = client.getStats();

    worker.crash();
    worker.crash();

    expect(faults).toEqual([{ code: "worker_crashed", detail: null }]);
    expect(JSON.stringify(faults)).not.toContain("secret");
    expect(worker.terminateCount).toBe(1);
    expect(await codeOf(pending)).toBe("worker_crashed");
  });

  it("異常終了のあとの操作は invalid_state（死んだワーカーへ送り続けない）。processor の参照も手放す", async () => {
    const { client, worker } = await started();
    client.addVideoSource("camera", new FakeVideoTrack().asTrack());

    worker.crash();

    expect(codeOfSync(() => client.beginDelivery())).toBe("invalid_state");
    expect(await codeOf(client.getStats())).toBe("invalid_state");
    expect(client.heldSourceCount).toBe(0);
  });
});

describe("terminate（資源の解放）", () => {
  it("shutdown を送り、ワーカーを終了し、processor の参照を手放し、待っていた要求を terminated で拒否する。何度呼んでもよい", async () => {
    const { client, worker } = await started();
    client.addVideoSource("camera", new FakeVideoTrack().asTrack());
    const pending = client.getStats();

    client.terminate();
    client.terminate();

    expect(worker.commands("shutdown")).toHaveLength(1);
    expect(worker.terminateCount).toBe(1);
    expect(client.heldSourceCount).toBe(0);
    expect(await codeOf(pending)).toBe("terminated");
    expect(codeOfSync(() => client.requestKeyframe())).toBe("invalid_state");
  });

  it("shutdown を送れなくても（postMessage が失敗）、ワーカーは終了する（資源を残さない）", async () => {
    const { client, worker } = await started();
    worker.failPost = new Error("port closed");

    expect(() => client.terminate()).not.toThrow();

    expect(worker.terminateCount).toBe(1);
  });

  it("start の最中に terminate すると、start は terminated で拒否される", async () => {
    const context = setup();
    const starting = context.client.start();

    context.client.terminate();

    expect(await codeOf(starting)).toBe("terminated");
    expect(context.worker.terminateCount).toBe(1);
  });

  it("start する前の terminate は、何も起こさない", () => {
    const { client, worker } = setup();

    expect(() => client.terminate()).not.toThrow();
    expect(worker.terminateCount).toBe(0);
  });
});

describe("トラックの扱い（止めるのは SourceManager。#26）", () => {
  it("映像ソースの追加・解除・終了の通知・配信の終了・terminate のどれでも、トラックを stop() しない", async () => {
    const context = await started();
    const camera = new FakeVideoTrack();
    const screen = new FakeVideoTrack();

    context.client.addVideoSource("camera", camera.asTrack());
    context.client.addVideoSource("screen", screen.asTrack());
    context.client.removeVideoSource("screen");
    context.worker.emit({ type: "source_ended", kind: "camera" });
    const ending = context.client.endSession();
    context.worker.emit({ type: "reply", requestId: context.worker.lastRequestId("end_session"), ok: true, result: { kind: "ended" } });
    await ending;
    context.client.terminate();

    expect(camera.stopCount).toBe(0);
    expect(screen.stopCount).toBe(0);
    expect(camera.readyState).toBe("live");
    expect(screen.readyState).toBe("live");
  });

  it("同じ種類のソースを置き換えても、前のトラックを stop() しない（前の readable をワーカーが閉じる）", async () => {
    const context = await started();
    const first = new FakeVideoTrack();
    const second = new FakeVideoTrack();

    context.client.addVideoSource("camera", first.asTrack());
    context.client.addVideoSource("camera", second.asTrack());

    expect(first.stopCount).toBe(0);
    expect(second.stopCount).toBe(0);
    expect(context.client.heldSourceCount).toBe(1);
  });

  it("終了済みのトラックは invalid_state で断る。断るときも stop() しない", async () => {
    const context = await started();
    const ended = new FakeVideoTrack();
    ended.readyState = "ended";

    expect(codeOfSync(() => context.client.addVideoSource("camera", ended.asTrack()))).toBe("invalid_state");
    expect(ended.stopCount).toBe(0);
    expect(context.client.heldSourceCount).toBe(0);
  });
});

const STATS: PipelineStats = {
  mode: "clock",
  profile: "720p",
  videoBitrateKbps: 4500,
  layout: "screen_only",
  composedFrames: 100,
  composeFailures: 0,
  skippedForLag: 0,
  audioBacklogMs: 0,
  encodedVideoFrames: 98,
  droppedBeforeEncode: 2,
  deliveredVideoChunks: 90,
  deliveredAudioChunks: 200,
  gateOpen: true,
  gate: { closedDiscardedVideo: 0, closedDiscardedAudio: 0, skippedBeforeKeyframe: 0 },
  framesReceived: 300,
  framesClosed: 299,
  framesRetained: 1,
  videoEncodeQueueSize: 0,
  videoFaulted: false,
  audioFaulted: false,
  clock: { sampleCount: 147_000, frameIndex: 100, stalled: false },
};
