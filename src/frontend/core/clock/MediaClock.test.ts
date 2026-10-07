/**
 * @jest-environment node
 */
// メディアクロック（requirements.md 11.6）。音声の累積サンプル数が基準で、実時計を使わない。
// 時刻は累積値から毎回算出し（差分を積み上げない）、BigInt を使わずに Number の安全整数の範囲で厳密に計算する。
//
// 大量の点を検査するループは、点ごとに expect を呼ばず、食い違いを集めて最後に 1 回だけ検査する
// （Jest の実行環境では、組み込みの関数の呼び出しと expect が遅く、点ごとの expect は数十倍かかるため）。
import { LIMITS } from "../contract";
import { Problems, seededRandom } from "../testing/helpers";
import { MediaClock, audioTimeUs, videoTimeUs } from "./MediaClock";
import type { FrameRange } from "./MediaClock";

const SAMPLE_RATE = 44_100;
const SAMPLES_PER_FRAME = 1_470;
const TEN_HOURS_SAMPLES = SAMPLE_RATE * 36_000; // 1,587,600,000
const TEN_HOURS_FRAMES = 30 * 36_000; // 1,080,000

/**
 * 独立した基準値。1 秒 = 1,000,000 マイクロ秒 = 44,100 サンプルを約分すると、1 サンプル = 10,000 / 441 マイクロ秒。
 * 分母 441 の分数のまま、(2 × 分子 + 441) ÷ 882 を切り捨てて四捨五入する（実装とは別の分解）。
 * 2 × n × 10,000 が 2^53 未満である n < 4.5 × 10^11（約 116 日分）で厳密。
 */
function referenceAudioTimeUs(samples: number): number {
  return Math.floor((2 * samples * 10_000 + 441) / 882);
}

/** 映像も同様。1 フレーム = 1,000,000 / 30 = 100,000 / 3 マイクロ秒。(2 × 分子 + 3) ÷ 6 の切り捨て。 */
function referenceVideoTimeUs(frameIndex: number): number {
  return Math.floor((2 * frameIndex * 100_000 + 3) / 6);
}

function framesOf(range: FrameRange): number[] {
  return Array.from({ length: range.frameCount }, (_, offset) => range.firstFrameIndex + offset);
}

describe("契約との対応（音声と映像の関係）", () => {
  test("映像 1 フレーム = 音声 1,470 サンプル、44,100 Hz、30 fps（両プロファイルとも）", () => {
    expect(LIMITS.audio.sample_rate_hz).toBe(SAMPLE_RATE);
    expect(LIMITS.audio.samples_per_video_frame).toBe(SAMPLES_PER_FRAME);
    expect(LIMITS.audio.sample_rate_hz / LIMITS.audio.samples_per_video_frame).toBe(30);
    expect(LIMITS.profiles["720p"].framerate).toBe(30);
    expect(LIMITS.profiles["480p"].framerate).toBe(30);
  });
});

describe("videoTimeUs: round(フレーム番号 × 1,000,000 ÷ 30)", () => {
  test.each([
    [0, 0],
    [1, 33_333],
    [2, 66_667],
    [3, 100_000],
    [29, 966_667],
    [30, 1_000_000],
    [31, 1_033_333],
    [60, 2_000_000],
    [TEN_HOURS_FRAMES, 36_000_000_000],
  ])("フレーム %i -> %i マイクロ秒", (frameIndex, expected) => {
    expect(videoTimeUs(frameIndex)).toBe(expected);
  });

  test("独立した基準値と一致し、ちょうど 1 秒（30 フレーム）ごとに 1,000,000 マイクロ秒進む（疑似乱数 5,000 点・10 時間の範囲）", () => {
    const random = seededRandom(20_261_007);
    const problems = new Problems();
    for (let i = 0; i < 5_000; i += 1) {
      const frameIndex = Math.floor(random() * TEN_HOURS_FRAMES);
      if (videoTimeUs(frameIndex) !== referenceVideoTimeUs(frameIndex)) {
        problems.report(`frame ${frameIndex}: ${videoTimeUs(frameIndex)} vs ${referenceVideoTimeUs(frameIndex)}`);
      }
      if (videoTimeUs(frameIndex + 30) - videoTimeUs(frameIndex) !== 1_000_000) {
        problems.report(`frame ${frameIndex}: one second does not add 1,000,000 microseconds`);
      }
    }
    expect(problems.list()).toEqual([]);
  });
});

describe("audioTimeUs: round(累積サンプル数 × 1,000,000 ÷ 44,100)", () => {
  test.each([
    [0, 0],
    [1, 23],
    [2, 45],
    [128, 2_902],
    [1_024, 23_220],
    [1_470, 33_333],
    [44_100, 1_000_000],
    [441_000, 10_000_000],
    [SAMPLE_RATE * 3_600, 3_600_000_000],
    [TEN_HOURS_SAMPLES, 36_000_000_000],
  ])("%i サンプル -> %i マイクロ秒（ws-protocol.md 6 章の例を含む）", (samples, expected) => {
    expect(audioTimeUs(samples)).toBe(expected);
  });

  test("1,470 サンプルの倍数の時刻は、同じ番号の映像フレームの時刻と同じ値になる（音声が映像のクロックを駆動する）", () => {
    const problems = new Problems();
    for (let frameIndex = 0; frameIndex < 3_000; frameIndex += 1) {
      if (audioTimeUs(frameIndex * SAMPLES_PER_FRAME) !== videoTimeUs(frameIndex)) {
        problems.report(`frame ${frameIndex}`);
      }
    }
    expect(problems.list()).toEqual([]);
  });

  test("独立した基準値（分母 441 の分数）と一致し、ちょうど 1 秒（44,100 サンプル）ごとに 1,000,000 マイクロ秒進み、真の値との差が 0.5 マイクロ秒以内（疑似乱数 5,000 点・10 時間の範囲）", () => {
    const random = seededRandom(7);
    const problems = new Problems();
    for (let i = 0; i < 5_000; i += 1) {
      const samples = Math.floor(random() * TEN_HOURS_SAMPLES);
      const actual = audioTimeUs(samples);
      if (actual !== referenceAudioTimeUs(samples)) {
        problems.report(`samples ${samples}: ${actual} vs ${referenceAudioTimeUs(samples)}`);
      }
      if (audioTimeUs(samples + SAMPLE_RATE) - actual !== 1_000_000) {
        problems.report(`samples ${samples}: one second does not add 1,000,000 microseconds`);
      }
      // 真の値 = samples × 10,000 / 441。差は 441 倍した整数で比べる（浮動小数点を介さない）。0.5 マイクロ秒 = 220.5 / 441
      if (Math.abs(actual * 441 - samples * 10_000) > 220) {
        problems.report(`samples ${samples}: deviates from the exact value by more than 0.5 microseconds`);
      }
    }
    expect(problems.list()).toEqual([]);
  });

  test("狭義単調増加（1 サンプル進めば必ず時刻が進む。逆行しない）。10 時間の直前の 2 秒分を全点で検査", () => {
    const start = TEN_HOURS_SAMPLES - SAMPLE_RATE;
    const problems = new Problems();
    let previous = audioTimeUs(start);
    for (let samples = start + 1; samples <= start + 2 * SAMPLE_RATE; samples += 1) {
      const current = audioTimeUs(samples);
      if (current <= previous) {
        problems.report(`not strictly increasing at ${samples}: ${previous} -> ${current}`);
      }
      previous = current;
    }
    expect(problems.list()).toEqual([]);
  });

  test("巨大な入力でも厳密（期待値は任意精度の整数で別に計算した値）。入力が 10^14 を超えても、計算の順序で桁が落ちない", () => {
    expect(audioTimeUs(395_999_999_967_600)).toBe(8_979_591_836_000_000); // ちょうど 8,979,591,836 秒
    expect(audioTimeUs(395_999_999_967_601)).toBe(8_979_591_836_000_023);
    expect(audioTimeUs(397_000_000_000_000)).toBe(9_002_267_573_696_145);
  });

  test("安全整数の境界：結果が 2^53 - 1 に収まる最大の入力まで厳密で、1 つ超えると丸めた値を返さず RangeError", () => {
    expect(audioTimeUs(397_217_487_134_077)).toBe(9_007_199_254_740_975);
    expect(() => audioTimeUs(397_217_487_134_078)).toThrow(RangeError); // 結果は 9,007,199,254,740,998（> 2^53 - 1）
    expect(() => audioTimeUs(400_000_000_000_000)).toThrow(RangeError);
    expect(() => audioTimeUs(Number.MAX_SAFE_INTEGER)).toThrow(RangeError);
  });

  test.each([
    ["負の数", -1],
    ["小数", 1.5],
    ["NaN", Number.NaN],
    ["無限大", Number.POSITIVE_INFINITY],
    ["安全整数を超える値", Number.MAX_SAFE_INTEGER + 2],
  ])("不正な入力（%s）は RangeError", (_label, value) => {
    expect(() => audioTimeUs(value)).toThrow(RangeError);
    expect(() => videoTimeUs(value)).toThrow(RangeError);
  });
});

describe("MediaClock: 初期状態", () => {
  test("累積 0・フレーム 0・停止していない・キーフレームは不要", () => {
    const clock = new MediaClock();
    expect(clock.sampleCount).toBe(0);
    expect(clock.frameIndex).toBe(0);
    expect(clock.isStalled).toBe(false);
    expect(clock.needsKeyframe).toBe(false);
  });

  test("videoTime・audioTime は、純粋な関数（videoTimeUs・audioTimeUs）と同じ値を返す", () => {
    const clock = new MediaClock();
    expect(clock.videoTime(31)).toBe(videoTimeUs(31));
    expect(clock.audioTime(1_024)).toBe(audioTimeUs(1_024));
    clock.onAudioTick(5_000);
    expect(clock.videoTime(31)).toBe(1_033_333);
    expect(clock.audioTime(clock.sampleCount)).toBe(audioTimeUs(5_000));
  });

  test("インスタンスは互いに独立している", () => {
    const first = new MediaClock();
    const second = new MediaClock();
    first.onAudioTick(SAMPLES_PER_FRAME * 10);
    expect(first.frameIndex).toBe(10);
    expect(second.frameIndex).toBe(0);
    expect(second.sampleCount).toBe(0);
  });
});

describe("MediaClock.onAudioTick: 映像 1 フレーム = 音声 1,470 サンプル", () => {
  test("128 サンプル単位：11 回（1,408 サンプル）まではフレームが無く、12 回目（1,536）で 1,470 を跨いで 1 フレーム", () => {
    const clock = new MediaClock();
    for (let tick = 1; tick <= 11; tick += 1) {
      expect(clock.onAudioTick(128).frameCount).toBe(0);
    }
    expect(clock.sampleCount).toBe(1_408);
    expect(clock.frameIndex).toBe(0);

    expect(clock.onAudioTick(128)).toMatchObject({ firstFrameIndex: 0, frameCount: 1, skippedFrameCount: 0, keyframeRequired: false });
    expect(clock.sampleCount).toBe(1_536);
    expect(clock.frameIndex).toBe(1);
  });

  test("128 サンプル単位で 4,000 回：1,470 の倍数を跨ぐたびに 1 フレーム、番号は連続（取りこぼし・重複なし）", () => {
    const clock = new MediaClock();
    const emitted: number[] = [];
    for (let tick = 0; tick < 4_000; tick += 1) {
      const range = clock.onAudioTick(128);
      expect(range.frameCount).toBeLessThanOrEqual(1);
      emitted.push(...framesOf(range));
    }
    expect(clock.sampleCount).toBe(512_000);
    expect(emitted).toEqual(Array.from({ length: Math.floor(512_000 / SAMPLES_PER_FRAME) }, (_, index) => index));
    expect(clock.frameIndex).toBe(348);
  });

  test.each([1, 7, 64, 128, 441, 1_023, 1_024, 1_469, 1_470, 1_471, 2_940, 4_096, 44_100, 100_000])(
    "呼び出しの大きさ %i サンプル：2 秒余りの間、取りこぼし・重複・飛びが無い",
    (chunk) => {
      const clock = new MediaClock();
      const problems = new Problems();
      let total = 0;
      let nextExpected = 0;
      while (total < 2 * SAMPLE_RATE + 123) {
        const range = clock.onAudioTick(chunk);
        total += chunk;
        if (range.firstFrameIndex !== nextExpected) {
          problems.report(`gap or overlap: expected ${nextExpected}, got ${range.firstFrameIndex}`);
        }
        nextExpected += range.frameCount;
        if (nextExpected !== Math.floor(total / SAMPLES_PER_FRAME)) {
          problems.report(`frame count after ${total} samples: ${nextExpected}`);
        }
      }
      expect(problems.list()).toEqual([]);
      expect(clock.sampleCount).toBe(total);
      expect(clock.frameIndex).toBe(Math.floor(total / SAMPLES_PER_FRAME));
    },
  );

  test("大きさがまちまちの呼び出し（疑似乱数・0 を含む）でも、フレーム数は floor(累積 ÷ 1,470) に一致する", () => {
    const random = seededRandom(99);
    const clock = new MediaClock();
    const problems = new Problems();
    let total = 0;
    let nextExpected = 0;
    for (let tick = 0; tick < 10_000; tick += 1) {
      const chunk = Math.floor(random() * 5_000);
      const range = clock.onAudioTick(chunk);
      total += chunk;
      if (range.firstFrameIndex !== nextExpected) {
        problems.report(`tick ${tick}: expected first ${nextExpected}, got ${range.firstFrameIndex}`);
      }
      nextExpected += range.frameCount;
      if (nextExpected !== Math.floor(total / SAMPLES_PER_FRAME)) {
        problems.report(`tick ${tick}: ${nextExpected} frames after ${total} samples`);
      }
    }
    expect(problems.list()).toEqual([]);
    expect(clock.sampleCount).toBe(total);
  });

  test("1 回で複数フレームをまたぐと、番号の区間（先頭と個数）で返す", () => {
    const clock = new MediaClock();
    expect(clock.onAudioTick(100)).toMatchObject({ firstFrameIndex: 0, frameCount: 0 });
    expect(clock.onAudioTick(SAMPLES_PER_FRAME * 3)).toMatchObject({ firstFrameIndex: 0, frameCount: 3 });
    expect(clock.onAudioTick(SAMPLES_PER_FRAME * 2)).toMatchObject({ firstFrameIndex: 3, frameCount: 2 });
    expect(clock.frameIndex).toBe(5);
  });

  test("1,470 ちょうどの境界：1,469 ではフレームが無く、1,470 でちょうど 1 フレーム", () => {
    const below = new MediaClock();
    expect(below.onAudioTick(1_469).frameCount).toBe(0);
    const exact = new MediaClock();
    expect(exact.onAudioTick(1_470)).toMatchObject({ firstFrameIndex: 0, frameCount: 1 });
    expect(exact.onAudioTick(1)).toMatchObject({ firstFrameIndex: 1, frameCount: 0 });
  });

  test("1 回の呼び出しが巨大（1 日分 = 3,810,240,000 サンプル。32 ビットを超える）でも、フレームの数は厳密（2,592,000 枚）", () => {
    const clock = new MediaClock();
    const oneDay = SAMPLE_RATE * 86_400;
    const range = clock.onAudioTick(oneDay);
    expect(oneDay).toBe(3_810_240_000);
    expect(range).toMatchObject({ firstFrameIndex: 0, frameCount: 2_592_000, skippedFrameCount: 0 });
    expect(clock.frameIndex).toBe(2_592_000);
    expect(clock.audioTime(clock.sampleCount)).toBe(86_400_000_000);
    // 端数を持ち越す：さらに 1,469 サンプルではフレームが無く、1 サンプルで 1 フレーム
    expect(clock.onAudioTick(1_469).frameCount).toBe(0);
    expect(clock.onAudioTick(1).frameCount).toBe(1);
  });

  test("0 サンプルの呼び出しは、何も進めない", () => {
    const clock = new MediaClock();
    clock.onAudioTick(2_000);
    const range = clock.onAudioTick(0);
    expect(range).toMatchObject({ firstFrameIndex: 1, frameCount: 0 });
    expect(clock.sampleCount).toBe(2_000);
    expect(clock.frameIndex).toBe(1);
  });

  test("返す区間は変更できない（凍結されている）", () => {
    const range = new MediaClock().onAudioTick(SAMPLES_PER_FRAME);
    expect(Object.isFrozen(range)).toBe(true);
  });

  test.each([
    ["負の数", -1],
    ["小数", 0.5],
    ["NaN", Number.NaN],
    ["無限大", Number.POSITIVE_INFINITY],
    ["安全整数を超える値", Number.MAX_SAFE_INTEGER + 2],
  ])("不正なサンプル数（%s）は RangeError。状態は変わらない（クロックが逆行しない）", (_label, value) => {
    const clock = new MediaClock();
    clock.onAudioTick(3_000);
    expect(() => clock.onAudioTick(value)).toThrow(RangeError);
    expect(clock.sampleCount).toBe(3_000);
    expect(clock.frameIndex).toBe(2);
  });

  test("累積が安全整数を超える呼び出しは RangeError で、状態は変わらない", () => {
    const clock = new MediaClock();
    clock.onAudioTick(Number.MAX_SAFE_INTEGER - 10);
    expect(() => clock.onAudioTick(11)).toThrow(RangeError);
    expect(clock.sampleCount).toBe(Number.MAX_SAFE_INTEGER - 10);
    expect(() => clock.onAudioTick(10)).not.toThrow();
    expect(clock.sampleCount).toBe(Number.MAX_SAFE_INTEGER);
  });
});

describe("MediaClock: 長時間の累積（BigInt を使わない）", () => {
  /**
   * 呼び出しのたびに、(1) フレームの区間が連続していること、(2) 時刻が、分母 441 の分数を厳密に足し込んだ基準値と一致することを検査する。
   * 基準値は、1 サンプル = 10,000 / 441 マイクロ秒を、呼び出しの大きさずつ、整数のまま（整数部と分子の剰余）足し込んだもの。
   */
  function runAccumulation(samplesPerTick: number, ticks: number): { problems: readonly string[]; clock: MediaClock; frames: number } {
    const clock = new MediaClock();
    const problems = new Problems();
    let nextExpectedFrame = 0;
    let wholeMicroseconds = 0;
    let remainderTimes441 = 0;

    for (let tick = 0; tick < ticks; tick += 1) {
      const range = clock.onAudioTick(samplesPerTick);
      if (range.firstFrameIndex !== nextExpectedFrame) {
        problems.report(`frame gap at tick ${tick}: expected ${nextExpectedFrame}, got ${range.firstFrameIndex}`);
        break;
      }
      nextExpectedFrame += range.frameCount;

      remainderTimes441 += samplesPerTick * 10_000;
      const carried = Math.floor(remainderTimes441 / 441);
      wholeMicroseconds += carried;
      remainderTimes441 -= carried * 441;
      const rounded = wholeMicroseconds + (2 * remainderTimes441 >= 441 ? 1 : 0);
      const actual = audioTimeUs(clock.sampleCount);
      if (actual !== rounded) {
        problems.report(`audio time deviates at tick ${tick}: ${actual} vs ${rounded}`);
        break;
      }
    }
    return { problems: problems.list(), clock, frames: nextExpectedFrame };
  }

  test("128 サンプル単位で約 19 分（400,000 回）：フレームは連続し、時刻は基準値と、毎回一致する", () => {
    const { problems, clock, frames } = runAccumulation(128, 400_000);
    expect(problems).toEqual([]);
    expect(clock.sampleCount).toBe(51_200_000);
    expect(frames).toBe(Math.floor(51_200_000 / SAMPLES_PER_FRAME));
    expect(clock.frameIndex).toBe(frames);
  });

  test("10 時間分（8,820 サンプル × 180,000 回）：フレームは 1,080,000 枚で連続し、時刻は基準値と毎回一致し、最後は 36,000,000,000 マイクロ秒ちょうど", () => {
    expect(8_820 * 180_000).toBe(TEN_HOURS_SAMPLES);
    const { problems, clock, frames } = runAccumulation(8_820, 180_000);
    expect(problems).toEqual([]);
    expect(clock.sampleCount).toBe(TEN_HOURS_SAMPLES);
    expect(frames).toBe(TEN_HOURS_FRAMES);
    expect(clock.frameIndex).toBe(TEN_HOURS_FRAMES);
    expect(clock.audioTime(clock.sampleCount)).toBe(36_000_000_000);
    expect(clock.videoTime(clock.frameIndex)).toBe(36_000_000_000);
  });

  test("1 サンプルずつ 1 秒分：1 サンプル進むたびに、時刻は基準値に一致する（累積の丸め誤差が無い）", () => {
    const { problems, clock } = runAccumulation(1, SAMPLE_RATE * 2);
    expect(problems).toEqual([]);
    expect(clock.audioTime(clock.sampleCount)).toBe(2_000_000);
  });
});

describe("MediaClock: 音声の処理系の停止と再開（11.6）", () => {
  test("停止すると isStalled になり、合成の停止を示す。停止中の呼び出しは、サンプルを数えるが、フレームを合成しない（数を skippedFrameCount で返す）", () => {
    const clock = new MediaClock();
    clock.onAudioTick(SAMPLES_PER_FRAME * 2);
    clock.onAudioStall();
    expect(clock.isStalled).toBe(true);

    const range = clock.onAudioTick(SAMPLES_PER_FRAME * 3 + 10);
    expect(range).toMatchObject({ firstFrameIndex: 2, frameCount: 0, skippedFrameCount: 3, keyframeRequired: false });
    expect(clock.sampleCount).toBe(SAMPLES_PER_FRAME * 5 + 10);
    expect(clock.frameIndex).toBe(5);
  });

  test("再開すると、空白を埋めない（番号は巻き戻らず・埋め合わせの区間も返さない）。累積とフレーム番号は変わらず、キーフレームが必要になる", () => {
    const clock = new MediaClock();
    clock.onAudioTick(SAMPLES_PER_FRAME * 4 + 100);
    clock.onAudioStall();
    expect(clock.needsKeyframe).toBe(false);

    const samplesBefore = clock.sampleCount;
    const framesBefore = clock.frameIndex;
    clock.onAudioResume();
    expect(clock.isStalled).toBe(false);
    expect(clock.needsKeyframe).toBe(true);
    expect(clock.sampleCount).toBe(samplesBefore);
    expect(clock.frameIndex).toBe(framesBefore);
  });

  test("再開後、最初にフレームを返す区間だけが keyframeRequired（1 回だけ）。そのあと needsKeyframe は下がる", () => {
    const clock = new MediaClock();
    clock.onAudioTick(SAMPLES_PER_FRAME * 4 + 100);
    clock.onAudioStall();
    clock.onAudioResume();

    const notYet = clock.onAudioTick(100);
    expect(notYet).toMatchObject({ frameCount: 0, keyframeRequired: false });
    expect(clock.needsKeyframe).toBe(true);

    const first = clock.onAudioTick(SAMPLES_PER_FRAME);
    expect(first).toMatchObject({ firstFrameIndex: 4, frameCount: 1, keyframeRequired: true });
    expect(clock.needsKeyframe).toBe(false);

    expect(clock.onAudioTick(SAMPLES_PER_FRAME)).toMatchObject({ frameCount: 1, keyframeRequired: false });
  });

  test("停止と再開をまたいでも、クロックは逆行しない（累積・フレーム番号・時刻が単調）", () => {
    const random = seededRandom(5);
    const clock = new MediaClock();
    const problems = new Problems();
    let previousSamples = 0;
    let previousFrame = 0;
    let previousAudioTime = 0;
    for (let step = 0; step < 3_000; step += 1) {
      const action = random();
      if (action < 0.1) {
        clock.onAudioStall();
      } else if (action < 0.2) {
        clock.onAudioResume();
      } else {
        clock.onAudioTick(Math.floor(random() * 3_000));
      }
      const audioTime = clock.audioTime(clock.sampleCount);
      if (clock.sampleCount < previousSamples || clock.frameIndex < previousFrame || audioTime < previousAudioTime) {
        problems.report(`clock went backwards at step ${step}`);
      }
      previousSamples = clock.sampleCount;
      previousFrame = clock.frameIndex;
      previousAudioTime = audioTime;
    }
    expect(problems.list()).toEqual([]);
  });

  test("停止は冪等。再開は、停止していなければ何もしない（キーフレームを要求しない）", () => {
    const clock = new MediaClock();
    clock.onAudioResume();
    expect(clock.isStalled).toBe(false);
    expect(clock.needsKeyframe).toBe(false);

    clock.onAudioStall();
    clock.onAudioStall();
    expect(clock.isStalled).toBe(true);
    clock.onAudioResume();
    clock.onAudioResume();
    expect(clock.isStalled).toBe(false);
    expect(clock.needsKeyframe).toBe(true);
  });

  test("再開の直前に再び停止しても、キーフレームの要求は保持される", () => {
    const clock = new MediaClock();
    clock.onAudioStall();
    clock.onAudioResume();
    clock.onAudioStall();
    expect(clock.needsKeyframe).toBe(true);
    clock.onAudioResume();
    expect(clock.needsKeyframe).toBe(true);
    expect(clock.onAudioTick(SAMPLES_PER_FRAME)).toMatchObject({ frameCount: 1, keyframeRequired: true });
  });
});
