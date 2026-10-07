// AudioClockDriver（requirements.md 11.6。issue #26）。音声の処理周期（Worklet のブロック）が、メディアクロック（core の MediaClock）と、
// 合成の駆動源になる。
//   - ブロックのたびに MediaClock.onAudioTick(サンプル数) を呼び、期限が来たフレームの番号の区間を、合成（呼び出し側）へ渡す
//   - ブロックの累積サンプル数が、クロックの累積と食い違ったら（欠落・重複・順序の入れ替わり）、続けず、型付きのエラー（AudioContinuityError）
//   - AudioContext の停止は onAudioStall、再開は onAudioResume（空白を埋めず、再開後の最初のフレームをキーフレームにする。#24）
//   - 時刻の採番に、実時計（Date・performance）を使わない（累積サンプル数のみ）
import { MediaClock } from "@/core/clock";
import { FakeTrack } from "@/lib/sources/test-support";
import { AudioClockDriver } from "./AudioClockDriver";
import type { AudioTick } from "./AudioClockDriver";
import { AudioMixer } from "./AudioMixer";
import { AudioContinuityError } from "./errors";
import { FakeAudioEnvironment } from "./test-support";
import type { MixedAudioBlock } from "./workletProtocol";

function blockAt(firstSample: number, frames = 128): MixedAudioBlock {
  return { firstSample, frames, pcm: new Float32Array(frames * 2) };
}

function createDriver(): { clock: MediaClock; driver: AudioClockDriver; ticks: AudioTick[] } {
  const clock = new MediaClock();
  const ticks: AudioTick[] = [];
  return { clock, driver: new AudioClockDriver(clock, (tick) => ticks.push(tick)), ticks };
}

/** 連続したブロックを、count 個、流し込む。 */
function feed(driver: AudioClockDriver, from: number, count: number, frames = 128): number {
  let next = from;
  for (let index = 0; index < count; index += 1) {
    driver.onBlock(blockAt(next, frames));
    next += frames;
  }
  return next;
}

describe("ブロックでメディアクロックを進める", () => {
  it("ブロックのサンプル数だけ、累積サンプル数が進む。映像 1 フレームは音声 1,470 サンプル（128 サンプルのブロックなら、12 ブロック目で最初のフレーム）", () => {
    const { clock, driver, ticks } = createDriver();

    feed(driver, 0, 11);
    expect(ticks.map((tick) => tick.range.frameCount)).toEqual(new Array<number>(11).fill(0));
    feed(driver, 11 * 128, 1);

    expect(clock.sampleCount).toBe(1536);
    expect(ticks[11].range).toEqual({ firstFrameIndex: 0, frameCount: 1, skippedFrameCount: 0, keyframeRequired: false });
    expect(clock.frameIndex).toBe(1);
  });

  it("合成へ、ブロックと、期限が来たフレームの区間を渡す（呼び出しの順に）", () => {
    const { driver, ticks } = createDriver();
    const first = blockAt(0);

    driver.onBlock(first);

    expect(ticks).toHaveLength(1);
    expect(ticks[0].block).toBe(first);
    expect(ticks[0].range.frameCount).toBe(0);
  });

  it("1 時間分（128 サンプルずつ）を流しても、累積が厳密で、フレームは取りこぼしも重複も無い（30 fps × 3,600 秒 = 108,000）", () => {
    const clock = new MediaClock();
    let frames = 0;
    const driver = new AudioClockDriver(clock, (tick) => {
      frames += tick.range.frameCount;
    });
    const total = 44_100 * 3600;
    const pcm = new Float32Array(256);
    let next = 0;

    while (next + 128 <= total) {
      driver.onBlock({ firstSample: next, frames: 128, pcm });
      next += 128;
    }
    driver.onBlock({ firstSample: next, frames: total - next, pcm: new Float32Array((total - next) * 2) });

    expect(clock.sampleCount).toBe(total);
    expect(frames).toBe(108_000);
    expect(clock.frameIndex).toBe(108_000);
    expect(clock.audioTime(clock.sampleCount)).toBe(3_600_000_000);
  });

  it("実時計（Date.now・performance.now）を使わない（使うと例外になる状態で、流し込む）", () => {
    const dateNow = jest.spyOn(Date, "now").mockImplementation(() => {
      throw new Error("Date.now must not be used");
    });
    const performanceNow = jest.spyOn(performance, "now").mockImplementation(() => {
      throw new Error("performance.now must not be used");
    });
    try {
      const { clock, driver } = createDriver();

      feed(driver, 0, 50);

      expect(clock.sampleCount).toBe(6400);
    } finally {
      dateNow.mockRestore();
      performanceNow.mockRestore();
    }
  });
});

describe("連続性（ブロックの累積サンプル数が、クロックの累積と一致しない）", () => {
  it.each([
    ["欠落（1 ブロック飛ばす）", 1, 256],
    ["重複（同じブロックをもう一度）", 1, 0],
    ["順序の入れ替わり（先のブロックが先に来る）", 1, 512],
    ["先頭が 0 でない", 0, 128],
  ])("%s は、AudioContinuityError。クロックも、合成への通知も、変えない", (_name, blocksBefore, firstSample) => {
    const { clock, driver, ticks } = createDriver();
    feed(driver, 0, blocksBefore);
    const countBefore = ticks.length;
    const sampleCountBefore = clock.sampleCount;

    let thrown: unknown;
    try {
      driver.onBlock(blockAt(firstSample));
    } catch (error) {
      thrown = error;
    }

    expect(thrown).toBeInstanceOf(AudioContinuityError);
    expect((thrown as AudioContinuityError).expectedSample).toBe(sampleCountBefore);
    expect((thrown as AudioContinuityError).actualSample).toBe(firstSample);
    expect(clock.sampleCount).toBe(sampleCountBefore);
    expect(ticks).toHaveLength(countBefore);
  });
});

describe("停止と再開（端末の休止・音声出力の中断。空白を埋めず、キーフレームから再開する）", () => {
  it("停止中に届いたブロックは、サンプルを数えるが、フレームは合成しない（skippedFrameCount）。再開のあとの最初のフレームがキーフレーム", () => {
    const { clock, driver, ticks } = createDriver();
    const resumedAt = feed(driver, 0, 6); // 768 サンプル

    driver.onStall();
    expect(clock.isStalled).toBe(true);
    const stalledEnd = feed(driver, resumedAt, 6); // 1,536 サンプル（フレーム 0 の期限が、停止中に来る）
    driver.onResume();
    expect(clock.isStalled).toBe(false);
    expect(clock.needsKeyframe).toBe(true);
    feed(driver, stalledEnd, 12);

    const stalledTicks = ticks.slice(6, 12);
    expect(stalledTicks.every((tick) => tick.range.frameCount === 0)).toBe(true);
    expect(stalledTicks.reduce((sum, tick) => sum + tick.range.skippedFrameCount, 0)).toBe(1);
    const keyframes = ticks.filter((tick) => tick.range.keyframeRequired);
    expect(keyframes).toHaveLength(1);
    expect(keyframes[0].range.frameCount).toBeGreaterThan(0);
    expect(clock.sampleCount).toBe(24 * 128);
  });

  it("停止・再開をまたいでも、Worklet の累積サンプル数は連続している（再開後の最初のブロックが、直前の続き）", () => {
    const { driver } = createDriver();
    const next = feed(driver, 0, 5);

    driver.onStall();
    driver.onResume();

    expect(() => driver.onBlock(blockAt(next))).not.toThrow();
  });

  it("停止していないときの再開は、何も起こさない（キーフレームを要求しない）", () => {
    const { clock, driver } = createDriver();

    driver.onResume();

    expect(clock.needsKeyframe).toBe(false);
  });
});

describe("AudioMixer の購読者として使う（メインスレッドで、メディアクロックを駆動する）", () => {
  it("混合器のブロックがクロックを進め、AudioContext の停止・再開がクロックの停止・再開になる", async () => {
    const env = new FakeAudioEnvironment();
    const errors: unknown[] = [];
    const mixer = new AudioMixer({ environment: env.asEnvironment(), onListenerError: (error) => errors.push(error) });
    const { clock, driver, ticks } = createDriver();
    mixer.subscribe(driver);
    mixer.addSource("microphone", new FakeTrack("audio").asTrack());
    await mixer.start();

    for (let index = 0; index < 12; index += 1) {
      env.node.port.receive({ type: "block", firstSample: index * 128, frames: 128, pcm: new Float32Array(256) });
    }
    expect(clock.sampleCount).toBe(1536);
    expect(ticks[11].range.frameCount).toBe(1);

    env.context.setState("suspended");
    expect(clock.isStalled).toBe(true);
    env.context.setState("running");
    expect(clock.isStalled).toBe(false);
    expect(clock.needsKeyframe).toBe(true);
    expect(errors).toEqual([]);
  });

  it("連続性が崩れたとき、購読者の例外として、混合器の例外の処理へ渡る（混合器は、止まらない）", async () => {
    const env = new FakeAudioEnvironment();
    const errors: unknown[] = [];
    const mixer = new AudioMixer({ environment: env.asEnvironment(), onListenerError: (error) => errors.push(error) });
    const { driver } = createDriver();
    mixer.subscribe(driver);
    await mixer.start();

    env.node.port.receive({ type: "block", firstSample: 0, frames: 128, pcm: new Float32Array(256) });
    env.node.port.receive({ type: "block", firstSample: 999, frames: 128, pcm: new Float32Array(256) });

    expect(errors).toHaveLength(1);
    expect(errors[0]).toBeInstanceOf(AudioContinuityError);
    expect(mixer.status).toBe("running");
  });
});
