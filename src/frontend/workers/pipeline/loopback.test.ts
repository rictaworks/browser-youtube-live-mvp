/**
 * @jest-environment node
 */
// クライアント（PipelineClient）とワーカー（startPipelineWorker + PipelineHost）を、メモリの中でつなぎ、実際のコード同士のメッセージの往復を確かめる
// （issue #27）。クライアントの試験は疑似のワーカー、ホストの試験は疑似のメインスレッドで行うので、両側の取り決め（メッセージの種類・項目・検証）の
// 食い違いは、ここで検知する。実ブラウザでの確認（構造化複製・転送・実際のエンコーダ）は、test/prNEW_issue27 の probe が受け持つ。
//   - SourceManager（#26）の変化 -> applySourceChange -> クライアント -> ワーカーの合成が選ぶレイアウトが、SourceChange.layout と一致する
//   - 設定 -> 送出 -> キーフレーム要求 -> ビットレートの変更 -> 停止・再開 -> 配信の終了 -> 終了
//   - ワーカーの異常終了
import { PipelineClient } from "@/lib/pipeline/PipelineClient";
import { applySourceChange } from "@/lib/pipeline/sourceBridge";
import { FakeTimers } from "@/lib/pipeline/test-support";
import type { DecoderConfigChunk, EncodedChunk } from "@/lib/pipeline/chunks";
import type { PipelineFault } from "@/lib/pipeline/errors";
import { PipelineError } from "@/lib/pipeline/errors";
import { FakeMediaDevices } from "@/lib/sources/test-support";
import { SourceManager } from "@/lib/sources/SourceManager";
import type { Layout } from "@/core/contract";
import { audioTimeUs, videoTimeUs } from "@/core/clock";
import { settle } from "./host-support";
import { Loopback } from "./loopback-support";
import { FAKE_AUDIO_SPECIFIC_CONFIG, FAKE_AVCC_DESCRIPTION, FakeAudioEncoder, FakeVideoEncoder } from "./test-support";

function setup() {
  const loop = new Loopback();
  const timers = new FakeTimers();
  const chunks: EncodedChunk[] = [];
  const faults: PipelineFault[] = [];
  const layouts: Layout[] = [];
  const ended: string[] = [];
  const configChanges: DecoderConfigChunk[] = [];
  const client = new PipelineClient({
    createWorker: loop.createWorker,
    createTrackReadable: loop.createTrackReadable,
    createMessageChannel: loop.createMessageChannel,
    timers,
    onChunk: (chunk) => chunks.push(chunk),
    onFault: (fault) => faults.push(fault),
    onLayoutChanged: (layout) => layouts.push(layout),
    onSourceEnded: (kind) => ended.push(kind),
    onDecoderConfigChanged: (config) => configChanges.push(config),
  });
  return { loop, timers, chunks, faults, layouts, ended, configChanges, client };
}

/** 配信を設定し、最初の出力（復号器設定）を得るまで、音声を流す。 */
async function configureStream(context: ReturnType<typeof setup>) {
  const { loop, client } = context;
  client.openAudioSink();
  const configured = client.configure({ profile: "720p", videoCodec: "avc1.4D401F", videoBitrateKbps: 4500 });
  await settle();
  loop.feedAudioSeconds(0.3);
  return configured;
}

describe("起動とプレビュー", () => {
  it("start は ready で解決し、プレビューの canvas がワーカーへ渡り、プレビューだけの間は、符号化しない", async () => {
    const { loop, client, layouts } = setup();

    await client.start();
    client.attachPreview(loop.previewSource);
    await settle();
    loop.worker.scheduler.advance(100);
    await settle();

    expect(loop.worker.eventsToClient("ready")).toHaveLength(1);
    expect(loop.worker.commands("attach_preview")).toHaveLength(1);
    expect(layouts).toEqual(["slate"]);
    expect(FakeVideoEncoder.instances).toHaveLength(0);
    expect(loop.worker.videoFrames.created).toHaveLength(0);
    // 代替スレートを、プレビュー用のキャンバスへ描いた（合成用のキャンバスとは別）
    expect(loop.previewCanvas.context.calls.length).toBeGreaterThan(0);
    client.terminate();
  });
});

describe("SourceManager の変化に合わせて、ワーカーの合成が選ぶレイアウトは、SourceChange.layout と一致する", () => {
  it("カメラ -> 画面共有 -> 画面共有の終了 -> カメラの解除", async () => {
    const { loop, client, layouts, faults } = setup();
    await client.start();
    client.attachPreview(loop.previewSource);
    const devices = new FakeMediaDevices();
    const errors: unknown[] = [];
    const manager = new SourceManager({ mediaDevices: devices.asMediaDevices(), onError: (error) => errors.push(error) });
    const managerLayouts: Layout[] = ["slate"];
    manager.subscribe((change) => {
      if (change.layoutChanged) {
        managerLayouts.push(change.layout);
      }
      applySourceChange(client, change);
    });
    const step = async (): Promise<Layout | undefined> => {
      await settle();
      loop.worker.scheduler.advance(40);
      await settle();
      return layouts[layouts.length - 1];
    };

    expect(await step()).toBe("slate");

    const camera = await manager.attach("camera");
    expect(camera.track).not.toBeNull();
    loop.feedFrame(camera.track, 640, 480);
    expect(await step()).toBe(manager.layout);
    expect(manager.layout).toBe("camera_only");

    const screen = await manager.attach("screen");
    loop.feedFrame(screen.track, 1920, 1080);
    expect(await step()).toBe(manager.layout);
    expect(manager.layout).toBe("screen_with_wipe");

    manager.onTrackEnded("screen");
    expect(await step()).toBe(manager.layout);
    expect(manager.layout).toBe("camera_only");

    const cameraTrack = camera.track as unknown as { stopCount: number };
    expect(cameraTrack.stopCount).toBe(0);
    manager.detach("camera");
    expect(await step()).toBe(manager.layout);
    expect(manager.layout).toBe("slate");

    // ワーカーが選んだレイアウトの列は、マネージャが通知したレイアウトの列と同じ
    expect(layouts).toEqual(managerLayouts);
    expect(layouts).toEqual(["slate", "camera_only", "screen_with_wipe", "camera_only", "slate"]);
    // トラックを止めたのは、マネージャの 1 回だけ（パイプラインは止めない）
    expect(cameraTrack.stopCount).toBe(1);
    // 外したソースのフレームは、すべて閉じられた
    for (const source of loop.sources.values()) {
      expect(source.ledger.openCount).toBe(0);
      expect(source.ledger.doubleClosedCount).toBe(0);
    }
    expect(errors).toEqual([]);
    expect(faults).toEqual([]);
    manager.dispose();
    client.terminate();
  });
});

describe("設定 -> 送出 -> 適応制御 -> 停止・再開 -> 終了", () => {
  it("復号器設定を得て、送出を始めると、映像（キーフレームから）と音声の符号化結果が、メディア時刻つきで届く", async () => {
    const context = setup();
    const { loop, client, chunks, faults, configChanges } = context;
    await client.start();

    const configured = await configureStream(context);

    expect(configured.video.codec).toBe("avc1.4D401F");
    expect(Array.from(configured.video.description)).toEqual(Array.from(FAKE_AVCC_DESCRIPTION));
    expect(configured.audio.codec).toBe("mp4a.40.2");
    expect(Array.from(configured.audio.description)).toEqual(Array.from(FAKE_AUDIO_SPECIFIC_CONFIG));
    // 送出を始めるまでは、符号化結果を渡さない
    expect(chunks).toEqual([]);

    // メッセージはメモリの中でも非同期に届く（本物のワーカーと同じ）。beginDelivery が届いてから、音声を流す
    client.beginDelivery();
    await settle();
    loop.feedAudioSeconds(1);
    await settle();

    const video = chunks.filter((chunk) => chunk.kind === "video");
    const audio = chunks.filter((chunk) => chunk.kind === "audio");
    expect(video.length).toBeGreaterThan(20);
    expect(audio.length).toBeGreaterThan(30);
    expect(video[0].keyframe).toBe(true);
    expect(video.every((chunk) => videoTimeUs(Math.round((chunk.timestampUs * 30) / 1_000_000)) === chunk.timestampUs)).toBe(true);
    expect(video.every((chunk, index) => index === 0 || chunk.timestampUs > video[index - 1].timestampUs)).toBe(true);
    expect(audio.every((chunk) => !chunk.keyframe)).toBe(true);
    const firstAudioSample = Math.round((audio[0].timestampUs * 44_100) / 1_000_000 / 128) * 128;
    expect(audio.every((chunk, index) => chunk.timestampUs === audioTimeUs(firstAudioSample + index * 1024))).toBe(true);
    expect(video.every((chunk) => chunk.byteLength === chunk.data.length)).toBe(true);
    expect(configChanges).toEqual([]);
    expect(faults).toEqual([]);
    client.terminate();
  });

  it("キーフレームの要求・ビットレートの変更・停止と再開が、ワーカーへ届き、符号化に反映される", async () => {
    const context = setup();
    const { loop, client, chunks, faults, configChanges } = context;
    await client.start();
    await configureStream(context);
    client.beginDelivery();
    await settle();
    loop.feedAudioSeconds(0.5);
    await settle();

    // ビットレートの変更: 再設定。復号器設定の内容は変わらないので、通知は無い
    client.setBitrate(3000);
    loop.feedAudioSeconds(0.2);
    await settle();
    const encoder = FakeVideoEncoder.instances[0];
    expect(encoder.configureCalls.map((call) => call.bitrate)).toEqual([4_500_000, 3_000_000]);
    expect(configChanges).toEqual([]);

    // キーフレームの要求: 次に符号化するフレームが、キーフレームになる
    const before = chunks.filter((chunk) => chunk.kind === "video").length;
    client.requestKeyframe();
    loop.feedAudioSeconds(0.2);
    await settle();
    const requested = chunks.filter((chunk) => chunk.kind === "video").slice(before);
    expect(requested.length).toBeGreaterThan(0);
    expect(requested[0].keyframe).toBe(true);

    // 音声の停止（AudioContext の suspend）: メディアクロックが止まる。再開すると、キーフレームから再開する
    client.audioListener.onStall?.();
    await settle();
    const stalled = await client.getStats();
    expect(stalled.clock?.stalled).toBe(true);
    const composedWhileStalled = stalled.composedFrames;
    loop.worker.scheduler.advance(500);
    await settle();
    expect((await client.getStats()).composedFrames).toBe(composedWhileStalled);

    client.audioListener.onResume?.();
    await settle();
    const videoBeforeResume = chunks.filter((chunk) => chunk.kind === "video").length;
    loop.feedAudioSeconds(0.3);
    await settle();
    const resumed = chunks.filter((chunk) => chunk.kind === "video").slice(videoBeforeResume);
    expect((await client.getStats()).clock?.stalled).toBe(false);
    expect(resumed.length).toBeGreaterThan(0);
    expect(resumed[0].keyframe).toBe(true);
    expect(faults).toEqual([]);
    client.terminate();
  });

  it("設定の再取得（getConfig）と、配信の終了（endSession）: 終了のあとは、プレビューだけの状態に戻り、エンコーダは閉じられる", async () => {
    const context = setup();
    const { loop, client, faults } = context;
    await client.start();
    await configureStream(context);

    const config = await client.getConfig();
    expect(Array.from(config.video?.description ?? [])).toEqual(Array.from(FAKE_AVCC_DESCRIPTION));
    expect(Array.from(config.audio?.description ?? [])).toEqual(Array.from(FAKE_AUDIO_SPECIFIC_CONFIG));

    await client.endSession();
    const stats = await client.getStats();

    expect(stats.mode).toBe("preview");
    expect(FakeVideoEncoder.instances[0].closeCalls).toBe(1);
    expect(FakeAudioEncoder.instances[0].closeCalls).toBe(1);
    expect(loop.audioPort?.closeCount).toBe(1);
    expect(stats.framesReceived).toBe(stats.framesClosed + stats.framesRetained);
    expect(faults).toEqual([]);
    client.terminate();
  });

  it("エンコーダの故障は、型付きの故障として、クライアントへ届く（符号と元のエラーの名前だけ）", async () => {
    const context = setup();
    const { loop, client, faults } = context;
    await client.start();
    await configureStream(context);
    client.beginDelivery();
    await settle();
    loop.feedAudioSeconds(0.2);
    await settle();

    FakeVideoEncoder.instances[0].fail(new DOMException("secret detail", "EncodingError"));
    await settle();

    expect(faults).toEqual([{ code: "video_encoder_error", detail: "EncodingError" }]);
    client.terminate();
  });
});

describe("終了と異常終了", () => {
  it("terminate: shutdown を送り、ワーカーを終了し、ワーカー自身も閉じる。待っていた要求は terminated で拒否される", async () => {
    const { loop, client } = setup();
    await client.start();
    const pending = client.getStats();
    const rejected = pending.then(
      () => "resolved",
      (error: unknown) => (error instanceof PipelineError ? error.code : "other"),
    );

    client.terminate();
    await settle();

    expect(await rejected).toBe("terminated");
    expect(loop.worker.commands("shutdown")).toHaveLength(1);
    expect(loop.worker.terminateCount).toBe(1);
    expect(loop.worker.closeCount).toBe(1);
    expect(() => client.requestKeyframe()).toThrow(PipelineError);
  });

  it("ワーカーの異常終了: worker_crashed の故障を 1 回だけ通知し、以後の操作は invalid_state", async () => {
    const { loop, client, faults } = setup();
    await client.start();

    loop.worker.crash();
    loop.worker.crash();

    expect(faults).toEqual([{ code: "worker_crashed", detail: null }]);
    expect(loop.worker.terminateCount).toBe(1);
    await expect(client.getStats()).rejects.toMatchObject({ code: "invalid_state" });
  });
});
