/**
 * @jest-environment node
 */
// AudioWorklet のプロセッサ（public/worklets/stream-mixer-processor.js）。
//   1. Worklet の数値処理と MixerCore が一致すること（同じ入力で、1 ビットも違わない）。Worklet のファイルを、疑似の AudioWorkletGlobalScope
//      （worklet-harness.ts。Node の vm）で実行して、MixerCore の出力と比較する
//   2. 音声の処理周期（process() の呼び出し 1 回）ごとに、PCM のブロックと累積サンプル数を、メッセージポートで送ること。
//      ソースの有無にかかわらず止まらず、連続すること（無音のブロックを含む）
//   3. 不正なコマンドで、例外を投げず（投げると、プロセッサが止まる）、拒否を通知して処理を続けること
//
// モックの境界: AudioWorkletGlobalScope・AudioWorkletProcessor・MessagePort は疑似。Worklet のコードは、実物のファイルをそのまま実行する。
// 実ブラウザでの確認は、test/ の実機の確認（Playwright の Chromium）が行う。
import { Problems, seededRandom } from "@/core/testing/helpers";
import { DEFAULT_MIXER_GAINS, MIXER_GAIN_MAX, MIXER_INPUT_KINDS, MIXER_PROCESSOR_NAME } from "./config";
import { GAIN_SNAP_EPSILON, createMixerParameters, createMixerState, interleave, mixBlock, setTargetGain } from "./MixerCore";
import { FakeMessagePort, loadStreamMixerWorklet } from "./worklet-harness";
import type { WorkletProcessorHandle } from "./worklet-harness";

const worklet = loadStreamMixerWorklet();

function defaultGains(): number[] {
  return MIXER_INPUT_KINDS.map((kind) => DEFAULT_MIXER_GAINS[kind]);
}

function processorOptions(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return { ...createMixerParameters(), gains: defaultGains(), ...overrides };
}

interface BlockMessage {
  readonly type: "block";
  readonly firstSample: number;
  readonly frames: number;
  readonly pcm: ArrayLike<number> & { readonly buffer: unknown };
}

function blocksOf(port: FakeMessagePort): BlockMessage[] {
  return port.posted.map((message) => message.data as { type?: unknown }).filter((data): data is BlockMessage => data.type === "block");
}

function rejectionsOf(port: FakeMessagePort): { type: string; command: unknown; reason: string }[] {
  return port.posted.map((message) => message.data as { type?: unknown }).filter((data): data is { type: string; command: unknown; reason: string } => data.type === "rejected");
}

function startedProcessor(overrides: Record<string, unknown> = {}): { handle: WorkletProcessorHandle; sink: FakeMessagePort } {
  const handle = worklet.create(processorOptions(overrides));
  const sink = new FakeMessagePort();
  handle.command({ type: "start" }, [sink]);
  return { handle, sink };
}

function channelBlock(random: () => number, frames: number, amplitude: number, channels: number): Float32Array[] {
  return Array.from({ length: channels }, () => Float32Array.from({ length: frames }, () => (random() * 2 - 1) * amplitude));
}

function same(actual: ArrayLike<number>, expected: ArrayLike<number>): boolean {
  if (actual.length !== expected.length) {
    return false;
  }
  for (let index = 0; index < actual.length; index += 1) {
    if (!Object.is(actual[index], expected[index])) {
      return false;
    }
  }
  return true;
}

describe("読み込み", () => {
  it("プロセッサを、1 つだけ、設定の名前（stream-mixer）で登録する", () => {
    expect(worklet.registrationCount).toBe(1);
    expect(worklet.registeredName).toBe(MIXER_PROCESSOR_NAME);
    expect(MIXER_PROCESSOR_NAME).toBe("stream-mixer");
  });

  it("スナップの閾値が、MixerCore と同じ値（数値処理の定数が、2 か所で食い違わない）", () => {
    const match = /const GAIN_SNAP_EPSILON = ([0-9.e-]+);/.exec(worklet.source);

    expect(match).not.toBeNull();
    expect(Number(match?.[1])).toBe(GAIN_SNAP_EPSILON);
  });

  it("自己完結の 1 つのスクリプト（import・export を持たない。読み込みに、他のファイルを要しない）", () => {
    expect(worklet.source).not.toMatch(/^\s*(import|export)\s/m);
  });
});

describe("開始の前後", () => {
  it("開始の前は、何も送らない（process は true を返し、プロセッサは生き続ける）", () => {
    const handle = worklet.create(processorOptions());

    const results = Array.from({ length: 10 }, () => handle.process([[], []]));

    expect(results.every((result) => result === true)).toBe(true);
    expect(handle.port.posted).toEqual([]);
  });

  it("開始のあと、処理周期ごとに、ブロック（累積サンプル数・サンプル数・PCM）を送る。累積は 0 から、128 ずつ", () => {
    const handle = worklet.create(processorOptions());
    handle.command({ type: "start" });

    for (let call = 0; call < 5; call += 1) {
      expect(handle.process([[], []])).toBe(true);
    }

    const blocks = blocksOf(handle.port);
    expect(blocks.map((block) => block.firstSample)).toEqual([0, 128, 256, 384, 512]);
    expect(blocks.map((block) => block.frames)).toEqual([128, 128, 128, 128, 128]);
    expect(blocks.every((block) => block.pcm.length === 256)).toBe(true);
    expect(Object.keys(handle.port.posted[0].data as object).sort()).toEqual(["firstSample", "frames", "pcm", "type"]);
  });

  it("PCM のバッファは、コピーせず転送する（転送リストに、そのバッファが入っている）", () => {
    const handle = worklet.create(processorOptions());
    handle.command({ type: "start" });

    handle.process([[], []]);

    const [message] = handle.port.posted;
    expect(message.transfer).toEqual([blocksOf(handle.port)[0].pcm.buffer]);
  });

  it("転送された MessagePort を、送り先にする（その場合、メインスレッドの port へは、ブロックを送らない）", () => {
    const { handle, sink } = startedProcessor();

    handle.process([[], []]);
    handle.process([[], []]);

    expect(blocksOf(sink).map((block) => block.firstSample)).toEqual([0, 128]);
    expect(blocksOf(handle.port)).toEqual([]);
  });

  it("サンプル数は、処理周期の長さに従う（64・256・129 サンプルでも、累積が連続する）", () => {
    const handle = worklet.create(processorOptions());
    handle.command({ type: "start" });

    handle.process([[], []], 64);
    handle.process([[], []], 256);
    handle.process([[], []], 129);

    const blocks = blocksOf(handle.port);
    expect(blocks.map((block) => [block.firstSample, block.frames, block.pcm.length])).toEqual([
      [0, 64, 128],
      [64, 256, 512],
      [320, 129, 258],
    ]);
  });

  it("2 回目の開始は拒否する（累積サンプル数を巻き戻さない）", () => {
    const handle = worklet.create(processorOptions());
    handle.command({ type: "start" });
    handle.process([[], []]);
    handle.process([[], []]);

    handle.command({ type: "start" });
    handle.process([[], []]);

    expect(blocksOf(handle.port).map((block) => block.firstSample)).toEqual([0, 128, 256]);
    expect(rejectionsOf(handle.port)).toEqual([{ type: "rejected", command: "start", reason: "already_started" }]);
  });
});

describe("無音（音声ソースが 1 つも無くても、止まらず、途切れない）", () => {
  it("入力がすべて切断（空の配列）でも、2,000 回の処理周期が連続し、すべて無音のブロック", () => {
    const { handle, sink } = startedProcessor();
    const problems = new Problems();

    for (let call = 0; call < 2000; call += 1) {
      if (handle.process([[], []]) !== true) {
        problems.report(`call ${call}: process did not return true`);
      }
    }
    const blocks = blocksOf(sink);

    expect(problems.list()).toEqual([]);
    expect(blocks).toHaveLength(2000);
    for (let index = 0; index < blocks.length; index += 1) {
      if (blocks[index].firstSample !== index * 128 || blocks[index].frames !== 128 || !Array.from(blocks[index].pcm).every((sample) => Object.is(sample, 0))) {
        problems.report(`block ${index}: ${blocks[index].firstSample}`);
      }
    }
    expect(problems.list()).toEqual([]);
  });

  it("入力の配列が足りなくても（空）、無音のブロックを送る", () => {
    const { handle, sink } = startedProcessor();

    expect(handle.process([])).toBe(true);

    expect(blocksOf(sink)).toHaveLength(1);
    expect(Array.from(blocksOf(sink)[0].pcm).every((sample) => Object.is(sample, 0))).toBe(true);
  });
});

describe("MixerCore との一致（同じ入力で、1 ビットも違わない）", () => {
  interface Scenario {
    readonly name: string;
    readonly frames: number;
    readonly blocks: number;
    /** 入力の振幅。ブロック番号から決める関数でもよい */
    readonly amplitude: number | ((block: number) => number);
    /** ブロック番号 -> 入力が接続されているか（マイク・共有音声） */
    readonly connected: (block: number) => readonly [boolean, boolean];
    /** 入力のチャンネル数（Web Audio は、接続された入力に 2 チャンネルを渡す。1 は、モノラルの保険） */
    readonly channels?: number;
    /** ブロック番号 -> そのブロックの前に送る、音量の変更コマンド */
    readonly gainChanges?: Readonly<Record<number, readonly [index: number, value: number]>>;
    /** 入力の点に、NaN・無限大を混ぜる（0 として扱われ、利得の状態を壊さないこと） */
    readonly nonFinite?: boolean;
  }

  const BOTH = (): readonly [boolean, boolean] => [true, true];
  const SCENARIOS: readonly Scenario[] = [
    { name: "マイクと共有音声（通常の音量）", frames: 128, blocks: 400, amplitude: 0.5, connected: BOTH },
    { name: "マイクだけ", frames: 128, blocks: 300, amplitude: 0.7, connected: () => [true, false] },
    { name: "共有音声だけ", frames: 128, blocks: 300, amplitude: 0.7, connected: () => [false, true] },
    { name: "過大な信号（リミッタが働く）", frames: 128, blocks: 400, amplitude: 1.6, connected: BOTH },
    { name: "接続と切断を、ブロックごとに繰り返す（両方とも無いブロックを含む）", frames: 128, blocks: 400, amplitude: 1.1, connected: (block) => [block % 2 === 0, block % 3 === 0] },
    {
      name: "音量の変更（共有音声を 0.1、マイクを 2.0 へ。途中のブロックで）",
      frames: 128,
      blocks: 400,
      amplitude: 0.9,
      connected: BOTH,
      gainChanges: { 50: [1, 0.1], 120: [0, 2], 300: [1, 0] },
    },
    { name: "処理周期が 64 サンプル", frames: 64, blocks: 400, amplitude: 1.3, connected: BOTH },
    { name: "処理周期が 256 サンプル", frames: 256, blocks: 200, amplitude: 1.3, connected: BOTH },
    { name: "処理周期が 129 サンプル（128 の倍数でない）", frames: 129, blocks: 200, amplitude: 1.3, connected: BOTH },
    { name: "モノラルの入力（1 チャンネル）", frames: 128, blocks: 200, amplitude: 1.2, connected: BOTH, channels: 1 },
    { name: "NaN・無限大を含む入力（0 として扱う。出力は有限で、状態を壊さない）", frames: 128, blocks: 200, amplitude: 1.2, connected: BOTH, nonFinite: true },
    {
      name: "過大な信号のあと、静かな信号が 10 万サンプル以上続く（リミッタの利得が、ちょうど 1 へ戻る。戻ったあとも一致）",
      frames: 128,
      blocks: 1000,
      amplitude: (block) => (block < 20 ? 2 : 0.1),
      connected: BOTH,
    },
  ];

  it.each(SCENARIOS)("$name", (scenario) => {
    const random = seededRandom(1000 + scenario.frames + scenario.blocks);
    const { handle, sink } = startedProcessor();
    const parameters = createMixerParameters();
    const reference = createMixerState(defaultGains());
    const problems = new Problems();
    const channels = scenario.channels ?? 2;

    for (let block = 0; block < scenario.blocks; block += 1) {
      const change = scenario.gainChanges?.[block];
      if (change !== undefined) {
        handle.command({ type: "gain", index: change[0], value: change[1] });
        setTargetGain(reference, change[0], change[1]);
      }
      const [micConnected, sharedConnected] = scenario.connected(block);
      const amplitude = typeof scenario.amplitude === "function" ? scenario.amplitude(block) : scenario.amplitude;
      const inputs = [micConnected ? channelBlock(random, scenario.frames, amplitude, channels) : [], sharedConnected ? channelBlock(random, scenario.frames, amplitude, channels) : []];
      if (scenario.nonFinite === true) {
        for (const input of inputs) {
          if (input.length > 0) {
            input[0][3] = Number.NaN;
            input[input.length - 1][7] = Number.POSITIVE_INFINITY;
            input[0][9] = Number.NEGATIVE_INFINITY;
          }
        }
      }

      handle.process(inputs, scenario.frames);
      const expectedPlanar = [new Float32Array(scenario.frames), new Float32Array(scenario.frames)];
      mixBlock(parameters, reference, inputs, expectedPlanar);
      const actual = blocksOf(sink)[block];

      if (actual === undefined) {
        problems.report(`block ${block}: no message`);
      } else if (actual.firstSample !== block * scenario.frames || actual.frames !== scenario.frames) {
        problems.report(`block ${block}: firstSample ${actual.firstSample}, frames ${actual.frames}`);
      } else if (!same(actual.pcm, interleave(expectedPlanar))) {
        problems.report(`block ${block}: pcm differs from MixerCore`);
      } else if (scenario.nonFinite === true && !Array.from(actual.pcm).every((sample) => Number.isFinite(sample))) {
        problems.report(`block ${block}: pcm is not finite`);
      }
    }

    expect(problems.list()).toEqual([]);
    expect(blocksOf(sink)).toHaveLength(scenario.blocks);
  });

  it("開始の前に受けた音量の変更も、開始後の出力に反映される（MixerCore に同じ変更をしたものと一致。目標へなだらかに近づく）", () => {
    const random = seededRandom(77);
    const handle = worklet.create(processorOptions());
    handle.command({ type: "gain", index: 1, value: 0 });
    handle.command({ type: "start" });
    const inputs = [channelBlock(random, 128, 0.5, 2), channelBlock(random, 128, 0.5, 2)];

    handle.process(inputs);

    const reference = createMixerState(defaultGains());
    setTargetGain(reference, 1, 0);
    const expected = [new Float32Array(128), new Float32Array(128)];
    mixBlock(createMixerParameters(), reference, inputs, expected);
    expect(same(blocksOf(handle.port)[0].pcm, interleave(expected))).toBe(true);
    expect(reference.gains[1]).toBeLessThan(0.6);
  });
});

describe("コマンドの検査（不正なコマンドで例外を投げない。拒否を通知して、処理を続ける）", () => {
  it.each([
    ["null", null, null, "malformed"],
    ["数値", 5, null, "malformed"],
    ["文字列", "gain", null, "malformed"],
    ["type が無い", {}, null, "malformed"],
    ["type が文字列でない", { type: 1 }, null, "malformed"],
    ["未知の type", { type: "stop" }, "stop", "unknown_command"],
    ["gain: index が負", { type: "gain", index: -1, value: 0.5 }, "gain", "invalid_index"],
    ["gain: index が範囲外", { type: "gain", index: 2, value: 0.5 }, "gain", "invalid_index"],
    ["gain: index が小数", { type: "gain", index: 1.5, value: 0.5 }, "gain", "invalid_index"],
    ["gain: index が文字列", { type: "gain", index: "0", value: 0.5 }, "gain", "invalid_index"],
    ["gain: index が無い", { type: "gain", value: 0.5 }, "gain", "invalid_index"],
    ["gain: value が NaN", { type: "gain", index: 0, value: Number.NaN }, "gain", "invalid_value"],
    ["gain: value が負", { type: "gain", index: 0, value: -0.1 }, "gain", "invalid_value"],
    ["gain: value が無限大", { type: "gain", index: 0, value: Number.POSITIVE_INFINITY }, "gain", "invalid_value"],
    ["gain: value が上限超え", { type: "gain", index: 0, value: MIXER_GAIN_MAX + 0.01 }, "gain", "invalid_value"],
    ["gain: value が文字列", { type: "gain", index: 0, value: "1" }, "gain", "invalid_value"],
    ["gain: value が無い", { type: "gain", index: 0 }, "gain", "invalid_value"],
  ])("%s", (_name, command, expectedCommand, expectedReason) => {
    const { handle, sink } = startedProcessor();

    expect(() => handle.command(command)).not.toThrow();

    expect(rejectionsOf(handle.port)).toEqual([{ type: "rejected", command: expectedCommand, reason: expectedReason }]);
    expect(handle.process([[], []])).toBe(true);
    expect(blocksOf(sink)).toHaveLength(1);
  });

  it("拒否したコマンドは、音量を変えない（不正な gain のあとも、出力は、変更前のまま）", () => {
    const random = seededRandom(5);
    const { handle, sink } = startedProcessor();
    handle.command({ type: "gain", index: 0, value: Number.NaN });
    handle.command({ type: "gain", index: 9, value: 0 });
    const inputs = [channelBlock(random, 128, 0.4, 2), channelBlock(random, 128, 0.4, 2)];

    handle.process(inputs);

    const expected = [new Float32Array(128), new Float32Array(128)];
    mixBlock(createMixerParameters(), createMixerState(defaultGains()), inputs, expected);
    expect(same(blocksOf(sink)[0].pcm, interleave(expected))).toBe(true);
  });

  it("音量の上限ちょうど・0 は、受け付ける", () => {
    const { handle } = startedProcessor();

    handle.command({ type: "gain", index: 0, value: 0 });
    handle.command({ type: "gain", index: 1, value: MIXER_GAIN_MAX });

    expect(rejectionsOf(handle.port)).toEqual([]);
  });
});

describe("プロセッサの作成時の検査（不正な設定で、推測した値のまま続けない）", () => {
  const BASE = processorOptions();

  it.each([
    ["processorOptions が無い", undefined],
    ["processorOptions がオブジェクトでない", 5],
    ["gains が無い", { ...BASE, gains: undefined }],
    ["gains が配列でない", { ...BASE, gains: "1,0.6" }],
    ["gains が空", { ...BASE, gains: [] }],
    ["gains に NaN", { ...BASE, gains: [1, Number.NaN] }],
    ["gains が負", { ...BASE, gains: [-1, 0.6] }],
    ["gains が上限超え", { ...BASE, gains: [1, MIXER_GAIN_MAX + 1] }],
    ["ceiling が 0", { ...BASE, ceiling: 0 }],
    ["ceiling が NaN", { ...BASE, ceiling: Number.NaN }],
    ["limiterReleaseCoefficient が 0", { ...BASE, limiterReleaseCoefficient: 0 }],
    ["limiterReleaseCoefficient が 1 を超える", { ...BASE, limiterReleaseCoefficient: 1.5 }],
    ["limiterReleaseCoefficient が NaN", { ...BASE, limiterReleaseCoefficient: Number.NaN }],
    ["gainSmoothingCoefficient が 0", { ...BASE, gainSmoothingCoefficient: 0 }],
    ["gainSmoothingCoefficient が 1 を超える", { ...BASE, gainSmoothingCoefficient: 2 }],
    ["channelCount が 2 でない", { ...BASE, channelCount: 1 }],
    ["gainMax が 0 以下", { ...BASE, gainMax: 0 }],
  ])("%s は、例外", (_name, options) => {
    expect(() => worklet.create(options)).toThrow();
  });

  it("正しい設定なら、作れる（上の検査が、すべてを拒否しているのではない）", () => {
    expect(() => worklet.create(BASE)).not.toThrow();
  });
});
