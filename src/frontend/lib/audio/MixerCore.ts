// MixerCore（requirements.md 11.5）。マイクと共有音声の混合の、純粋な数値処理。
//   - 入力ごとのゲイン（共有音声の既定はマイクの 0.6 倍。音量の変更は、なだらかに反映する）を掛けて加算する
//   - 混合後の信号が上限（フルスケール）を超えないよう、リミッタで抑える（切り取らず、全体の利得を下げる。クリップの防止）
//   - 入力が 1 つも無い（切断・無音）ときは、無音のブロックを生成する
//   - インターリーブ／プレーナの変換
//
// Web Audio・DOM・実時計に依存しない。状態（現在の音量・リミッタの利得）は、呼び出し側が持つ MixerState で、mixBlock が更新する。
// 処理は 1 サンプルずつ、状態を持ち越して進めるため、ブロックをどう区切っても、結果は同じになる（ブロック境界で段差が出ない）。
//
// このファイルの mixBlock と、public/worklets/stream-mixer-processor.js の mixBlock は、同じ数値処理を、同じ順序で行う（Float32 への書き込みも含め、
// 結果が 1 ビットも違わない）。AudioWorklet は、プレーンな JavaScript のファイルとして読み込むため、同じ式が 2 か所にある。
// 一致は、lib/audio/streamMixerProcessor.test.ts が、Worklet のファイルを疑似の AudioWorkletGlobalScope で実行して、保証する。
// 一方を変えるときは、他方も同じに変える。

import {
  MIXER_CHANNEL_COUNT,
  MIXER_GAIN_MAX,
  MIXER_GAIN_SMOOTHING_SECONDS,
  MIXER_LIMITER_CEILING,
  MIXER_LIMITER_RELEASE_SECONDS,
  MIXER_SAMPLE_RATE_HZ,
} from "./config";

/** 1 つの入力（または出力）の、チャンネルごとのサンプル（プレーナ）。入力が切断されているときは、空の配列。 */
export type PlanarBlock = readonly Float32Array[];

/**
 * 目標との差がこの値より小さくなったら、目標へそろえる（指数的な近づき方は、そのままでは、目標に届かないため）。
 * リミッタの利得が 1 へ戻るときも、同じ値で、1 へそろえる（抑えたあとに、1 に微かに届かないままになるのを避ける）。
 * 1e-9 は、約 -9e-9 dB で、聞こえない。
 */
export const GAIN_SNAP_EPSILON = 1e-9;

/** 混合の固定のパラメータ（1 つの混合器の間は変わらない）。Worklet へは、この値をそのまま渡す（係数を Worklet で計算しない）。 */
export interface MixerParameters {
  /** 出力のチャンネル数（2 のみ。11.5） */
  readonly channelCount: number;
  /** 混合後の信号の上限（絶対値。フルスケール）。これを超えないよう、リミッタが抑える */
  readonly ceiling: number;
  /** リミッタが、元の利得（1）へ戻る速さ。1 サンプルあたり、残りの差のうち、この割合だけ近づく（0 より大きく 1 以下） */
  readonly limiterReleaseCoefficient: number;
  /** 音量の変更が、目標へ近づく速さ。1 サンプルあたり、残りの差のうち、この割合だけ近づく（0 より大きく 1 以下） */
  readonly gainSmoothingCoefficient: number;
  /** 音量（倍率）の上限 */
  readonly gainMax: number;
}

/** 混合の状態。呼び出し側が持ち、mixBlock が更新する（入力の番号ごとの、現在の音量・目標の音量・リミッタの利得）。 */
export interface MixerState {
  /** 入力ごとの、現在の音量（目標へなだらかに近づく） */
  readonly gains: number[];
  /** 入力ごとの、目標の音量 */
  readonly targetGains: number[];
  /** リミッタの利得（0 より大きく 1 以下。1 = 抑えていない） */
  limiterGain: number;
}

/** 時定数（秒）から、1 サンプルあたりの係数を作る（1 - exp(-1 / (時定数 × サンプリング周波数))）。 */
function timeConstantCoefficient(seconds: number, sampleRate: number): number {
  return 1 - Math.exp(-1 / (seconds * sampleRate));
}

/** 混合のパラメータを作る。サンプリング周波数が正の有限値でなければ、推測せず RangeError。 */
export function createMixerParameters(sampleRate: number = MIXER_SAMPLE_RATE_HZ): MixerParameters {
  if (typeof sampleRate !== "number" || !Number.isFinite(sampleRate) || sampleRate <= 0) {
    throw new RangeError(`sampleRate must be a positive finite number: ${String(sampleRate)}`);
  }
  return Object.freeze({
    channelCount: MIXER_CHANNEL_COUNT,
    ceiling: MIXER_LIMITER_CEILING,
    limiterReleaseCoefficient: timeConstantCoefficient(MIXER_LIMITER_RELEASE_SECONDS, sampleRate),
    gainSmoothingCoefficient: timeConstantCoefficient(MIXER_GAIN_SMOOTHING_SECONDS, sampleRate),
    gainMax: MIXER_GAIN_MAX,
  });
}

/** 音量（倍率）が、0 以上、上限以下の有限値であることを確かめる。そうでなければ RangeError。 */
export function assertGain(value: number, gainMax: number = MIXER_GAIN_MAX): void {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > gainMax) {
    throw new RangeError(`gain must be a finite number between 0 and ${gainMax}: ${String(value)}`);
  }
}

/** 混合の状態を作る。初期の音量が、そのまま現在の音量・目標の音量になる（なだらかな変化は、起こさない）。入力が 1 つも無い状態は作れない。 */
export function createMixerState(initialGains: readonly number[], gainMax: number = MIXER_GAIN_MAX): MixerState {
  if (initialGains.length === 0) {
    throw new RangeError("a mixer needs at least one input");
  }
  for (const gain of initialGains) {
    assertGain(gain, gainMax);
  }
  return { gains: [...initialGains], targetGains: [...initialGains], limiterGain: 1 };
}

/** 入力の目標の音量を変える。現在の音量は、すぐには変わらず、目標へなだらかに近づく。不正な値・番号は RangeError で、状態を変えない。 */
export function setTargetGain(state: MixerState, index: number, value: number, gainMax: number = MIXER_GAIN_MAX): void {
  if (!Number.isInteger(index) || index < 0 || index >= state.targetGains.length) {
    throw new RangeError(`input index must be an integer between 0 and ${state.targetGains.length - 1}: ${String(index)}`);
  }
  assertGain(value, gainMax);
  state.targetGains[index] = value;
}

/** 現在の音量を、目標へ、1 サンプル分だけ近づける。差が十分に小さければ、目標へそろえる。 */
function approachGain(current: number, target: number, coefficient: number): number {
  const difference = target - current;
  if (difference < GAIN_SNAP_EPSILON && difference > -GAIN_SNAP_EPSILON) {
    return target;
  }
  return current + difference * coefficient;
}

/** NaN・無限大は、0 として扱う（NaN の PCM を、エンコーダへ渡さないため。無限大は、リミッタの利得を 0 まで落とし、しばらく無音にするため。リアルタイムの処理は、例外にしない）。 */
function finiteOrZero(sample: number): number {
  return Number.isFinite(sample) ? sample : 0;
}

/** 上限（絶対値）を超える値を、上限にそろえる。 */
function clampToCeiling(value: number, ceiling: number): number {
  if (value > ceiling) {
    return ceiling;
  }
  if (value < -ceiling) {
    return -ceiling;
  }
  return value;
}

/** 出力のブロックと、パラメータを確かめる。ブロックのサンプル数を返す。 */
function validateOutput(parameters: MixerParameters, output: PlanarBlock): number {
  if (parameters.channelCount !== MIXER_CHANNEL_COUNT) {
    throw new RangeError(`mixBlock supports ${MIXER_CHANNEL_COUNT} channels only: ${String(parameters.channelCount)}`);
  }
  if (!(parameters.ceiling > 0) || !Number.isFinite(parameters.ceiling)) {
    throw new RangeError(`ceiling must be a positive finite number: ${String(parameters.ceiling)}`);
  }
  if (output.length !== parameters.channelCount) {
    throw new RangeError(`output must have ${parameters.channelCount} channels: ${output.length}`);
  }
  const frames = output[0].length;
  for (const channel of output) {
    if (channel.length !== frames) {
      throw new RangeError(`output channels must have the same length: ${channel.length} != ${frames}`);
    }
  }
  return frames;
}

/** 入力の数・チャンネルの長さが、状態と出力に合うことを確かめる。 */
function validateInputs(state: MixerState, inputs: readonly PlanarBlock[], frames: number): void {
  if (state.gains.length !== state.targetGains.length) {
    throw new RangeError("state.gains and state.targetGains must have the same length");
  }
  if (inputs.length !== state.gains.length) {
    throw new RangeError(`the number of inputs must equal the number of gains: ${inputs.length} != ${state.gains.length}`);
  }
  for (const channels of inputs) {
    for (const channel of channels) {
      if (channel.length !== frames) {
        throw new RangeError(`input channels must have the same length as the output: ${channel.length} != ${frames}`);
      }
    }
  }
}

/** mixBlock の引数を、状態を変える前に、すべて確かめる。ブロックのサンプル数を返す。 */
function validateMixArguments(parameters: MixerParameters, state: MixerState, inputs: readonly PlanarBlock[], output: PlanarBlock): number {
  const frames = validateOutput(parameters, output);
  validateInputs(state, inputs, frames);
  return frames;
}

/**
 * 入力を混合して、output（プレーナ）へ書き込む。output のすべての点を上書きする。
 *
 * 入力ごとに、現在の音量（目標へなだらかに近づく）を掛けて、加算する。1 チャンネルの入力は左右へ同じ値を、3 チャンネル以上の入力は先頭の 2 つを使い、
 * 切断された入力（空の配列）は、無音として扱う。入力がすべて切断されていれば、出力は無音（0）になる。
 * 混合した信号の左右の大きい方の絶対値が上限を超えるとき、利得を下げて上限に収める（左右の利得は同じ。左右の比が保たれる）。
 * 利得は、超えた瞬間に下がり、超えなくなれば、時定数に従って、1 へ戻る。最後に、浮動小数点の丸めの誤差も含め、上限を超えない。
 * NaN・無限大の入力の点は 0 として扱う。
 *
 * 引数が正しくないとき（チャンネル数・長さ・入力の数）は、状態も output も変えず、RangeError。
 */
export function mixBlock(parameters: MixerParameters, state: MixerState, inputs: readonly PlanarBlock[], output: PlanarBlock): void {
  const frames = validateMixArguments(parameters, state, inputs, output);
  const { ceiling, limiterReleaseCoefficient, gainSmoothingCoefficient } = parameters;
  const inputCount = state.gains.length;
  const outputLeft = output[0];
  const outputRight = output[1];
  let limiterGain = state.limiterGain;

  for (let frame = 0; frame < frames; frame += 1) {
    let left = 0;
    let right = 0;
    for (let index = 0; index < inputCount; index += 1) {
      const gain = approachGain(state.gains[index], state.targetGains[index], gainSmoothingCoefficient);
      state.gains[index] = gain;
      const channels = inputs[index];
      if (channels.length > 0) {
        left += finiteOrZero(channels[0][frame]) * gain;
        right += finiteOrZero(channels.length > 1 ? channels[1][frame] : channels[0][frame]) * gain;
      }
    }

    const peak = Math.max(Math.abs(left), Math.abs(right));
    const required = peak > ceiling ? ceiling / peak : 1;
    let released = limiterGain + (1 - limiterGain) * limiterReleaseCoefficient;
    if (1 - released < GAIN_SNAP_EPSILON) {
      released = 1;
    }
    limiterGain = required < released ? required : released;

    outputLeft[frame] = clampToCeiling(left * limiterGain, ceiling);
    outputRight[frame] = clampToCeiling(right * limiterGain, ceiling);
  }
  state.limiterGain = limiterGain;
}

/**
 * プレーナ（チャンネルごと）のブロックを、インターリーブ（L0 R0 L1 R1 ...）にする。
 * target を渡すと、そこへ書き込み、同じ配列を返す（長さは、サンプル数 × チャンネル数）。渡さなければ、新しく作る。
 */
export function interleave(planar: PlanarBlock, target?: Float32Array): Float32Array {
  const channelCount = planar.length;
  if (channelCount === 0) {
    throw new RangeError("planar must have at least one channel");
  }
  const frames = planar[0].length;
  for (const channel of planar) {
    if (channel.length !== frames) {
      throw new RangeError(`planar channels must have the same length: ${channel.length} != ${frames}`);
    }
  }
  const required = frames * channelCount;
  const result = target ?? new Float32Array(required);
  if (result.length !== required) {
    throw new RangeError(`target must have ${required} samples: ${result.length}`);
  }
  for (let channelIndex = 0; channelIndex < channelCount; channelIndex += 1) {
    const channel = planar[channelIndex];
    for (let frame = 0; frame < frames; frame += 1) {
      result[frame * channelCount + channelIndex] = channel[frame];
    }
  }
  return result;
}

/** インターリーブのブロックを、プレーナ（チャンネルごと）へ戻す。 */
export function deinterleave(interleaved: Float32Array, channelCount: number): Float32Array[] {
  if (!Number.isInteger(channelCount) || channelCount < 1) {
    throw new RangeError(`channelCount must be a positive integer: ${String(channelCount)}`);
  }
  if (interleaved.length % channelCount !== 0) {
    throw new RangeError(`the length ${interleaved.length} is not a multiple of channelCount ${channelCount}`);
  }
  const frames = interleaved.length / channelCount;
  const planar = Array.from({ length: channelCount }, () => new Float32Array(frames));
  for (let frame = 0; frame < frames; frame += 1) {
    for (let channelIndex = 0; channelIndex < channelCount; channelIndex += 1) {
      planar[channelIndex][frame] = interleaved[frame * channelCount + channelIndex];
    }
  }
  return planar;
}
