/**
 * @jest-environment node
 */
// 結合：メディアクロック（#24）の時刻 -> SendQueue -> FrameCodec（送信）-> 中継側の復号（Go の Decode に当たる decodeRawFrame）。
// さらに、BitrateGovernor の出来事 -> ReportBuilder -> FrameCodec（report）-> 中継側の復号。送信の経路を、型の境界をまたいで通す。
//   - 映像・音声の時刻は、MediaClock の関数（フレーム番号・累積サンプル数から、毎回、算出）。Number のまま、キューへ、符号化へ渡せる
//   - 中継（TimeGuard）が破棄する、同じ種別での時刻の逆行が、送信の列に無い
//   - 状態報告は、1 秒ごとに、ワイヤとして正しい本文になり、出来事は、欠落なく・重複なく届く
import { audioTimeUs, videoTimeUs } from "../clock";
import { BitrateGovernor } from "../governor";
import { SendQueue } from "../queue";
import type { ChunkMeta } from "../queue";
import { ReportBuilder } from "../report";
import { FrameCodec } from "./FrameCodec";
import { decodeRawFrame } from "./frameLayout";
import { parseReportBody } from "./bodies";

interface MediaChunk extends ChunkMeta {
  readonly data: Uint8Array;
}

const SAMPLES_PER_VIDEO_FRAME = 1470;
const AAC_SAMPLES = 1024;
const SECONDS = 12;

describe("送信の経路（メディアクロック -> SendQueue -> FrameCodec -> 中継側の復号）", () => {
  const codec = new FrameCodec();
  const queue = new SendQueue<MediaChunk>();
  const sent: Array<{ kind: "video" | "audio"; keyframe: boolean; timestampUs: bigint; bytes: number }> = [];
  const videoFrames = SECONDS * 30;

  // 音声の累積サンプル数が進むのに合わせて、映像（1,470 サンプルごとに 1 フレーム）と音声（1,024 サンプルごとに 1 チャンク）を作る
  let nextVideoFrame = 0;
  let nextAudioChunk = 0;
  while (nextVideoFrame < videoFrames) {
    const videoDue = nextVideoFrame * SAMPLES_PER_VIDEO_FRAME;
    const audioDue = nextAudioChunk * AAC_SAMPLES;
    if (videoDue <= audioDue) {
      queue.enqueue({ kind: "video", keyframe: nextVideoFrame % 60 === 0, timestampUs: videoTimeUs(nextVideoFrame), byteLength: 100 + (nextVideoFrame % 7), data: Uint8Array.from([0, 0, 0, 2, 0x65, nextVideoFrame & 255]) });
      nextVideoFrame += 1;
    } else {
      queue.enqueue({ kind: "audio", keyframe: false, timestampUs: audioTimeUs(audioDue), byteLength: 4, data: Uint8Array.from([0x21, 0x10, 0x04, nextAudioChunk & 255]) });
      nextAudioChunk += 1;
    }
    for (let chunk = queue.dequeue(); chunk !== undefined; chunk = queue.dequeue()) {
      const frame = codec.encode(chunk.kind === "video" ? { type: "video", timestampUs: chunk.timestampUs, keyframe: chunk.keyframe, payload: chunk.data } : { type: "audio", timestampUs: chunk.timestampUs, payload: chunk.data });
      const raw = decodeRawFrame(frame, "browser_to_relay");
      sent.push({ kind: raw.type === "video" ? "video" : "audio", keyframe: raw.keyframe, timestampUs: raw.timestampUs, bytes: raw.body.length });
    }
  }

  test("映像 360 フレーム・音声のチャンクが、すべて、符号化でき、中継側の復号で、元の時刻・キーフレーム・本文の長さに戻る", () => {
    const video = sent.filter((frame) => frame.kind === "video");
    expect(video).toHaveLength(videoFrames);
    expect(video[0]).toMatchObject({ keyframe: true, timestampUs: BigInt(0), bytes: 6 });
    expect(video[1].timestampUs).toBe(BigInt(33_333));
    expect(video[2].timestampUs).toBe(BigInt(66_667));
    expect(video[30].timestampUs).toBe(BigInt(1_000_000));
    expect(video.filter((frame) => frame.keyframe)).toHaveLength(videoFrames / 60);
    expect(video[60]).toMatchObject({ keyframe: true, timestampUs: BigInt(2_000_000) });
    const audio = sent.filter((frame) => frame.kind === "audio");
    expect(audio[1].timestampUs).toBe(BigInt(23_220));
    expect(audio.every((frame) => !frame.keyframe)).toBe(true);
  });

  test("同じ種別の時刻は、逆行しない（中継の TimeGuard が破棄するものが、無い）。映像と音声が、時刻の順に交互に並ぶ", () => {
    for (const kind of ["video", "audio"] as const) {
      const times = sent.filter((frame) => frame.kind === kind).map((frame) => frame.timestampUs);
      for (let index = 1; index < times.length; index += 1) {
        expect(times[index] >= times[index - 1]).toBe(true);
      }
    }
    const kinds = sent.slice(0, 12).map((frame) => frame.kind);
    expect(kinds).toContain("video");
    expect(kinds).toContain("audio");
  });
});

describe("状態報告の経路（BitrateGovernor -> ReportBuilder -> FrameCodec -> 中継側の復号）", () => {
  test("毎秒、評価して、報告を作り、符号化して、復号した本文が、組み立てた本文と同じ。出来事は、欠落なく・重複なく届く", () => {
    const governor = new BitrateGovernor();
    const builder = new ReportBuilder();
    const codec = new FrameCodec();
    let target = 4500;
    let degraded = false;
    const emitted: string[] = [];
    const delivered: string[] = [];

    for (let second = 0; second < 70; second += 1) {
      // 滞留時間：0 から 20 秒は健全、20 から 50 秒は逼迫（2 秒。下限で 20 秒続くと、劣化）、50 秒以降は健全（10 秒続くと、劣化を解除）
      const backlogMs = second >= 20 && second < 50 ? 2000 : 100;
      const decision = governor.evaluate({
        nowSec: second,
        backlogMs,
        dropTimesSec: [],
        targetKbps: target,
        minKbps: 3000,
        maxKbps: 6000,
        ackedVideoUs: (second + 1) * 1_000_000,
        degraded,
      });
      target = decision.targetKbps;
      degraded = decision.degraded;
      for (const event of decision.events) {
        builder.record(event);
        emitted.push(event.kind);
      }
      const report = builder.prepare({ backlogMs, droppedVideoFrames: 0, targetKbps: target, state: degraded ? "degraded" : "live" });
      const frame = codec.encode({ type: "report", body: report.body });
      const raw = decodeRawFrame(frame, "browser_to_relay");
      expect(raw.type).toBe("report");
      const decoded = parseReportBody(JSON.parse(new TextDecoder().decode(raw.body)));
      expect(decoded).toEqual(report.body);
      for (const event of decoded.events) {
        delivered.push(event.kind);
      }
      builder.commit(report);
    }
    expect(emitted.length).toBeGreaterThan(5);
    expect(delivered).toEqual(emitted);
    expect(delivered).toEqual(expect.arrayContaining(["bitrate_up", "bitrate_down", "degraded_started", "degraded_cleared"]));
  });
});
