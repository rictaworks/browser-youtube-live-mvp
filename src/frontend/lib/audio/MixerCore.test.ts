/**
 * @jest-environment node
 */
// MixerCore（requirements.md 11.5）。マイクと共有音声の混合の、純粋な数値処理。
//   - 加算とゲイン（共有音声の既定はマイクの 0.6 倍）・位相・上限（リミッタ。クリップの防止）・無音・ゲインの変更・ブロック境界
//   - インターリーブ／プレーナの変換
// 実時計・乱数（Math.random）は使わない。ランダムな信号は、種つきの疑似乱数で作る（毎回同じ）。
// 大量の点を検査するループは、点ごとに expect を呼ばず、食い違いを集めて、最後に 1 回だけ検査する（Jest では、点ごとの expect が遅いため）。
import { Problems, seededRandom } from "@/core/testing/helpers";
import { DEFAULT_MIXER_GAINS, MIXER_CHANNEL_COUNT, MIXER_GAIN_MAX, MIXER_INPUT_KINDS, MIXER_LIMITER_CEILING, MIXER_SAMPLE_RATE_HZ } from "./config";
import type { MixerParameters, MixerState } from "./MixerCore";
import { GAIN_SNAP_EPSILON, createMixerParameters, createMixerState, deinterleave, interleave, mixBlock, setTargetGain } from "./MixerCore";

const PARAMETERS: MixerParameters = createMixerParameters();
const MICROPHONE = 0;
const SHARED_AUDIO = 1;

function defaultGains(): number[] {
  return MIXER_INPUT_KINDS.map((kind) => DEFAULT_MIXER_GAINS[kind]);
}

function defaultState(): MixerState {
  return createMixerState(defaultGains());
}

/** 2 チャンネルのブロック（右を省略したら、左と同じ）。 */
function stereo(left: ArrayLike<number>, right: ArrayLike<number> = left): Float32Array[] {
  return [Float32Array.from(left), Float32Array.from(right)];
}

function filled(frames: number, value: number): Float32Array[] {
  return stereo(new Array<number>(frames).fill(value));
}

function emptyOutput(frames: number): Float32Array[] {
  return [new Float32Array(frames), new Float32Array(frames)];
}

function randomBlock(random: () => number, frames: number, amplitude: number): Float32Array[] {
  const channel = (): Float32Array => Float32Array.from({ length: frames }, () => (random() * 2 - 1) * amplitude);
  return [channel(), channel()];
}

/** 出力を、数の配列にする（Float32Array の比較は、配列にそろえて行う）。 */
function values(channel: Float32Array): number[] {
  return Array.from(channel);
}

describe("契約と設定の対応", () => {
  it("サンプリング周波数は 44,100 Hz、チャンネル数は 2、上限（フルスケール）は 1", () => {
    expect(MIXER_SAMPLE_RATE_HZ).toBe(44_100);
    expect(MIXER_CHANNEL_COUNT).toBe(2);
    expect(MIXER_LIMITER_CEILING).toBe(1);
  });

  it("入力の並びは、マイク（0）・共有音声（1）。共有音声の既定の倍率は、マイクの 0.6 倍（11.5）", () => {
    expect(MIXER_INPUT_KINDS).toEqual(["microphone", "shared_audio"]);
    expect(MIXER_INPUT_KINDS[MICROPHONE]).toBe("microphone");
    expect(MIXER_INPUT_KINDS[SHARED_AUDIO]).toBe("shared_audio");
    expect(DEFAULT_MIXER_GAINS.microphone).toBe(1);
    expect(DEFAULT_MIXER_GAINS.shared_audio / DEFAULT_MIXER_GAINS.microphone).toBe(0.6);
  });
});

describe("createMixerParameters", () => {
  it("時定数から、1 サンプルあたりの係数を作る（1 - exp(-1 / (時定数 × サンプリング周波数))）", () => {
    const parameters = createMixerParameters(44_100);

    expect(parameters.channelCount).toBe(2);
    expect(parameters.ceiling).toBe(1);
    expect(parameters.gainMax).toBe(MIXER_GAIN_MAX);
    expect(parameters.limiterReleaseCoefficient).toBe(1 - Math.exp(-1 / (0.1 * 44_100)));
    expect(parameters.gainSmoothingCoefficient).toBe(1 - Math.exp(-1 / (0.01 * 44_100)));
    expect(parameters.limiterReleaseCoefficient).toBeGreaterThan(0);
    expect(parameters.limiterReleaseCoefficient).toBeLessThan(parameters.gainSmoothingCoefficient);
    expect(parameters.gainSmoothingCoefficient).toBeLessThan(1);
  });

  it("引数を省くと、混合の既定のサンプリング周波数（44,100 Hz）で作る", () => {
    expect(createMixerParameters()).toEqual(createMixerParameters(MIXER_SAMPLE_RATE_HZ));
  });

  it("結果は凍結されている（実行中に書き換えられない）", () => {
    expect(Object.isFrozen(createMixerParameters())).toBe(true);
  });

  it.each([0, -1, Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY])("不正なサンプリング周波数（%p）は RangeError", (sampleRate) => {
    expect(() => createMixerParameters(sampleRate)).toThrow(RangeError);
  });
});

describe("createMixerState・setTargetGain", () => {
  it("初期の音量は、そのまま現在の音量でも目標でもある。リミッタの利得は 1", () => {
    const state = createMixerState([1, 0.6]);

    expect(state.gains).toEqual([1, 0.6]);
    expect(state.targetGains).toEqual([1, 0.6]);
    expect(state.limiterGain).toBe(1);
  });

  it("渡した配列と、状態は、別のもの（呼び出し側の配列を書き換えない）", () => {
    const initial = [1, 0.6];
    const state = createMixerState(initial);
    setTargetGain(state, 1, 0.2);

    expect(initial).toEqual([1, 0.6]);
  });

  it("目標の音量を変えても、現在の音量は、すぐには変わらない（なだらかに近づく）", () => {
    const state = defaultState();
    setTargetGain(state, SHARED_AUDIO, 0.2);

    expect(state.targetGains[SHARED_AUDIO]).toBe(0.2);
    expect(state.gains[SHARED_AUDIO]).toBe(0.6);
  });

  it.each([
    ["0（無音）", 0],
    ["上限ちょうど", MIXER_GAIN_MAX],
    ["1", 1],
  ])("音量の境界値（%s）は設定できる", (_name, value) => {
    const state = defaultState();

    setTargetGain(state, MICROPHONE, value);

    expect(state.targetGains[MICROPHONE]).toBe(value);
  });

  it.each([
    ["NaN", Number.NaN],
    ["+Infinity", Number.POSITIVE_INFINITY],
    ["-Infinity", Number.NEGATIVE_INFINITY],
    ["負の値", -0.001],
    ["上限を超える値", MIXER_GAIN_MAX + 0.001],
  ])("不正な音量（%s）は RangeError で、状態を変えない", (_name, value) => {
    const state = defaultState();

    expect(() => setTargetGain(state, SHARED_AUDIO, value)).toThrow(RangeError);

    expect(state.targetGains).toEqual(defaultGains());
  });

  it.each([-1, 2, 1.5, Number.NaN])("入力の番号（%p）が範囲外・整数でなければ RangeError", (index) => {
    expect(() => setTargetGain(defaultState(), index, 0.5)).toThrow(RangeError);
  });

  it("初期の音量の不正（NaN・負・上限超え）も RangeError。入力が 1 つも無い状態は作れない", () => {
    expect(() => createMixerState([1, Number.NaN])).toThrow(RangeError);
    expect(() => createMixerState([-1])).toThrow(RangeError);
    expect(() => createMixerState([MIXER_GAIN_MAX + 1])).toThrow(RangeError);
    expect(() => createMixerState([])).toThrow(RangeError);
  });
});

describe("mixBlock: 加算とゲイン", () => {
  it("マイクだけのとき、出力はマイクの信号そのもの（倍率 1）", () => {
    const output = emptyOutput(4);

    mixBlock(PARAMETERS, defaultState(), [stereo([0.25, -0.5, 0.125, 0], [-0.25, 0.5, 0, 0.0625]), []], output);

    expect(values(output[0])).toEqual([0.25, -0.5, 0.125, 0]);
    expect(values(output[1])).toEqual([-0.25, 0.5, 0, 0.0625]);
  });

  it("共有音声だけのとき、出力は共有音声の 0.6 倍", () => {
    const shared = stereo([0.5, -0.5, 0.25, 0]);
    const output = emptyOutput(4);

    mixBlock(PARAMETERS, defaultState(), [[], shared], output);

    expect(values(output[0])).toEqual(Array.from(shared[0], (sample) => Math.fround(sample * 0.6)));
  });

  it.each([
    ["同じ大きさ", [0.5, 0.25], [0.5, 0.25]],
    ["符号が逆", [0.5, -0.25], [-0.5, 0.25]],
    ["片方が 0", [0.5, 0], [0, 0.125]],
    ["小さい値", [1e-6, -1e-6], [3e-7, 2e-7]],
    ["上限の手前", [0.3, -0.3], [0.5, -0.5]],
  ])("両方があるとき、出力はマイク × 1 + 共有音声 × 0.6（%s）", (_name, micValues, sharedValues) => {
    const mic = stereo(micValues);
    const shared = stereo(sharedValues);
    const output = emptyOutput(2);

    mixBlock(PARAMETERS, defaultState(), [mic, shared], output);

    const expected = Array.from(mic[0], (sample, index) => Math.fround(sample * 1 + shared[0][index] * 0.6));
    expect(values(output[0])).toEqual(expected);
  });

  it("音量を 0 にした入力は、混合から外したのと同じ", () => {
    const random = seededRandom(7);
    const mic = randomBlock(random, 128, 0.4);
    const shared = randomBlock(random, 128, 0.4);
    const muted = emptyOutput(128);
    const absent = emptyOutput(128);

    mixBlock(PARAMETERS, createMixerState([1, 0]), [mic, shared], muted);
    mixBlock(PARAMETERS, createMixerState([1, 0]), [mic, []], absent);

    expect(values(muted[0])).toEqual(values(absent[0]));
    expect(values(muted[1])).toEqual(values(absent[1]));
  });

  it("入力の音量は、入力ごとに独立（共有音声の音量を変えても、マイクの出力は変わらない）", () => {
    const mic = stereo([0.25, -0.25, 0.5, 0]);
    const loud = emptyOutput(4);
    const quiet = emptyOutput(4);

    mixBlock(PARAMETERS, createMixerState([1, 1]), [mic, []], loud);
    mixBlock(PARAMETERS, createMixerState([1, 0.1]), [mic, []], quiet);

    expect(values(loud[0])).toEqual(values(quiet[0]));
  });
});

describe("mixBlock: 位相・チャンネル", () => {
  it("同位相の信号は加わり、逆位相の同じ大きさの信号は打ち消し合う", () => {
    const inPhase = emptyOutput(4);
    const opposite = emptyOutput(4);
    const half = createMixerState([1, 0.5]);

    mixBlock(PARAMETERS, createMixerState([1, 0.5]), [stereo([0.25, 0.125, -0.25, 0]), stereo([0.25, 0.125, -0.25, 0])], inPhase);
    mixBlock(PARAMETERS, half, [stereo([0.25, 0.125, -0.25, 0]), stereo([-0.5, -0.25, 0.5, 0])], opposite);

    expect(values(inPhase[0])).toEqual([0.375, 0.1875, -0.375, 0]);
    expect(values(opposite[0])).toEqual([0, 0, 0, 0]);
  });

  it("左右は独立（左だけの信号は、左だけに出る。極性は保たれる）", () => {
    const output = emptyOutput(4);

    mixBlock(PARAMETERS, defaultState(), [stereo([0.5, -0.5, 0.25, -0.125], [0, 0, 0, 0]), []], output);

    expect(values(output[0])).toEqual([0.5, -0.5, 0.25, -0.125]);
    expect(values(output[1])).toEqual([0, 0, 0, 0]);
  });

  it("1 チャンネル（モノラル）の入力は、左右の両方へ同じ値を出す", () => {
    const output = emptyOutput(3);

    mixBlock(PARAMETERS, defaultState(), [[Float32Array.from([0.5, -0.25, 0.125])], []], output);

    expect(values(output[0])).toEqual([0.5, -0.25, 0.125]);
    expect(values(output[1])).toEqual([0.5, -0.25, 0.125]);
  });

  it("3 チャンネル以上の入力は、先頭の 2 つだけを使う", () => {
    const output = emptyOutput(2);

    mixBlock(PARAMETERS, defaultState(), [[Float32Array.from([0.5, 0.5]), Float32Array.from([0.25, 0.25]), Float32Array.from([0.9, 0.9])], []], output);

    expect(values(output[0])).toEqual([0.5, 0.5]);
    expect(values(output[1])).toEqual([0.25, 0.25]);
  });

  it("出力のブロックは、すべての点が上書きされる（前の内容が残らない）", () => {
    const output = [Float32Array.from([9, 9, 9]), Float32Array.from([9, 9, 9])];

    mixBlock(PARAMETERS, defaultState(), [[], []], output);

    expect(values(output[0])).toEqual([0, 0, 0]);
    expect(values(output[1])).toEqual([0, 0, 0]);
  });
});

describe("mixBlock: 上限（リミッタ。クリップの防止）", () => {
  it("上限ちょうど（1.0）は、そのまま通す（利得は 1 のまま）", () => {
    const state = defaultState();
    const output = emptyOutput(2);

    mixBlock(PARAMETERS, state, [stereo([1, -1], [-1, 1]), []], output);

    expect(values(output[0])).toEqual([1, -1]);
    expect(values(output[1])).toEqual([-1, 1]);
    expect(state.limiterGain).toBe(1);
  });

  it("上限を超えるピークは、絶対値が上限（1）まで抑えられ、手前の信号は変わらない（正負とも）", () => {
    const state = defaultState();
    const output = emptyOutput(3);

    mixBlock(PARAMETERS, state, [stereo([0.5, 1.5, -1.5]), []], output);

    expect(output[0][0]).toBe(0.5);
    expect(Math.abs(output[0][1])).toBeLessThanOrEqual(1);
    expect(Math.abs(output[0][1])).toBeGreaterThan(0.999999);
    expect(Math.abs(output[0][2])).toBeLessThanOrEqual(1);
    expect(Math.abs(output[0][2])).toBeGreaterThan(0.999999);
    expect(output[0][2]).toBeLessThan(0);
    expect(state.limiterGain).toBeCloseTo(2 / 3, 9);
  });

  it("マイク 1.0 と共有音声 1.0 を足した 1.6 は、切り取らず、全体を縮めて上限に収める", () => {
    const output = emptyOutput(1000);

    mixBlock(PARAMETERS, defaultState(), [filled(1000, 1), filled(1000, 1)], output);

    const problems = new Problems();
    for (let index = 0; index < 1000; index += 1) {
      const sample = output[0][index];
      if (sample > 1 || sample < 0.9999999) {
        problems.report(`index ${index}: ${sample}`);
      }
    }
    expect(problems.list()).toEqual([]);
  });

  it("左右はリンクして抑える（片方だけが上限を超えても、左右の比が保たれる）", () => {
    const output = emptyOutput(1);

    mixBlock(PARAMETERS, defaultState(), [stereo([2], [0.5]), []], output);

    expect(output[0][0]).toBe(1);
    expect(output[1][0]).toBe(0.25);
  });

  it("上限は設定で変えられる（上限 0.5 なら、すべての出力が 0.5 以下）", () => {
    const parameters: MixerParameters = { ...PARAMETERS, ceiling: 0.5 };
    const random = seededRandom(11);
    const output = emptyOutput(128);
    const state = defaultState();
    const problems = new Problems();

    for (let block = 0; block < 200; block += 1) {
      mixBlock(parameters, state, [randomBlock(random, 128, 3), randomBlock(random, 128, 3)], output);
      for (const channel of output) {
        for (const sample of channel) {
          if (Math.abs(sample) > 0.5) {
            problems.report(`block ${block}: ${sample}`);
          }
        }
      }
    }

    expect(problems.list()).toEqual([]);
  });

  it("性質: どんな大きな信号（振幅 8）でも、すべての出力は有限で、絶対値が 1 以下", () => {
    const random = seededRandom(20_261_007);
    const state = defaultState();
    const output = emptyOutput(128);
    const problems = new Problems();
    let loudestOutput = 0;

    for (let block = 0; block < 1500; block += 1) {
      const amplitude = block % 3 === 0 ? 8 : block % 3 === 1 ? 1.2 : 0.2;
      mixBlock(PARAMETERS, state, [randomBlock(random, 128, amplitude), randomBlock(random, 128, amplitude)], output);
      for (const channel of output) {
        for (const sample of channel) {
          if (!Number.isFinite(sample) || Math.abs(sample) > 1) {
            problems.report(`block ${block}: ${sample}`);
          }
          loudestOutput = Math.max(loudestOutput, Math.abs(sample));
        }
      }
    }

    expect(problems.list()).toEqual([]);
    expect(loudestOutput).toBeGreaterThan(0.99);
  });

  it("抑えたあと、時定数に従って、元の利得（1）へ戻る（1 - (1 - g0) × (1 - 係数)^サンプル数）", () => {
    const state = defaultState();
    const output = emptyOutput(1);
    mixBlock(PARAMETERS, state, [stereo([2]), []], output);
    expect(state.limiterGain).toBe(0.5);

    const small = filled(100, 0.1);
    const settle = emptyOutput(100);
    mixBlock(PARAMETERS, state, [small, []], settle);

    const expected = 1 - 0.5 * (1 - PARAMETERS.limiterReleaseCoefficient) ** 100;
    expect(state.limiterGain).toBeCloseTo(expected, 9);
    expect(state.limiterGain).toBeGreaterThan(0.5);
    expect(state.limiterGain).toBeLessThan(1);
  });

  it("十分な時間（10 万サンプル）のあとは、利得がちょうど 1 に戻り、信号は元のまま通る", () => {
    const state = defaultState();
    mixBlock(PARAMETERS, state, [stereo([2]), []], emptyOutput(1));

    const quiet = filled(128, 0.1);
    const output = emptyOutput(128);
    for (let block = 0; block < 800; block += 1) {
      mixBlock(PARAMETERS, state, [quiet, []], output);
    }

    expect(state.limiterGain).toBe(1);
    expect(values(output[0])).toEqual(new Array<number>(128).fill(Math.fround(0.1)));
  });

  it("利得は、1 を超えない・0 以下にならない（過大な入力が続いても）", () => {
    const state = defaultState();
    const random = seededRandom(3);
    const problems = new Problems();

    for (let block = 0; block < 500; block += 1) {
      mixBlock(PARAMETERS, state, [randomBlock(random, 128, 100), randomBlock(random, 128, 100)], emptyOutput(128));
      if (!(state.limiterGain > 0 && state.limiterGain <= 1)) {
        problems.report(`block ${block}: ${state.limiterGain}`);
      }
    }

    expect(problems.list()).toEqual([]);
  });
});

describe("mixBlock: 無音（音声ソースが 1 つも無くても、無音のブロックを生成し続ける）", () => {
  it.each([
    ["入力がすべて切断（空の配列）", () => [[], []] as Float32Array[][]],
    ["入力が、0 だけのブロック", () => [filled(128, 0), filled(128, 0)]],
    ["片方だけ 0 のブロック、もう片方は切断", () => [filled(128, 0), []]],
  ])("%s: 1,000 ブロックのすべての点が 0 で、状態が変わらない", (_name, makeInputs) => {
    const state = defaultState();
    const output = emptyOutput(128);
    const problems = new Problems();

    for (let block = 0; block < 1000; block += 1) {
      mixBlock(PARAMETERS, state, makeInputs(), output);
      for (const channel of output) {
        for (const sample of channel) {
          if (!Object.is(sample, 0)) {
            problems.report(`block ${block}: ${sample}`);
          }
        }
      }
    }

    expect(problems.list()).toEqual([]);
    expect(state.limiterGain).toBe(1);
    expect(state.gains).toEqual(defaultGains());
  });
});

describe("mixBlock: 音量の変更（なだらかに反映する）", () => {
  it("下げる: 共有音声の定常信号に対して、出力は単調に減り、最後にちょうど 0 になる", () => {
    const state = defaultState();
    const shared = filled(128, 1);
    const output = emptyOutput(128);
    mixBlock(PARAMETERS, state, [[], shared], output);
    expect(output[0][127]).toBe(Math.fround(0.6));
    setTargetGain(state, SHARED_AUDIO, 0);

    let previous = Number.POSITIVE_INFINITY;
    let firstAfterChange = Number.NaN;
    const problems = new Problems();
    for (let block = 0; block < 160; block += 1) {
      mixBlock(PARAMETERS, state, [[], shared], output);
      if (block === 0) {
        firstAfterChange = output[0][0];
      }
      for (const sample of output[0]) {
        if (sample > previous) {
          problems.report(`block ${block}: ${sample} > ${previous}`);
        }
        previous = sample;
      }
    }

    expect(problems.list()).toEqual([]);
    expect(firstAfterChange).toBeLessThan(0.6);
    expect(firstAfterChange).toBeGreaterThan(0.59);
    expect(Object.is(output[0][127], 0)).toBe(true);
    expect(state.gains[SHARED_AUDIO]).toBe(0);
  });

  it("上げる: 隣り合う出力の差（段差）が小さい（0.6 から 1.0 へ、1 サンプルあたり 0.001 以下）", () => {
    const state = defaultState();
    setTargetGain(state, SHARED_AUDIO, 1);
    const shared = filled(128, 1);
    const output = emptyOutput(128);
    let previous = 0.6;
    let largestStep = 0;

    for (let block = 0; block < 100; block += 1) {
      mixBlock(PARAMETERS, state, [[], shared], output);
      for (const sample of output[0]) {
        largestStep = Math.max(largestStep, Math.abs(sample - previous));
        previous = sample;
      }
    }

    expect(largestStep).toBeLessThan(0.001);
    expect(previous).toBe(1);
  });

  it("目標との差が十分に小さくなったら、目標へそろえる（現在の音量が目標と一致して止まる）", () => {
    const state = defaultState();
    setTargetGain(state, MICROPHONE, 0.25);

    for (let block = 0; block < 100; block += 1) {
      mixBlock(PARAMETERS, state, [[], []], emptyOutput(128));
    }

    expect(state.gains[MICROPHONE]).toBe(0.25);
    expect(GAIN_SNAP_EPSILON).toBe(1e-9);
  });
});

describe("mixBlock: ブロック境界（どう区切っても、結果は同じ）", () => {
  const TOTAL = 5000;

  interface Signals {
    readonly mic: Float32Array[];
    readonly shared: Float32Array[];
  }

  function makeSignals(): Signals {
    const random = seededRandom(424_242);
    return { mic: randomBlock(random, TOTAL, 1.4), shared: randomBlock(random, TOTAL, 1.4) };
  }

  /** 区切り（先頭から順のブロックの大きさ）に従って処理する。gainChange があれば、その位置（区切りの上）で、共有音声の目標を変える。 */
  function render(signals: Signals, chunks: readonly number[], gainChange?: { at: number; value: number }): { output: Float32Array[]; state: MixerState } {
    const state = defaultState();
    const output = emptyOutput(TOTAL);
    let start = 0;
    for (const size of chunks) {
      if (gainChange !== undefined && start === gainChange.at) {
        setTargetGain(state, SHARED_AUDIO, gainChange.value);
      }
      const end = start + size;
      const slice = (block: Float32Array[]): Float32Array[] => block.map((channel) => channel.subarray(start, end));
      mixBlock(PARAMETERS, state, [slice(signals.mic), slice(signals.shared)], output.map((channel) => channel.subarray(start, end)));
      start = end;
    }
    expect(start).toBe(TOTAL);
    return { output, state };
  }

  function repeated(size: number, count: number): number[] {
    return new Array<number>(count).fill(size);
  }

  const PARTITIONS: readonly (readonly [string, number[]])[] = [
    ["全体を 1 回", [TOTAL]],
    ["128 サンプルずつ（Web Audio の処理周期）", [...repeated(128, 39), 8]],
    ["1 サンプルずつ", repeated(1, TOTAL)],
    ["1,470 サンプルずつ（映像 1 フレーム分）", [...repeated(1470, 3), 590]],
    ["不規則（1・7・129・500・3・…）", [1, 7, 129, 500, 3, 1000, 2, 63, 2000, 1, 1294]],
  ];

  it("区切りの大きさの組が、すべて TOTAL に等しい（テストの前提）", () => {
    for (const [, chunks] of PARTITIONS) {
      expect(chunks.reduce((sum, size) => sum + size, 0)).toBe(TOTAL);
    }
  });

  it.each(PARTITIONS)("区切り: %s は、全体を 1 回で処理した結果と、すべての点・最終の状態が一致する", (_name, chunks) => {
    const signals = makeSignals();
    const whole = render(signals, [TOTAL]);

    const split = render(signals, chunks);

    const problems = new Problems();
    for (let channel = 0; channel < 2; channel += 1) {
      for (let index = 0; index < TOTAL; index += 1) {
        if (!Object.is(split.output[channel][index], whole.output[channel][index])) {
          problems.report(`channel ${channel} index ${index}: ${split.output[channel][index]} != ${whole.output[channel][index]}`);
        }
      }
    }
    expect(problems.list()).toEqual([]);
    expect(split.state).toEqual(whole.state);
  });

  it("音量の変更が区切りの上にあるとき（2,048 サンプル目）も、区切りによらず同じ結果", () => {
    const signals = makeSignals();
    const change = { at: 2048, value: 0.1 };
    const whole = render(signals, [2048, TOTAL - 2048], change);

    const irregular = render(signals, [100, 1948, 3, 1, 948, 2000], change);

    expect(irregular.output.map(values)).toEqual(whole.output.map(values));
    expect(irregular.state).toEqual(whole.state);
  });
});

describe("mixBlock: 非有限値（NaN・無限大）", () => {
  it("非有限の入力の点は 0 として扱う。出力は有限のまま、状態（利得）を壊さない", () => {
    const mic = stereo([0.5, Number.NaN, 0.5, Number.POSITIVE_INFINITY, 0.5, Number.NEGATIVE_INFINITY, 0.5]);
    const clean = stereo([0.5, 0, 0.5, 0, 0.5, 0, 0.5]);
    const state = defaultState();
    const output = emptyOutput(7);
    const reference = emptyOutput(7);

    mixBlock(PARAMETERS, state, [mic, []], output);
    mixBlock(PARAMETERS, defaultState(), [clean, []], reference);

    expect(values(output[0])).toEqual(values(reference[0]));
    expect(state.limiterGain).toBe(1);
    expect(state.gains).toEqual(defaultGains());
  });
});

describe("mixBlock: 引数の検査（呼び出しの誤りは、推測せず RangeError）", () => {
  it("出力のチャンネル数が、パラメータと違うとき", () => {
    expect(() => mixBlock(PARAMETERS, defaultState(), [[], []], [new Float32Array(4)])).toThrow(RangeError);
  });

  it("出力のチャンネルの長さが、そろっていないとき", () => {
    expect(() => mixBlock(PARAMETERS, defaultState(), [[], []], [new Float32Array(4), new Float32Array(3)])).toThrow(RangeError);
  });

  it("入力のチャンネルの長さが、出力と違うとき", () => {
    expect(() => mixBlock(PARAMETERS, defaultState(), [stereo([0.1, 0.2, 0.3]), []], emptyOutput(4))).toThrow(RangeError);
  });

  it("入力の数が、音量の数と違うとき", () => {
    expect(() => mixBlock(PARAMETERS, defaultState(), [[]], emptyOutput(4))).toThrow(RangeError);
    expect(() => mixBlock(PARAMETERS, defaultState(), [[], [], []], emptyOutput(4))).toThrow(RangeError);
  });

  it("エラーのとき、出力と状態を変えない", () => {
    const state = defaultState();
    const output = [Float32Array.from([7, 7, 7, 7]), Float32Array.from([7, 7, 7, 7])];

    expect(() => mixBlock(PARAMETERS, state, [stereo([0.1, 0.2, 0.3]), []], output)).toThrow(RangeError);

    expect(values(output[0])).toEqual([7, 7, 7, 7]);
    expect(state).toEqual(defaultState());
  });
});

describe("interleave・deinterleave", () => {
  it("インターリーブは、左右の順に並べる（L0 R0 L1 R1 ...）", () => {
    expect(values(interleave([Float32Array.from([1, 2, 3]), Float32Array.from([-1, -2, -3])]))).toEqual([1, -1, 2, -2, 3, -3]);
  });

  it("プレーナへ戻す（チャンネル数を指定する）", () => {
    const planar = deinterleave(Float32Array.from([1, -1, 2, -2, 3, -3]), 2);

    expect(planar.map(values)).toEqual([
      [1, 2, 3],
      [-1, -2, -3],
    ]);
  });

  it("往復で元に戻る（ランダムな 2 チャンネル・1 チャンネル・3 チャンネル）", () => {
    const random = seededRandom(5);
    for (const channelCount of [1, 2, 3]) {
      const planar = Array.from({ length: channelCount }, () => Float32Array.from({ length: 257 }, () => random() * 2 - 1));

      const roundTrip = deinterleave(interleave(planar), channelCount);

      expect(roundTrip.map(values)).toEqual(planar.map(values));
    }
  });

  it("書き込み先を渡すと、そこへ書き、同じ配列を返す（新しく作らない）", () => {
    const target = new Float32Array(4);

    const result = interleave([Float32Array.from([1, 2]), Float32Array.from([3, 4])], target);

    expect(result).toBe(target);
    expect(values(target)).toEqual([1, 3, 2, 4]);
  });

  it("空のブロック（0 サンプル）は、空の結果", () => {
    expect(interleave([new Float32Array(0), new Float32Array(0)]).length).toBe(0);
    expect(deinterleave(new Float32Array(0), 2).map((channel) => channel.length)).toEqual([0, 0]);
  });

  it("チャンネルの長さがそろわない・書き込み先の長さが違う・割り切れない・チャンネル数が不正は RangeError", () => {
    expect(() => interleave([new Float32Array(2), new Float32Array(3)])).toThrow(RangeError);
    expect(() => interleave([new Float32Array(2), new Float32Array(2)], new Float32Array(3))).toThrow(RangeError);
    expect(() => interleave([])).toThrow(RangeError);
    expect(() => deinterleave(new Float32Array(5), 2)).toThrow(RangeError);
    expect(() => deinterleave(new Float32Array(4), 0)).toThrow(RangeError);
    expect(() => deinterleave(new Float32Array(4), 1.5)).toThrow(RangeError);
  });
});
