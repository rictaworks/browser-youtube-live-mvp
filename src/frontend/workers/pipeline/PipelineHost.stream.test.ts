/**
 * @jest-environment node
 */
// PipelineHost（配信中: 音声の処理周期が合成とエンコードを駆動する。requirements.md 11.4・11.6・11.7・12。issue #27）。
//   - 配信中は、#26 のミキサーが送る音声の処理周期（累積サンプル数）から MediaClock が決めるフレーム番号ごとに、1 枚を合成する（映像 1 フレーム = 音声 1,470 サンプル）。
//     ワーカーのタイマ・画面の描画周期には依存しない
//   - 音声が止まったとき合成も止まり、再開時はキーフレームから再開する（空白を埋めない）
//   - 設定（configure）: エンコーダの最初の出力（復号器設定）を得て返す。得られない（音声のクロックが動かない）なら priming_timeout
//   - 符号化結果は、送出の開始（begin_delivery）まで渡さない。開始・復帰では、映像はキーフレームから、音声はすぐ渡す
//   - 映像の時刻は videoTime(フレーム番号)、音声の時刻は audioTime(累積サンプル数)。実時計で採番しない
//   - プレビューは、符号化へ渡すものと、同じ合成の結果（同じキャンバス）
import { audioTimeUs, videoTimeUs } from "@/core/clock";
import { DECODER_CONFIG_TIMEOUT_MS, SLATE } from "@/lib/pipeline/config";
import { buildAudioEncoderConfig, buildVideoEncoderConfig } from "@/lib/pipeline/encoderConfig";
import type { EncodedChunk } from "@/lib/pipeline/chunks";
import { HostHarness, settle } from "./host-support";
import { FAKE_AUDIO_SPECIFIC_CONFIG, FAKE_AVCC_DESCRIPTION, FakeAudioEncoder, FakeVideoEncoder } from "./test-support";

const MAIN = "avc1.4D401F";
const BASELINE = "avc1.42E01F";

function chunksOf(harness: HostHarness, kind: "video" | "audio"): EncodedChunk[] {
  return harness.eventsOf("chunk").map((event) => event.chunk).filter((chunk) => chunk.kind === kind);
}

/** 設定して、送出を開始する（送出の開始の通知を受けた状態）。 */
async function streaming(harness: HostHarness, profile: "720p" | "480p" = "720p"): Promise<void> {
  const reply = await harness.configureAndPrime(profile, profile === "720p" ? MAIN : BASELINE, profile === "720p" ? 4500 : 1500);
  if (!reply.ok) {
    throw new Error(`configure failed: ${reply.fault.code}`);
  }
  harness.send({ type: "begin_delivery" });
}

async function statsOf(harness: HostHarness) {
  const reply = await harness.replyTo(harness.request("get_stats"));
  if (!reply.ok || reply.result.kind !== "stats") {
    throw new Error("no stats");
  }
  return reply.result.stats;
}

describe("音声の処理周期が合成を駆動する", () => {
  it("音声のポートを接続すると、プレビューのタイマを止める。タイマが進んでも合成しない（画面の描画周期・タイマに依存しない）", () => {
    const harness = new HostHarness();
    harness.attachPreview();
    expect(harness.scheduler.activeIntervalCount).toBe(1);

    harness.connectAudio();
    harness.scheduler.advance(5000);

    expect(harness.scheduler.activeIntervalCount).toBe(0);
    expect(harness.compositeCanvas.context.calls).toEqual([]);
  });

  it("映像 1 フレーム = 音声 1,470 サンプル: 128 サンプルのブロックなら 12 ブロック目で最初の 1 枚を合成する", async () => {
    const harness = new HostHarness();
    harness.attachPreview();
    harness.connectAudio();

    harness.feedBlocks(11);
    expect(harness.compositeCanvas.context.calls).toEqual([]);
    harness.feedBlocks(1);

    expect(harness.compositeCanvas.context.calls.map((call) => call.method)).toContain("fillRect");
    const stats = await statsOf(harness);
    expect(stats.composedFrames).toBe(1);
    expect(stats.clock).toEqual({ sampleCount: 1536, frameIndex: 1, stalled: false });
    expect(stats.mode).toBe("clock");
  });

  it("合成するフレームの数は、累積サンプル数 ÷ 1,470 の切り捨て（取りこぼしも重複も無い）", async () => {
    const harness = new HostHarness();
    harness.connectAudio();

    harness.feedSeconds(10);

    const stats = await statsOf(harness);
    expect(stats.composedFrames).toBe(Math.floor(harness.audioSamples / 1470));
    expect(stats.clock?.frameIndex).toBe(stats.composedFrames);
  });

  it("プレビューは、符号化へ渡すものと同じ合成の結果: 合成のたびに、同じキャンバスを 1:1 で写す", async () => {
    const harness = new HostHarness();
    const preview = harness.attachPreview();
    harness.connectAudio();

    harness.feedSeconds(1);

    const stats = await statsOf(harness);
    const draws = preview.context.calls.filter((call) => call.method === "drawImage");
    expect(draws).toHaveLength(stats.composedFrames);
    expect(draws.every((call) => call.args[0] === harness.compositeCanvas)).toBe(true);
  });

  it("音声のポートが接続済みのときの 2 回目の connect_audio は invalid_state の故障（最初のポートはそのまま）", () => {
    const harness = new HostHarness();
    const first = harness.connectAudio();

    harness.connectAudio();

    expect(harness.faultCodes()).toEqual(["invalid_state"]);
    expect(first.closeCount).toBe(0);
  });

  it("ブロックが連続していない（欠落・重複）: audio_continuity_lost の故障を 1 回だけ知らせ、以後のブロックは取り込まない（時刻の基準が崩れたまま続けない）", async () => {
    const harness = new HostHarness();
    const port = harness.connectAudio();
    harness.feedBlocks(3);

    port.receive({ type: "block", firstSample: 999, frames: 128, pcm: new Float32Array(256) });
    harness.feedBlocks(20);

    expect(harness.faultCodes()).toEqual(["audio_continuity_lost"]);
    const stats = await statsOf(harness);
    expect(stats.clock?.sampleCount).toBe(384);
  });

  it("ブロックの形が不正: invalid_message の故障（クロックを進めない）", async () => {
    const harness = new HostHarness();
    const port = harness.connectAudio();

    port.receive({ type: "block", firstSample: 0, frames: 128, pcm: new Float32Array(10) });
    port.receive("not a message");

    expect(harness.faultCodes()).toEqual(["invalid_message", "invalid_message"]);
    expect((await statsOf(harness)).clock?.sampleCount).toBe(0);
  });
});

describe("音声の停止と再開（端末の休止・音声出力の中断）", () => {
  it("停止中は合成しない。再開しても、空白を埋める合成をしない", async () => {
    const harness = new HostHarness();
    harness.connectAudio();
    harness.feedSeconds(0.5);
    const before = (await statsOf(harness)).composedFrames;

    harness.send({ type: "audio_stalled" });
    harness.feedSeconds(2);
    const during = await statsOf(harness);
    harness.send({ type: "audio_resumed" });
    harness.feedSeconds(0.2);
    const after = await statsOf(harness);

    expect(during.composedFrames).toBe(before);
    expect(during.clock?.stalled).toBe(true);
    expect(after.clock?.stalled).toBe(false);
    // 停止中に期限が来たフレームは、合成しない（埋め合わせない）。再開後の分だけが増える
    expect(after.composedFrames - before).toBeLessThanOrEqual(Math.ceil(0.2 * 30) + 1);
    expect(after.composedFrames - before).toBeGreaterThan(0);
  });

  it("再開後に最初に符号化するフレームは、キーフレーム", async () => {
    const harness = new HostHarness();
    await streaming(harness);
    harness.feedSeconds(0.5);
    const encoder = FakeVideoEncoder.instances[0];

    harness.send({ type: "audio_stalled" });
    harness.feedSeconds(1);
    const callsBefore = encoder.encodeCalls.length;
    harness.send({ type: "audio_resumed" });
    harness.feedSeconds(0.3);

    expect(encoder.encodeCalls.length).toBeGreaterThan(callsBefore);
    expect(encoder.encodeCalls[callsBefore].keyFrame).toBe(true);
    expect(encoder.encodeCalls[callsBefore + 1].keyFrame).toBe(false);
  });

  it("音声のポートが無いときの停止・再開の通知は、何も起こさない", () => {
    const harness = new HostHarness();

    harness.send({ type: "audio_stalled" });
    harness.send({ type: "audio_resumed" });

    expect(harness.events).toEqual([]);
  });
});

describe("configure（エンコーダの設定と、復号器設定の取得）", () => {
  it("音声のクロックが動いている間に設定すると、映像・音声の復号器設定を返す。設定は、標準（720p）・Main・固定ビットレート・低遅延・AVCC と、AAC-LC", async () => {
    const harness = new HostHarness();
    const camera = harness.addSource("camera");
    camera.controller.enqueue(camera.ledger.create(640, 480));
    await settle();

    const reply = await harness.configureAndPrime("720p", MAIN, 4500);

    expect(reply.ok).toBe(true);
    if (reply.ok && reply.result.kind === "configured") {
      expect(reply.result.video).toMatchObject({ kind: "video", codec: MAIN });
      expect(Array.from(reply.result.video.description)).toEqual(Array.from(FAKE_AVCC_DESCRIPTION));
      expect(reply.result.audio).toMatchObject({ kind: "audio", codec: "mp4a.40.2" });
      expect(Array.from(reply.result.audio.description)).toEqual(Array.from(FAKE_AUDIO_SPECIFIC_CONFIG));
    } else {
      throw new Error("expected a configured reply");
    }
    expect(FakeVideoEncoder.instances[0].configureCalls[0]).toEqual(buildVideoEncoderConfig("720p", MAIN, 4500));
    expect(FakeAudioEncoder.instances[0].configureCalls[0]).toEqual(buildAudioEncoderConfig());
  });

  it("軽量（480p）・Constrained Baseline: 合成の解像度が 854x480 になり、エンコーダも 854x480 で設定される", async () => {
    const harness = new HostHarness();

    const reply = await harness.configureAndPrime("480p", BASELINE, 1500);

    expect(reply.ok).toBe(true);
    expect(harness.compositeCanvas.width).toBe(854);
    expect(harness.compositeCanvas.height).toBe(480);
    expect(FakeVideoEncoder.instances[0].configureCalls[0]).toMatchObject({ codec: BASELINE, width: 854, height: 480, bitrate: 1_500_000 });
  });

  it("映像ソースが皆無（代替スレート）でも、符号化される（映像が途切れない）", async () => {
    const harness = new HostHarness();

    await harness.configureAndPrime();

    expect(FakeVideoEncoder.instances[0].encodeCalls.length).toBeGreaterThan(0);
    expect(harness.compositeCanvas.context.calls.some((call) => call.fillStyle === SLATE.backgroundColor)).toBe(true);
  });

  it("音声のクロックが動かない（ポートが無い）: 期限内に復号器設定を得られず priming_timeout。作ったエンコーダは閉じ、設定をやり直せる", async () => {
    const harness = new HostHarness();
    const requestId = harness.request("configure", { profile: "720p", videoCodec: MAIN, videoBitrateKbps: 4500 });
    await settle();

    harness.scheduler.advance(DECODER_CONFIG_TIMEOUT_MS + 1);
    const reply = await harness.replyTo(requestId);

    expect(reply.ok).toBe(false);
    if (!reply.ok) {
      expect(reply.fault.code).toBe("priming_timeout");
    }
    expect(FakeVideoEncoder.instances[0].closeCalls).toBe(1);
    expect(FakeAudioEncoder.instances[0].closeCalls).toBe(1);
    const retry = await harness.configureAndPrime();
    expect(retry.ok).toBe(true);
  });

  it("AAC が使えない環境（Linux の Chrome など）: audio_config_unsupported で失敗する。作った映像エンコーダは閉じる。別の形式へ黙って切り替えない", async () => {
    const harness = new HostHarness();
    FakeAudioEncoder.aacSupported = false;

    const reply = await harness.configureAndPrime();

    expect(reply.ok).toBe(false);
    if (!reply.ok) {
      expect(reply.fault.code).toBe("audio_config_unsupported");
    }
    expect(FakeVideoEncoder.instances[0].closeCalls).toBe(1);
    expect(FakeAudioEncoder.instances).toHaveLength(0);
  });

  it("H.264 の設定が使えない: video_config_unsupported で失敗する。音声のエンコーダは作らない", async () => {
    const harness = new HostHarness();
    FakeVideoEncoder.supportedCodecs = new Set();

    const reply = await harness.configureAndPrime();

    expect(reply.ok).toBe(false);
    if (!reply.ok) {
      expect(reply.fault.code).toBe("video_config_unsupported");
    }
    expect(FakeAudioEncoder.instances).toHaveLength(0);
  });

  it("プロファイルは配信の開始時に確定し、配信中に変更しない: 設定済みで別のプロファイルを設定すると profile_locked、同じなら invalid_state", async () => {
    const harness = new HostHarness();
    await harness.configureAndPrime("720p", MAIN, 4500);

    const different = await harness.replyTo(harness.request("configure", { profile: "480p", videoCodec: MAIN, videoBitrateKbps: 1500 }));
    const same = await harness.replyTo(harness.request("configure", { profile: "720p", videoCodec: MAIN, videoBitrateKbps: 4500 }));

    expect(different.ok === false && different.fault.code).toBe("profile_locked");
    expect(same.ok === false && same.fault.code).toBe("invalid_state");
    expect(FakeVideoEncoder.instances).toHaveLength(1);
  });

  it("範囲外のビットレート: bitrate_out_of_range で失敗する（エンコーダに触れない）", async () => {
    const harness = new HostHarness();
    harness.connectAudio();

    const reply = await harness.replyTo(harness.request("configure", { profile: "720p", videoCodec: MAIN, videoBitrateKbps: 9000 }));

    expect(reply.ok === false && reply.fault.code).toBe("bitrate_out_of_range");
    expect(FakeVideoEncoder.instances).toHaveLength(0);
  });

  it("設定の最中に end_session が来たら、設定は打ち切られ（terminated）、作ったエンコーダは閉じられる", async () => {
    const harness = new HostHarness();
    harness.connectAudio();
    const configureId = harness.request("configure", { profile: "720p", videoCodec: MAIN, videoBitrateKbps: 4500 });
    await settle();

    const endId = harness.request("end_session");
    const configureReply = await harness.replyTo(configureId);
    const endReply = await harness.replyTo(endId);

    expect(configureReply.ok === false && configureReply.fault.code).toBe("terminated");
    expect(endReply.ok).toBe(true);
    expect(FakeVideoEncoder.instances[0].closeCalls).toBe(1);
    expect(FakeAudioEncoder.instances[0].closeCalls).toBe(1);
  });
});

describe("符号化結果の受け渡し（ゲート）", () => {
  it("送出の開始（begin_delivery）の前は、符号化結果を渡さない（エンコーダは動かし続ける）", async () => {
    const harness = new HostHarness();
    await harness.configureAndPrime();

    harness.feedSeconds(1);

    expect(harness.eventsOf("chunk")).toEqual([]);
    const stats = await statsOf(harness);
    expect(stats.gateOpen).toBe(false);
    expect(stats.gate.closedDiscardedVideo).toBeGreaterThan(0);
    expect(stats.gate.closedDiscardedAudio).toBeGreaterThan(0);
    expect(stats.encodedVideoFrames).toBeGreaterThan(0);
  });

  it("begin_delivery: 音声はすぐ渡し、映像は最初のキーフレームから渡す（それ以前の差分フレームは渡さない）", async () => {
    const harness = new HostHarness();
    await harness.configureAndPrime();

    harness.send({ type: "begin_delivery" });
    harness.feedSeconds(1);

    const video = chunksOf(harness, "video");
    const audio = chunksOf(harness, "audio");
    expect(video.length).toBeGreaterThan(10);
    expect(video[0].keyframe).toBe(true);
    expect(audio.length).toBeGreaterThan(10);
    expect(audio.every((chunk) => chunk.keyframe === false)).toBe(true);
  });

  it("pause_delivery（再接続中）: 渡さない。再開（begin_delivery）では、映像はまたキーフレームから、音声はすぐ", async () => {
    const harness = new HostHarness();
    await streaming(harness);
    harness.feedSeconds(0.5);

    harness.send({ type: "pause_delivery" });
    const pausedAt = harness.eventsOf("chunk").length;
    harness.feedSeconds(1);
    expect(harness.eventsOf("chunk").length).toBe(pausedAt);

    harness.send({ type: "begin_delivery" });
    harness.feedSeconds(0.5);
    const resumed = harness.eventsOf("chunk").slice(pausedAt).map((event) => event.chunk);
    const resumedVideo = resumed.filter((chunk) => chunk.kind === "video");
    expect(resumedVideo[0].keyframe).toBe(true);
    expect(resumed.some((chunk) => chunk.kind === "audio")).toBe(true);
  });

  it("映像の時刻は videoTime(フレーム番号)（実時計でない）、音声の時刻は audioTime(累積サンプル数)。どちらも逆行しない", async () => {
    const harness = new HostHarness();
    await streaming(harness);
    harness.feedSeconds(2);

    const video = chunksOf(harness, "video");
    const audio = chunksOf(harness, "audio");

    expect(video.every((chunk) => Array.from({ length: 400 }, (_unused, index) => videoTimeUs(index)).includes(chunk.timestampUs))).toBe(true);
    expect(video.every((chunk, index) => index === 0 || chunk.timestampUs > video[index - 1].timestampUs)).toBe(true);
    // 音声: 符号化の起点（最初のブロックの累積サンプル数）から 1,024 サンプルごと。最初に渡したチャンクが、何番目かを、時刻から求める
    const first = audio[0].timestampUs;
    const offsetFromStart = Array.from({ length: 2000 }, (_unused, index) => index).find((index) => audioTimeUs(harness.primeStartSample + index * 1024) === first);
    expect(offsetFromStart).toBeDefined();
    const base = offsetFromStart ?? 0;
    audio.forEach((chunk, index) => {
      expect(chunk.timestampUs).toBe(audioTimeUs(harness.primeStartSample + (base + index) * 1024));
    });
  });

  it("キーフレームは 2 秒（60 フレーム）ごと: 渡した映像のキーフレームの時刻の間隔が、2,000,000 マイクロ秒", async () => {
    const harness = new HostHarness();
    await streaming(harness);
    harness.feedSeconds(7);

    const keys = chunksOf(harness, "video").filter((chunk) => chunk.keyframe).map((chunk) => chunk.timestampUs);

    expect(keys.length).toBeGreaterThanOrEqual(3);
    keys.slice(1).forEach((time, index) => {
      expect(time - keys[index]).toBe(2_000_000);
    });
  });

  it("符号化結果は、バイト列のまま渡す（AVCC のまま・生の AAC のまま。加工しない）", async () => {
    const harness = new HostHarness();
    await streaming(harness);
    harness.feedSeconds(0.5);

    const video = chunksOf(harness, "video")[0];
    const audio = chunksOf(harness, "audio")[0];

    expect(Array.from(video.data.slice(0, 4))).toEqual([0, 0, 0, video.byteLength - 4]);
    expect(Array.from(audio.data)).toEqual([0x21, 0x10, 0x04]);
  });

  it("送出の開始の通知は、設定の前なら not_configured の故障", () => {
    const harness = new HostHarness();

    harness.send({ type: "begin_delivery" });

    expect(harness.faultCodes()).toEqual(["not_configured"]);
  });
});

describe("適応制御の指示", () => {
  it("set_bitrate: 映像エンコーダを、新しいビットレートで再設定する。範囲外は bitrate_out_of_range の故障（再設定しない）", async () => {
    const harness = new HostHarness();
    await streaming(harness);
    const encoder = FakeVideoEncoder.instances[0];

    harness.send({ type: "set_bitrate", kbps: 3150 });
    harness.send({ type: "set_bitrate", kbps: 100 });

    expect(encoder.configureCalls).toHaveLength(2);
    expect(encoder.configureCalls[1]).toEqual(buildVideoEncoderConfig("720p", MAIN, 3150));
    expect(harness.faultCodes()).toEqual(["bitrate_out_of_range"]);
    expect((await statsOf(harness)).videoBitrateKbps).toBe(3150);
  });

  it("request_keyframe: 次に符号化するフレームがキーフレームになる（滞留 4 秒超・復帰時）", async () => {
    const harness = new HostHarness();
    await streaming(harness);
    harness.feedSeconds(0.5);
    const encoder = FakeVideoEncoder.instances[0];
    const before = encoder.encodeCalls.length;

    harness.send({ type: "request_keyframe" });
    harness.feedSeconds(0.2);

    expect(encoder.encodeCalls[before].keyFrame).toBe(true);
    expect(encoder.encodeCalls[before + 1].keyFrame).toBe(false);
  });

  it("設定の前の set_bitrate・request_keyframe は not_configured の故障", () => {
    const harness = new HostHarness();

    harness.send({ type: "set_bitrate", kbps: 3000 });
    harness.send({ type: "request_keyframe" });

    expect(harness.faultCodes()).toEqual(["not_configured", "not_configured"]);
  });
});

describe("復号器設定の再取得", () => {
  it("get_config: 設定の前は null、設定のあとは映像・音声の復号器設定（再接続のあとの再送に使う）、end_session のあとは null", async () => {
    const harness = new HostHarness();
    const none = await harness.replyTo(harness.request("get_config"));
    await harness.configureAndPrime();
    const present = await harness.replyTo(harness.request("get_config"));
    await harness.replyTo(harness.request("end_session"));
    const gone = await harness.replyTo(harness.request("get_config"));

    expect(none.ok && none.result.kind === "config" && none.result.video === null && none.result.audio === null).toBe(true);
    expect(present.ok && present.result.kind === "config" && present.result.video?.kind === "video" && present.result.audio?.kind === "audio").toBe(true);
    expect(gone.ok && gone.result.kind === "config" && gone.result.video === null && gone.result.audio === null).toBe(true);
  });

  it("再設定のあとにエンコーダが内容の違う復号器設定を返したら、decoder_config のイベントで知らせる（中継へ設定を再送するため）", async () => {
    const harness = new HostHarness();
    await streaming(harness);
    const changed = new Uint8Array(FAKE_AVCC_DESCRIPTION);
    changed[3] = 0x20;

    harness.send({ type: "set_bitrate", kbps: 3500 });
    FakeVideoEncoder.instances[0].description = changed;
    harness.feedSeconds(0.3);

    const events = harness.eventsOf("decoder_config");
    expect(events).toHaveLength(1);
    expect(events[0].config.description[3]).toBe(0x20);
  });
});

describe("エンコーダの故障（黙って止まらない）", () => {
  it("映像エンコーダのエラー: video_encoder_error の故障を知らせる。合成とプレビューは続き、音声は送り続ける", async () => {
    const harness = new HostHarness();
    const preview = harness.attachPreview();
    await streaming(harness);
    harness.feedSeconds(0.3);
    const previewDraws = preview.context.calls.length;
    const audioBefore = chunksOf(harness, "audio").length;

    FakeVideoEncoder.instances[0].fail(new DOMException("hardware failure", "EncodingError"));
    harness.feedSeconds(0.5);

    expect(harness.eventsOf("fault").map((event) => event.fault)).toEqual([{ code: "video_encoder_error", detail: "EncodingError" }]);
    expect(preview.context.calls.length).toBeGreaterThan(previewDraws);
    expect(chunksOf(harness, "audio").length).toBeGreaterThan(audioBefore);
    expect((await statsOf(harness)).videoFaulted).toBe(true);
  });

  it("音声エンコーダのエラー: audio_encoder_error の故障を知らせる。映像は続く", async () => {
    const harness = new HostHarness();
    await streaming(harness);
    harness.feedSeconds(0.3);
    const videoBefore = chunksOf(harness, "video").length;

    FakeAudioEncoder.instances[0].fail(new DOMException("device lost", "EncodingError"));
    harness.feedSeconds(0.5);

    expect(harness.faultCodes()).toEqual(["audio_encoder_error"]);
    expect(chunksOf(harness, "video").length).toBeGreaterThan(videoBefore);
    expect((await statsOf(harness)).audioFaulted).toBe(true);
  });

  it("合成の失敗は、そのフレームを符号化しない（描きかけを符号化しない）。故障を 1 回だけ知らせ、回復したら符号化が続く", async () => {
    const harness = new HostHarness();
    const camera = harness.addSource("camera");
    camera.controller.enqueue(camera.ledger.create(640, 480));
    await settle();
    await streaming(harness);
    harness.feedSeconds(0.3);
    const encoded = FakeVideoEncoder.instances[0].encodeCalls.length;

    harness.compositeCanvas.context.failOn = "drawImage";
    harness.feedSeconds(0.5);
    expect(FakeVideoEncoder.instances[0].encodeCalls.length).toBe(encoded);
    expect(harness.faultCodes()).toEqual(["compose_failed"]);

    harness.compositeCanvas.context.failOn = null;
    harness.feedSeconds(0.3);
    expect(FakeVideoEncoder.instances[0].encodeCalls.length).toBeGreaterThan(encoded);
  });

  it("入力待ちが 2 フレームを超えるときは、符号化せず捨て、数える（統計の droppedBeforeEncode）。捨てたフレームも閉じる", async () => {
    const harness = new HostHarness();
    await streaming(harness);
    FakeVideoEncoder.instances[0].encodeQueueSize = 3;

    harness.feedSeconds(0.5);

    const stats = await statsOf(harness);
    expect(stats.droppedBeforeEncode).toBeGreaterThan(0);
    expect(harness.videoFrames.created.every((frame) => frame.closeCount === 1)).toBe(true);
  });
});

describe("フレームの解放漏れが無い（配信中）", () => {
  it("カメラのフレームが 30 fps で届き続ける 3 秒間: 合成用に作った VideoFrame はすべて閉じられ、ソースのフレームは最新の 1 枚だけが残る", async () => {
    const harness = new HostHarness();
    const camera = harness.addSource("camera");
    await streaming(harness);

    for (let second = 0; second < 6; second += 1) {
      for (let index = 0; index < 15; index += 1) {
        camera.controller.enqueue(camera.ledger.create(640, 480));
      }
      await settle();
      harness.feedSeconds(0.5);
    }

    expect(harness.videoFrames.created.length).toBeGreaterThan(60);
    expect(harness.videoFrames.created.every((frame) => frame.closeCount === 1)).toBe(true);
    expect(camera.ledger.openCount).toBe(1);
    expect(camera.ledger.doubleClosedCount).toBe(0);
    const stats = await statsOf(harness);
    expect(stats.framesReceived).toBe(stats.framesClosed + stats.framesRetained);
    expect(stats.framesRetained).toBe(1);
  });

  it("符号化へ渡す VideoFrame は、合成が確定したキャンバスの写し（描画が終わったあとに作る）。プレビューと同じキャンバス", async () => {
    const harness = new HostHarness();
    const preview = harness.attachPreview();
    const camera = harness.addSource("camera");
    camera.controller.enqueue(camera.ledger.create(640, 480));
    await settle();
    await streaming(harness);
    harness.feedSeconds(0.5);

    const snapshot = harness.videoFrames.created[harness.videoFrames.created.length - 1];

    expect(snapshot.source).toBe(harness.compositeCanvas);
    expect(snapshot.drawCallsAtCreation).toBe(harness.compositeCanvas.context.calls.length);
    expect(preview.context.calls[preview.context.calls.length - 1].args[0]).toBe(harness.compositeCanvas);
    // 配信中は、タイマを使わない（音声の処理周期だけが駆動する）
    expect(harness.scheduler.activeIntervalCount).toBe(0);
  });
});

describe("end_session（配信の終了）", () => {
  it("エンコーダを閉じ、音声のポートを閉じ、送出を止める。プレビューのタイマが戻り、合成の解像度はプレビュー用に戻る", async () => {
    const harness = new HostHarness();
    harness.attachPreview();
    const port = harness.connectAudio();
    await harness.configureAndPrime("480p", BASELINE, 1500);
    harness.send({ type: "begin_delivery" });
    expect(harness.compositeCanvas.width).toBe(854);

    const reply = await harness.replyTo(harness.request("end_session"));

    expect(reply.ok).toBe(true);
    expect(FakeVideoEncoder.instances[0].closeCalls).toBe(1);
    expect(FakeAudioEncoder.instances[0].closeCalls).toBe(1);
    expect(port.closeCount).toBe(1);
    expect(harness.scheduler.activeIntervalCount).toBe(1);
    expect(harness.compositeCanvas.width).toBe(1280);
    const stats = await statsOf(harness);
    expect(stats.mode).toBe("preview");
    expect(stats.profile).toBeNull();
    expect(stats.gateOpen).toBe(false);
  });

  it("終了のあとに音声のブロックが届いても、取り込まない。新しい配信は、新しい音声のポートと設定でやり直せる", async () => {
    const harness = new HostHarness();
    const oldPort = harness.connectAudio();
    await harness.configureAndPrime();
    await harness.replyTo(harness.request("end_session"));
    const encodedBefore = FakeVideoEncoder.instances[0].encodeCalls.length;

    oldPort.receive({ type: "block", firstSample: 99_999, frames: 128, pcm: new Float32Array(256) });
    expect(FakeVideoEncoder.instances[0].encodeCalls.length).toBe(encodedBefore);

    harness.connectAudio();
    const again = await harness.configureAndPrime("720p", MAIN, 4500);
    expect(again.ok).toBe(true);
    expect(FakeVideoEncoder.instances).toHaveLength(2);
  });

  it("設定する前の end_session も、応答する（何も起こさない）", async () => {
    const harness = new HostHarness();

    const reply = await harness.replyTo(harness.request("end_session"));

    expect(reply.ok).toBe(true);
  });
});

