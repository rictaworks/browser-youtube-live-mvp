/**
 * @jest-environment node
 */
// PipelineHost（処理の遅れへの対処。requirements.md 11.6・12・27。issue #27）。
// 音声のブロックは、音声のスレッドから一定の間隔でワーカーへ届く。ワーカーが合成に時間を取られると、届いたブロックが待ちに積み上がり、あとで続けて処理される。
// 合成を毎回行うと、遅れを取り戻せず、待ちが増え続ける（停止などの制御メッセージも、待ちの後ろに回る）。そのため、待ちが積み上がっている間は、
// 合成を飛ばす（飛ばしても、映像のフレーム番号・時刻は、音声の累積サンプル数から決まるので、正しい。符号化の前に飛ばすので、参照の連鎖を壊さない）。
// 待ちの深さは、イベントの timeStamp（処理を始めた時刻）の進みと、音声の累積サンプル数の進みの差から推定する（LagGuard）。timeStamp が無ければ、遅れとしない。
//
// 試験の道具（HostHarness.feedBlocks）の timing:
//   steady  ブロックの周期どおりに処理される（待ちが一定）
//   burst   周期の 1/30 の間隔で続けて処理される（積み上がった分を、急いで処理している）。advanceEventClock(ms) は、その前の塞がり（処理が止まっていた時間）
import { BACKLOG_ENTER_MS, BACKLOG_EXIT_MS } from "@/lib/pipeline/config";
import { HostHarness } from "./host-support";
import { FakeVideoEncoder } from "./test-support";

const BLOCK_FRAMES = 128;
const PERIOD_MS = (BLOCK_FRAMES * 1000) / 44_100;
const BURST_STEP_MS = PERIOD_MS / 30;
const STALL_MS = 500;
/** 塞がりの直後の、待ちの深さ: 塞がり + 最初の塊のブロックの間隔 - ブロックの周期 */
const BACKLOG_AFTER_STALL_MS = STALL_MS + BURST_STEP_MS - PERIOD_MS;
/** 塊の 1 ブロックごとに、待ちは (周期 - 塊の間隔) だけ減る。EXIT を下回るまでの、塊のブロック数 */
const DRAIN_BLOCKS = Math.ceil((BACKLOG_AFTER_STALL_MS - BACKLOG_EXIT_MS) / (PERIOD_MS - BURST_STEP_MS));

/** ブロック番号 first から last（含む）までで、期限が来る映像のフレームの数（1,470 サンプルごとに 1 フレーム）。 */
function framesCompletedIn(first: number, last: number): number {
  return Math.floor(((last + 1) * BLOCK_FRAMES) / 1470) - Math.floor((first * BLOCK_FRAMES) / 1470);
}

async function statsOf(harness: HostHarness) {
  const reply = await harness.replyTo(harness.request("get_stats"));
  if (!reply.ok || reply.result.kind !== "stats") {
    throw new Error("no stats");
  }
  return reply.result.stats;
}

describe("遅れていないとき: 合成を飛ばさない", () => {
  it("周期どおりに届くブロック（timeStamp あり）: 期限が来たフレームを、すべて合成する。待ちの深さは 0", async () => {
    const harness = new HostHarness();
    harness.connectAudio();

    harness.feedBlocks(1000, BLOCK_FRAMES, "steady");

    const stats = await statsOf(harness);
    expect(stats.composedFrames).toBe(Math.floor(harness.audioSamples / 1470));
    expect(stats.skippedForLag).toBe(0);
    expect(stats.audioBacklogMs).toBe(0);
  });

  it("timeStamp が無いイベントは、遅れとしない: 続けて 1,000 個届いても、すべて合成する（継続側）", async () => {
    const harness = new HostHarness();
    harness.connectAudio();

    harness.feedBlocks(1000, BLOCK_FRAMES, "none");

    const stats = await statsOf(harness);
    expect(stats.composedFrames).toBe(Math.floor(harness.audioSamples / 1470));
    expect(stats.skippedForLag).toBe(0);
    expect(stats.audioBacklogMs).toBe(0);
  });

  it("映像 1 フレーム強の塞がり（40 ミリ秒）は、遅れとしない（ENTER 未満）", async () => {
    const harness = new HostHarness();
    harness.connectAudio();
    harness.feedBlocks(20, BLOCK_FRAMES, "steady");

    for (let round = 0; round < 10; round += 1) {
      harness.advanceEventClock(40);
      harness.feedBlocks(20, BLOCK_FRAMES, "burst");
      harness.feedBlocks(20, BLOCK_FRAMES, "steady");
    }

    const stats = await statsOf(harness);
    expect(BACKLOG_ENTER_MS).toBeGreaterThan(40);
    expect(stats.skippedForLag).toBe(0);
    expect(stats.composedFrames).toBe(Math.floor(harness.audioSamples / 1470));
  });
});

describe("遅れているとき: 待ちが解けるまで、合成を飛ばす", () => {
  it("500 ミリ秒の塞がりのあとの塊（344 ブロック）: 待ちが解ける（EXIT 未満）までの分を飛ばし、そのあとは合成する。フレーム番号は、音声の累積サンプル数のとおり", async () => {
    const harness = new HostHarness();
    harness.connectAudio();
    harness.feedBlocks(20, BLOCK_FRAMES, "steady");
    const before = await statsOf(harness);

    harness.advanceEventClock(STALL_MS);
    harness.feedBlocks(344, BLOCK_FRAMES, "burst");

    const stats = await statsOf(harness);
    const due = framesCompletedIn(20, 20 + 344 - 1);
    const expectedSkipped = framesCompletedIn(20, 20 + DRAIN_BLOCKS - 1);
    expect(stats.clock?.frameIndex).toBe(Math.floor(harness.audioSamples / 1470));
    expect(stats.clock?.frameIndex ?? 0).toBe((before.clock?.frameIndex ?? 0) + due);
    // 解ける境目のブロックの違い（基準の追従の分）で、1 フレームの違いは許す
    expect(Math.abs(stats.skippedForLag - expectedSkipped)).toBeLessThanOrEqual(1);
    expect(stats.composedFrames - before.composedFrames + stats.skippedForLag).toBe(due);
    expect(stats.skippedForLag).toBeGreaterThanOrEqual(13);
    expect(stats.composedFrames - before.composedFrames).toBeGreaterThanOrEqual(13);
    // 塊を処理し終えたので、待ちは解けている
    expect(stats.audioBacklogMs).toBeLessThan(BACKLOG_EXIT_MS);
  });

  it("塞がりの直後は、待ちの深さが統計に出る（塞がりの長さに近い）", async () => {
    const harness = new HostHarness();
    harness.connectAudio();
    harness.feedBlocks(20, BLOCK_FRAMES, "steady");

    harness.advanceEventClock(STALL_MS);
    harness.feedBlocks(5, BLOCK_FRAMES, "burst");

    const stats = await statsOf(harness);
    expect(stats.audioBacklogMs).toBeGreaterThan(BACKLOG_AFTER_STALL_MS - 20);
    expect(stats.audioBacklogMs).toBeLessThanOrEqual(Math.ceil(BACKLOG_AFTER_STALL_MS));
  });

  it("塊が終わり、周期どおりに届き始めたら、合成が再開し、飛ばした数は増えない", async () => {
    const harness = new HostHarness();
    harness.connectAudio();
    harness.feedBlocks(20, BLOCK_FRAMES, "steady");
    harness.advanceEventClock(STALL_MS);
    harness.feedBlocks(DRAIN_BLOCKS + 20, BLOCK_FRAMES, "burst");
    const during = await statsOf(harness);

    harness.feedBlocks(230, BLOCK_FRAMES, "steady");

    const after = await statsOf(harness);
    expect(after.composedFrames - during.composedFrames).toBe(framesCompletedIn(20 + DRAIN_BLOCKS + 20, 20 + DRAIN_BLOCKS + 20 + 230 - 1));
    expect(after.skippedForLag).toBe(during.skippedForLag);
  });

  it("遅れで飛ばしたフレームは、符号化しない（入力待ちの破棄とは別に数える）。VideoFrame も作らない", async () => {
    const harness = new HostHarness();
    harness.connectAudio();
    await harness.configureAndPrime();
    harness.send({ type: "begin_delivery" });
    harness.feedBlocks(40, BLOCK_FRAMES, "steady");
    const before = await statsOf(harness);
    const snapshotsBefore = harness.videoFrames.created.length;

    harness.advanceEventClock(STALL_MS);
    harness.feedBlocks(DRAIN_BLOCKS, BLOCK_FRAMES, "burst");

    const stats = await statsOf(harness);
    const composedInBurst = stats.composedFrames - before.composedFrames;
    expect(stats.skippedForLag).toBeGreaterThanOrEqual(13);
    expect(stats.droppedBeforeEncode).toBe(before.droppedBeforeEncode);
    // 合成して VideoFrame を作ったのは、飛ばさなかった分だけ（待ちが解ける境目の 1 フレーム程度）。飛ばした分は、作っていない
    expect(harness.videoFrames.created.length - snapshotsBefore).toBe(composedInBurst);
    expect(composedInBurst).toBeLessThanOrEqual(2);
    expect(harness.videoFrames.created.every((frame) => frame.closeCount === 1)).toBe(true);
    expect(harness.faultCodes()).toEqual([]);
  });

  it("飛ばした間も、音声は途切れなく符号化する（音声フレームは破棄しない）", async () => {
    const harness = new HostHarness();
    harness.connectAudio();
    await harness.configureAndPrime();
    harness.send({ type: "begin_delivery" });
    harness.feedBlocks(40, BLOCK_FRAMES, "steady");
    const audioBefore = harness.eventsOf("chunk").filter((event) => event.chunk.kind === "audio").length;
    const encodedSamplesBefore = harness.audioSamples - harness.primeStartSample;

    harness.advanceEventClock(STALL_MS);
    harness.feedBlocks(344, BLOCK_FRAMES, "burst");

    const audioAfter = harness.eventsOf("chunk").filter((event) => event.chunk.kind === "audio").length;
    const expected = Math.floor(((encodedSamplesBefore % 1024) + 344 * BLOCK_FRAMES) / 1024);
    expect(audioAfter - audioBefore).toBe(expected);
  });

  it("再開後の最初のフレームを飛ばしても、キーフレームの要求は残り、次に符号化するフレームがキーフレームになる", async () => {
    const harness = new HostHarness();
    harness.connectAudio();
    await harness.configureAndPrime();
    harness.send({ type: "begin_delivery" });
    harness.feedBlocks(60, BLOCK_FRAMES, "steady");
    const encoder = FakeVideoEncoder.instances[0];

    harness.send({ type: "audio_stalled" });
    harness.feedBlocks(100, BLOCK_FRAMES, "steady");
    // 再開のあとの最初のフレームが、塊の中で完成するように、停止の間の音声を、フレームの境目の直後まで進める
    while (harness.audioSamples % 1470 >= BLOCK_FRAMES) {
      harness.feedBlocks(1, BLOCK_FRAMES, "steady");
    }
    harness.send({ type: "audio_resumed" });
    // 再開の直後のブロックは、新しい基準（フレームは、まだ完成しない）。そのあと塞がりがあり、最初のフレームが完成するブロックは、塊の中（遅れている）
    harness.feedBlocks(3, BLOCK_FRAMES, "steady");
    const encodedBeforeBurst = encoder.encodeCalls.length;
    harness.advanceEventClock(STALL_MS);
    harness.feedBlocks(14, BLOCK_FRAMES, "burst");

    // 遅れているので、再開のあとの最初のフレームは、飛ばした（符号化していない）
    expect(encoder.encodeCalls.length).toBe(encodedBeforeBurst);

    // 待ちが解けるまで、塊を処理し、そのあと周期どおりに処理する
    harness.feedBlocks(DRAIN_BLOCKS, BLOCK_FRAMES, "burst");
    harness.feedBlocks(40, BLOCK_FRAMES, "steady");

    expect(encoder.encodeCalls.length).toBeGreaterThan(encodedBeforeBurst + 1);
    expect(encoder.encodeCalls[encodedBeforeBurst].keyFrame).toBe(true);
    expect(encoder.encodeCalls[encodedBeforeBurst + 1].keyFrame).toBe(false);
  });
});

describe("基準のやり直し", () => {
  it("音声の停止と再開で、遅れの状態を忘れる: 停止の間に実時間だけが進んでも、再開の直後を遅れとしない", async () => {
    const harness = new HostHarness();
    harness.connectAudio();
    harness.feedBlocks(20, BLOCK_FRAMES, "steady");
    harness.advanceEventClock(STALL_MS);
    harness.feedBlocks(10, BLOCK_FRAMES, "burst");
    expect((await statsOf(harness)).audioBacklogMs).toBeGreaterThan(400);

    harness.send({ type: "audio_stalled" });
    harness.advanceEventClock(5000);
    harness.send({ type: "audio_resumed" });
    const skippedBefore = (await statsOf(harness)).skippedForLag;
    harness.feedBlocks(60, BLOCK_FRAMES, "steady");

    const stats = await statsOf(harness);
    expect(stats.audioBacklogMs).toBe(0);
    expect(stats.skippedForLag).toBe(skippedBefore);
  });

  it("end_session のあと、新しい音声のポートの最初からは、遅れとしない: 待ちの状態を引き継がない", async () => {
    const harness = new HostHarness();
    harness.connectAudio();
    harness.feedBlocks(20, BLOCK_FRAMES, "steady");
    harness.advanceEventClock(STALL_MS);
    harness.feedBlocks(100, BLOCK_FRAMES, "burst");
    await harness.replyTo(harness.request("end_session"));
    const skippedBefore = (await statsOf(harness)).skippedForLag;

    harness.connectAudio();
    harness.feedBlocks(1, BLOCK_FRAMES, "burst");
    harness.feedBlocks(12, BLOCK_FRAMES, "steady");

    const stats = await statsOf(harness);
    expect(stats.skippedForLag).toBe(skippedBefore);
    expect(stats.audioBacklogMs).toBe(0);
    expect(stats.composedFrames).toBeGreaterThanOrEqual(1);
  });
});
