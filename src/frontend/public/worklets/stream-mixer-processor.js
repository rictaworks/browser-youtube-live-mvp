"use strict";
/* global AudioWorkletProcessor, registerProcessor */

// 音声の混合（AudioWorklet のプロセッサ。requirements.md 11.5・11.6）。
//
// 役割
//   - 入力 0 = マイク、入力 1 = 共有音声（lib/audio/config.ts の MIXER_INPUT_KINDS の並び）を、入力ごとの音量を掛けて混合する。
//     混合後の信号が上限を超えないよう、リミッタで抑える。入力が切断されている（空の配列）ときは、その入力を無音として扱う。
//   - 処理周期（process() の呼び出し 1 回。通常は 128 サンプル）ごとに、PCM のブロック（インターリーブ。L R L R ...）と、
//     そのブロックの先頭までの累積サンプル数を、メッセージポートで送る。開始（start）の後は、ソースの有無にかかわらず、1 回も欠かさずに送る
//     （音声ソースが 1 つも無いときは、無音のブロック）。この累積サンプル数が、メディアクロックの基準になる（11.6）。
//   - 時刻の採番に、実時計（Date・performance）を使わない。累積サンプル数は、自分で数える（process() の呼び出しごとに、そのブロックの長さを足す）。
//   - 出力ポート（outputs）へは、何も書かない（常に無音）。混合の結果は、メッセージポートだけで運ぶ。出力があるのは、グラフの中で、
//     このノードが処理され続けるようにするため。配信者自身への折り返し再生を起こさないよう、出力を、スピーカーへつながない（lib/audio/AudioMixer.ts）。
//
// なぜ、TypeScript ではなく、public/ のプレーンな JavaScript か
//   AudioWorklet のモジュールは、audioWorklet.addModule(URL) で、専用のスレッドへ読み込む。Next.js 16 の公式ドキュメント
//   （node_modules/next/dist/docs）には、public/ の下のファイルを、ルート（/）から静的に配信する説明（public-folder.md）があるが、
//   AudioWorklet のモジュールを TypeScript からバンドルする方式の説明は無い（ドキュメントのどこにも、worklet の語が無い。
//   new Worker() の式を扱うマジックコメントの説明はあるが、Web Worker の話で、audioWorklet.addModule は対象外）。
//   そこで、プレーンな JavaScript を public/worklets/ に置き、/worklets/stream-mixer-processor.js として配る。
//
// 数値処理は、lib/audio/MixerCore.ts と同じ式を、同じ順序で行う（結果が 1 ビットも違わない）。一致は、
// lib/audio/streamMixerProcessor.test.ts が、このファイルを疑似の AudioWorkletGlobalScope で実行して、MixerCore と比較して保証する。
// 一方を変えるときは、他方も同じに変える。調整の値（係数・上限・音量の既定）は、このファイルに持たず、processorOptions で受け取る。
//
// コマンド（メインスレッド -> プロセッサ。node.port.postMessage）
//   { type: "gain", index, value }   入力 index の目標の音量を変える（0 以上、gainMax 以下）。現在の音量は、なだらかに近づく
//   { type: "start" }                ブロックの送信を始める。累積サンプル数は 0 から。転送された MessagePort（ports[0]）があれば、そこへ送る
//                                    （配信パイプラインのワーカーへ、メインスレッドを経由せず、直接送るため）。無ければ、node.port へ送る
// 不正なコマンドは、例外にせず、拒否を通知して、処理を続ける（メインスレッドの側が、気づけるように。process() の例外は、プロセッサを止める）。
//   { type: "rejected", command, reason }   reason: malformed・unknown_command・invalid_index・invalid_value・already_started
// ブロック（プロセッサ -> 送り先）
//   { type: "block", firstSample, frames, pcm }   pcm は Float32Array（長さ frames × 2）。バッファは、コピーせず転送する

const PROCESSOR_NAME = "stream-mixer";
const CHANNELS = 2;
const GAIN_SNAP_EPSILON = 1e-9;

function isFiniteNumber(value) {
  return typeof value === "number" && Number.isFinite(value);
}

function isValidGain(value, gainMax) {
  return isFiniteNumber(value) && value >= 0 && value <= gainMax;
}

function isCoefficient(value) {
  return isFiniteNumber(value) && value > 0 && value <= 1;
}

/** 設定の数値（チャンネル数・音量の上限・リミッタの上限・係数）を確かめる。不正なら、推測した値で続けず、例外。 */
function assertScalarSettings(settings) {
  if (settings.channelCount !== CHANNELS) {
    throw new RangeError("channelCount must be " + CHANNELS);
  }
  if (!isFiniteNumber(settings.gainMax) || settings.gainMax <= 0) {
    throw new RangeError("gainMax must be a positive finite number");
  }
  if (!isFiniteNumber(settings.ceiling) || settings.ceiling <= 0) {
    throw new RangeError("ceiling must be a positive finite number");
  }
  if (!isCoefficient(settings.limiterReleaseCoefficient) || !isCoefficient(settings.gainSmoothingCoefficient)) {
    throw new RangeError("the coefficients must be numbers greater than 0 and at most 1");
  }
}

/** 入力ごとの初期の音量を確かめる（空でない配列。すべて、0 以上、gainMax 以下の有限の数）。 */
function assertGains(settings) {
  if (!Array.isArray(settings.gains) || settings.gains.length === 0) {
    throw new TypeError("gains must be a non-empty array");
  }
  for (const gain of settings.gains) {
    if (!isValidGain(gain, settings.gainMax)) {
      throw new RangeError("every gain must be a finite number between 0 and gainMax");
    }
  }
}

/** processorOptions を確かめて、設定にする。不正なら、推測した値で続けず、例外（AudioWorkletNode の processorerror になる）。 */
function readSettings(options) {
  const settings = options === undefined || options === null ? undefined : options.processorOptions;
  if (typeof settings !== "object" || settings === null) {
    throw new TypeError("processorOptions must be an object");
  }
  assertScalarSettings(settings);
  assertGains(settings);
  return settings;
}

/** 現在の音量を、目標へ、1 サンプル分だけ近づける。差が十分に小さければ、目標へそろえる。 */
function approachGain(current, target, coefficient) {
  const difference = target - current;
  if (difference < GAIN_SNAP_EPSILON && difference > -GAIN_SNAP_EPSILON) {
    return target;
  }
  return current + difference * coefficient;
}

/** NaN・無限大は、0 として扱う（NaN の PCM を、エンコーダへ渡さないため。無限大は、リミッタの利得を 0 まで落とし、しばらく無音にするため。process() の例外は、プロセッサを止めるので、例外にしない）。 */
function finiteOrZero(sample) {
  return Number.isFinite(sample) ? sample : 0;
}

/** 上限（絶対値）を超える値を、上限にそろえる。 */
function clampToCeiling(value, ceiling) {
  if (value > ceiling) {
    return ceiling;
  }
  if (value < -ceiling) {
    return -ceiling;
  }
  return value;
}

/**
 * 入力を混合して、output（プレーナ。2 チャンネル）へ書き込む。lib/audio/MixerCore.ts の mixBlock と同じ処理。
 * inputs[k] は、入力 k のチャンネルごとのサンプル。切断された入力は、空の配列（または undefined）。
 */
function mixBlock(parameters, state, inputs, output) {
  const frames = output[0].length;
  const ceiling = parameters.ceiling;
  const limiterReleaseCoefficient = parameters.limiterReleaseCoefficient;
  const gainSmoothingCoefficient = parameters.gainSmoothingCoefficient;
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
      if (channels !== undefined && channels.length > 0) {
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

/** プレーナのブロックを、インターリーブ（L0 R0 L1 R1 ...）にして、target へ書き込む。 */
function interleave(planar, target) {
  const channelCount = planar.length;
  const frames = planar[0].length;
  for (let channelIndex = 0; channelIndex < channelCount; channelIndex += 1) {
    const channel = planar[channelIndex];
    for (let frame = 0; frame < frames; frame += 1) {
      target[frame * channelCount + channelIndex] = channel[frame];
    }
  }
  return target;
}

class StreamMixerProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const settings = readSettings(options);
    this.mixParameters = {
      ceiling: settings.ceiling,
      limiterReleaseCoefficient: settings.limiterReleaseCoefficient,
      gainSmoothingCoefficient: settings.gainSmoothingCoefficient,
    };
    this.gainMax = settings.gainMax;
    this.mixState = { gains: settings.gains.slice(), targetGains: settings.gains.slice(), limiterGain: 1 };
    this.scratch = null;
    this.sampleCount = 0;
    this.started = false;
    this.sink = null;
    this.port.onmessage = (event) => {
      this.handleCommand(event);
    };
  }

  /** メインスレッドから届いたコマンドを処理する。不正なコマンドは、例外にせず、拒否を通知する。 */
  handleCommand(event) {
    const command = event.data;
    if (typeof command !== "object" || command === null || typeof command.type !== "string") {
      this.reject(null, "malformed");
      return;
    }
    if (command.type === "gain") {
      this.setGain(command);
      return;
    }
    if (command.type === "start") {
      this.startBlocks(event.ports);
      return;
    }
    this.reject(command.type, "unknown_command");
  }

  setGain(command) {
    if (!Number.isInteger(command.index) || command.index < 0 || command.index >= this.mixState.targetGains.length) {
      this.reject("gain", "invalid_index");
      return;
    }
    if (!isValidGain(command.value, this.gainMax)) {
      this.reject("gain", "invalid_value");
      return;
    }
    this.mixState.targetGains[command.index] = command.value;
  }

  startBlocks(ports) {
    if (this.started) {
      this.reject("start", "already_started");
      return;
    }
    this.sink = ports !== undefined && ports.length > 0 ? ports[0] : null;
    this.sampleCount = 0;
    this.started = true;
  }

  reject(command, reason) {
    this.port.postMessage({ type: "rejected", command: command, reason: reason });
  }

  /** 現在のブロックの長さの、プレーナの作業用の配列を用意する（長さが変わらない限り、使い回す）。 */
  ensureScratch(frames) {
    if (this.scratch === null || this.scratch[0].length !== frames) {
      this.scratch = [new Float32Array(frames), new Float32Array(frames)];
    }
    return this.scratch;
  }

  process(inputs, outputs) {
    if (!this.started) {
      return true;
    }
    const frames = outputs.length > 0 && outputs[0].length > 0 ? outputs[0][0].length : 0;
    if (frames === 0) {
      return true;
    }
    const scratch = this.ensureScratch(frames);
    mixBlock(this.mixParameters, this.mixState, inputs, scratch);
    const pcm = interleave(scratch, new Float32Array(frames * CHANNELS));
    const target = this.sink !== null ? this.sink : this.port;
    target.postMessage({ type: "block", firstSample: this.sampleCount, frames: frames, pcm: pcm }, [pcm.buffer]);
    this.sampleCount += frames;
    return true;
  }
}

registerProcessor(PROCESSOR_NAME, StreamMixerProcessor);
