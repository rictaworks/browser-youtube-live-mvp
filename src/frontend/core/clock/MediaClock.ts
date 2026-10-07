// メディアクロック（requirements.md 4・11.6）。音声の累積サンプル数をマスタークロックとする、単調増加の時刻。
//   - 実時計（Date・performance・タイマ）から時刻を採番しない。進めるのは onAudioTick(samples) だけ
//   - 映像 1 フレーム = 音声 1,470 サンプル（44,100 ÷ 30）。音声の処理周期（128 サンプル単位の呼び出し）が合成の駆動源
//   - 時刻は累積値から毎回算出する（差分の積み上げをしない）。計算は Number の安全整数の範囲の整数演算だけで厳密に行い、BigInt を使わない
//   - 音声の処理系の停止・再開（端末の休止・音声出力の中断）では、空白を埋めずに、再開後の最初のフレームをキーフレームにする

import { LIMITS } from "../contract";

const MICROSECONDS_PER_SECOND = 1_000_000;
const SAMPLE_RATE_HZ = LIMITS.audio.sample_rate_hz;
const SAMPLES_PER_VIDEO_FRAME = LIMITS.audio.samples_per_video_frame;

function deriveFramesPerSecond(sampleRateHz: number, samplesPerVideoFrame: number): number {
  const framesPerSecond = sampleRateHz / samplesPerVideoFrame;
  if (!Number.isInteger(framesPerSecond)) {
    throw new RangeError(
      `contract audio constants are inconsistent: ${sampleRateHz} Hz is not a whole number of video frames per second at ${samplesPerVideoFrame} samples per frame`,
    );
  }
  return framesPerSecond;
}

/** 1 秒あたりの映像フレーム数（44,100 ÷ 1,470 = 30）。 */
const FRAMES_PER_SECOND = deriveFramesPerSecond(SAMPLE_RATE_HZ, SAMPLES_PER_VIDEO_FRAME);

function assertSafeNonNegativeInteger(value: number, name: string): void {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new RangeError(`${name} must be a non-negative safe integer: ${String(value)}`);
  }
}

/**
 * round(count × 1,000,000 ÷ countPerSecond)（四捨五入・0.5 は切り上げ）を、整数だけで厳密に求める。
 *
 * count × 1,000,000 を先に作ると、10 時間分の音声（1.5876 × 10^9 サンプル）でも 1.5876 × 10^15 で安全整数に収まるが、
 * それより長い入力では 2^53 を超える。そこで、秒の部分と 1 秒未満の端数に分ける。
 *   remainder = count % countPerSecond             （剰余は厳密）
 *   wholeSeconds = (count - remainder) / countPerSecond   （割り切れる除算は厳密）
 *   端数のマイクロ秒 = floor((2 × remainder × 10^6 + countPerSecond) ÷ (2 × countPerSecond))
 *     分子は 2 × 44,099 × 10^6 + 44,100 で、約 8.8 × 10^10 と小さく、商の最大は 10^6。商が整数に近づく差は 1 ÷ (2 × countPerSecond) 以上で、
 *     浮動小数点の刻み（約 10^-10）より十分に大きいため、floor の結果は厳密
 * 結果が安全整数に収まらないときは、丸めた値を返さず RangeError にする。
 */
function microsecondsOf(count: number, countPerSecond: number, name: string): number {
  assertSafeNonNegativeInteger(count, name);
  const remainder = count % countPerSecond;
  const wholeSeconds = (count - remainder) / countPerSecond;
  const fractionMicroseconds = Math.floor(
    (2 * remainder * MICROSECONDS_PER_SECOND + countPerSecond) / (2 * countPerSecond),
  );
  const total = wholeSeconds * MICROSECONDS_PER_SECOND + fractionMicroseconds;
  if (!Number.isSafeInteger(total)) {
    throw new RangeError(`${name} is too large: the time in microseconds is not a safe integer: ${String(count)}`);
  }
  return total;
}

/** 映像の時刻（マイクロ秒）= round(フレーム番号 × 1,000,000 ÷ 30)。フレーム番号は 0 始まり。毎回、番号から算出する。 */
export function videoTimeUs(frameIndex: number): number {
  return microsecondsOf(frameIndex, FRAMES_PER_SECOND, "frameIndex");
}

/** 音声の時刻（マイクロ秒）= round(累積サンプル数 × 1,000,000 ÷ 44,100)。毎回、累積値から算出する。 */
export function audioTimeUs(sampleCount: number): number {
  return microsecondsOf(sampleCount, SAMPLE_RATE_HZ, "sampleCount");
}

/**
 * 音声の処理周期（onAudioTick）が返す、合成すべきフレームの番号の区間。
 * 番号 firstFrameIndex から frameCount 枚（firstFrameIndex ... firstFrameIndex + frameCount - 1）。
 * 各フレームの時刻は videoTimeUs(番号)。
 */
export interface FrameRange {
  /** この呼び出しの前の frameIndex（区間の先頭の番号） */
  readonly firstFrameIndex: number;
  /** 合成すべきフレームの数（0 なら合成するものは無い） */
  readonly frameCount: number;
  /** 停止中（onAudioStall のあと）に期限が来て、合成しなかったフレームの数。埋め合わせはしない */
  readonly skippedFrameCount: number;
  /** 区間の最初のフレームをキーフレームにする（再開後の最初の合成。1 回だけ真） */
  readonly keyframeRequired: boolean;
}

/**
 * 音声の累積サンプル数を基準とするメディアクロック。配信 1 本につき 1 つ（再接続・復帰をまたいで続く）。
 *
 * frameIndex は「期限が来たフレームの数」= floor(sampleCount ÷ 1,470)。フレーム k（0 始まり）は、累積が (k + 1) × 1,470 に達したときに期限が来る。
 */
export class MediaClock {
  private totalSamples = 0;
  private dueFrames = 0;
  /** 端数：累積のうち、完成したフレームに満たない分（0 以上 1,470 未満） */
  private samplesIntoFrame = 0;
  private stalled = false;
  private keyframePending = false;

  /** 音声の累積サンプル数（マスタークロック）。 */
  get sampleCount(): number {
    return this.totalSamples;
  }

  /** 期限が来たフレームの数（次に期限が来るフレームの番号）。 */
  get frameIndex(): number {
    return this.dueFrames;
  }

  /** 音声の処理系が停止している（合成を止めている）。 */
  get isStalled(): boolean {
    return this.stalled;
  }

  /** 再開後、まだキーフレームを要求していない（次に合成するフレームをキーフレームにする）。 */
  get needsKeyframe(): boolean {
    return this.keyframePending;
  }

  /** フレーム番号から映像の時刻（マイクロ秒）。 */
  videoTime(frameIndex: number): number {
    return videoTimeUs(frameIndex);
  }

  /** 累積サンプル数から音声の時刻（マイクロ秒）。 */
  audioTime(sampleCount: number): number {
    return audioTimeUs(sampleCount);
  }

  /**
   * 音声の処理周期（128 サンプルなど）ごとに呼ぶ。累積サンプル数を進め、期限が来たフレームの番号の区間を返す。
   * 1,470 の倍数をまたぐたびに 1 フレーム。取りこぼしも重複も無い。
   *
   * 停止中（onAudioStall のあと）の呼び出しも、サンプルは数える（実際に生成された音声は、止めない・数え落とさない）。
   * その間に期限が来たフレームは合成せず（frameCount は 0）、数を skippedFrameCount で返す。
   * 不正な値（負・小数・NaN・安全整数を超える累積）は RangeError で、状態は変わらない（クロックは逆行しない）。
   */
  onAudioTick(samples: number): FrameRange {
    assertSafeNonNegativeInteger(samples, "samples");
    const nextTotal = this.totalSamples + samples;
    if (!Number.isSafeInteger(nextTotal)) {
      throw new RangeError(`sampleCount would exceed the safe integer range: ${String(this.totalSamples)} + ${String(samples)}`);
    }

    // 剰余で数える（浮動小数点の除算の切り捨てに頼らない）
    const pending = this.samplesIntoFrame + samples;
    const nextRemainder = pending % SAMPLES_PER_VIDEO_FRAME;
    const completedFrames = (pending - nextRemainder) / SAMPLES_PER_VIDEO_FRAME;
    const firstFrameIndex = this.dueFrames;

    this.totalSamples = nextTotal;
    this.samplesIntoFrame = nextRemainder;
    this.dueFrames = firstFrameIndex + completedFrames;

    if (this.stalled) {
      return Object.freeze({ firstFrameIndex, frameCount: 0, skippedFrameCount: completedFrames, keyframeRequired: false });
    }
    const keyframeRequired = this.keyframePending && completedFrames > 0;
    if (keyframeRequired) {
      this.keyframePending = false;
    }
    return Object.freeze({ firstFrameIndex, frameCount: completedFrames, skippedFrameCount: 0, keyframeRequired });
  }

  /** 音声の処理系の停止（端末の休止・音声出力の中断）を知らせる。合成を止める。冪等。 */
  onAudioStall(): void {
    this.stalled = true;
  }

  /**
   * 音声の処理系の再開を知らせる。空白を埋めない（累積サンプル数もフレーム番号も変えず、埋め合わせのフレームも作らない）。
   * 再開後の最初に合成するフレームをキーフレームにするため、needsKeyframe を立てる。
   * 停止していなければ何もしない（冪等）。空白が中断の期限（30 秒）を超えるかの判断は、呼び出し側（13 章）。
   */
  onAudioResume(): void {
    if (!this.stalled) {
      return;
    }
    this.stalled = false;
    this.keyframePending = true;
  }
}
