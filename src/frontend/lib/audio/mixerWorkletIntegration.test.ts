/**
 * @jest-environment node
 */
// AudioMixer（TypeScript）と Worklet（public/worklets/stream-mixer-processor.js）の、メッセージの取り決めの結合。
// AudioMixer が Worklet のノードへ送るコマンドと設定（processorOptions）を、実物の Worklet のプロセッサ（疑似の AudioWorkletGlobalScope で実行）へ渡し、
// プロセッサが送るメッセージ（ブロック・拒否）を、AudioMixer の側へ届ける。どちらか一方の取り決めが変わると、ここで失敗する。
//
// モックの境界: AudioContext・AudioWorkletNode・MessagePort は疑似（test-support.ts・worklet-harness.ts）。Worklet のコードは、実物のファイルをそのまま実行する。
// 実ブラウザでの確認は、test/ の実機の確認（Playwright の Chromium）。
import { seededRandom } from "@/core/testing/helpers";
import { AudioMixer } from "./AudioMixer";
import type { AudioMixerFault } from "./AudioMixer";
import { DEFAULT_MIXER_GAINS, MIXER_INPUT_KINDS } from "./config";
import { createMixerParameters, createMixerState, interleave, mixBlock, setTargetGain } from "./MixerCore";
import { FakeAudioEnvironment } from "./test-support";
import type { FakeWorkletNode } from "./test-support";
import type { MixedAudioBlock } from "./workletProtocol";
import { FakeMessagePort, loadStreamMixerWorklet } from "./worklet-harness";
import type { WorkletProcessorHandle } from "./worklet-harness";

const worklet = loadStreamMixerWorklet();

interface Bridge {
  readonly env: FakeAudioEnvironment;
  readonly mixer: AudioMixer;
  readonly handle: WorkletProcessorHandle;
  readonly blocks: MixedAudioBlock[];
  readonly faults: AudioMixerFault[];
  /** コマンドを Worklet へ渡し、process() を 1 回呼び、Worklet が送ったメッセージを AudioMixer へ届ける */
  pump(inputs?: Float32Array[][]): void;
}

function channels(random: () => number, frames: number, amplitude: number): Float32Array[] {
  return [0, 1].map(() => Float32Array.from({ length: frames }, () => (random() * 2 - 1) * amplitude));
}

/** AudioMixer を開始し、そのノードに、実物の Worklet のプロセッサをつなぐ。 */
async function startedBridge(sink?: FakeMessagePort): Promise<Bridge> {
  const env = new FakeAudioEnvironment();
  const blocks: MixedAudioBlock[] = [];
  const faults: AudioMixerFault[] = [];
  const mixer = new AudioMixer({ environment: env.asEnvironment(), onListenerError: (error) => faults.push({ code: "processor_error", detail: String(error) }) });
  mixer.subscribe({ onBlock: (block) => blocks.push(block), onFault: (fault) => faults.push(fault) });
  await mixer.start(sink === undefined ? {} : { sink: sink as unknown as MessagePort });
  const node: FakeWorkletNode = env.node;
  // AudioMixer が渡した設定を、そのまま、Worklet のプロセッサの作成へ渡す（Worklet が受け付けること自体が、取り決めの確認）
  const handle = worklet.create((node.options as { processorOptions: unknown }).processorOptions);

  let forwarded = 0;
  let delivered = 0;
  const pump = (inputs: Float32Array[][] = [[], []]): void => {
    for (const message of node.port.posted.slice(forwarded)) {
      handle.command(message.data, message.transfer);
    }
    forwarded = node.port.posted.length;
    handle.process(inputs);
    for (const message of handle.port.posted.slice(delivered)) {
      node.port.receive(message.data);
    }
    delivered = handle.port.posted.length;
  };
  return { env, mixer, handle, blocks, faults, pump };
}

describe("AudioMixer と Worklet の取り決め", () => {
  it("AudioMixer が渡した設定（processorOptions）を、Worklet のプロセッサが受け付ける（係数・音量・チャンネル数・上限）", async () => {
    const bridge = await startedBridge();

    expect(bridge.faults).toEqual([]);
    expect(bridge.handle.port.posted).toEqual([]);
  });

  it("開始のコマンドを受けて、ブロックが流れ始める。ソースが 1 つも無くても、無音のブロックが、1 回も欠かさず、AudioMixer の購読者へ届く", async () => {
    const bridge = await startedBridge();

    for (let call = 0; call < 1000; call += 1) {
      bridge.pump();
    }

    expect(bridge.faults).toEqual([]);
    expect(bridge.blocks).toHaveLength(1000);
    const broken = bridge.blocks.filter((block, index) => block.firstSample !== index * 128 || block.frames !== 128 || !Array.from(block.pcm).every((sample) => Object.is(sample, 0)));
    expect(broken).toEqual([]);
  });

  it("ソースがあるとき、ブロックの内容は、MixerCore（マイク × 1 + 共有音声 × 0.6）と一致する", async () => {
    const bridge = await startedBridge();
    const random = seededRandom(31);
    const reference = createMixerState(MIXER_INPUT_KINDS.map((kind) => DEFAULT_MIXER_GAINS[kind]));
    const parameters = createMixerParameters();
    const mismatches: number[] = [];

    for (let call = 0; call < 200; call += 1) {
      const inputs = [channels(random, 128, 0.9), channels(random, 128, 0.9)];
      bridge.pump(inputs);
      const expected = [new Float32Array(128), new Float32Array(128)];
      mixBlock(parameters, reference, inputs, expected);
      const actual = bridge.blocks[call];
      if (JSON.stringify(Array.from(actual.pcm)) !== JSON.stringify(Array.from(interleave(expected)))) {
        mismatches.push(call);
      }
    }

    expect(mismatches).toEqual([]);
    expect(bridge.faults).toEqual([]);
  });

  it("setGain のコマンドを、Worklet が受け付け（拒否しない）、出力に反映される（MixerCore に同じ変更をしたものと一致）", async () => {
    const bridge = await startedBridge();
    const random = seededRandom(32);
    const parameters = createMixerParameters();
    const reference = createMixerState(MIXER_INPUT_KINDS.map((kind) => DEFAULT_MIXER_GAINS[kind]));
    const firstInputs = [channels(random, 128, 0.5), channels(random, 128, 0.5)];
    const secondInputs = [channels(random, 128, 0.5), channels(random, 128, 0.5)];

    bridge.pump(firstInputs);
    mixBlock(parameters, reference, firstInputs, [new Float32Array(128), new Float32Array(128)]);
    bridge.mixer.setGain("shared_audio", 0.1);
    bridge.mixer.setGain("microphone", 1.5);
    setTargetGain(reference, 1, 0.1);
    setTargetGain(reference, 0, 1.5);
    bridge.pump(secondInputs);
    const expected = [new Float32Array(128), new Float32Array(128)];
    mixBlock(parameters, reference, secondInputs, expected);

    expect(bridge.faults).toEqual([]);
    expect(Array.from(bridge.blocks[1].pcm)).toEqual(Array.from(interleave(expected)));
  });

  it("sink（MessagePort）を渡すと、ブロックは sink へ届く。AudioMixer の購読者へは、届かない", async () => {
    const sink = new FakeMessagePort();
    const bridge = await startedBridge(sink);

    bridge.pump();
    bridge.pump();

    const received = sink.posted.map((message) => message.data as { type: string; firstSample: number });
    expect(received.map((message) => [message.type, message.firstSample])).toEqual([
      ["block", 0],
      ["block", 128],
    ]);
    expect(bridge.blocks).toEqual([]);
  });

  it("Worklet が拒否した不正なコマンドは、AudioMixer が、障害（command_rejected）として受け取る（拒否の形の取り決め）", async () => {
    const bridge = await startedBridge();
    bridge.pump();

    bridge.handle.command({ type: "gain", index: 7, value: 1 });
    bridge.handle.command({ type: "unknown" });
    for (const message of bridge.handle.port.posted) {
      bridge.env.node.port.receive(message.data);
    }

    expect(bridge.faults).toEqual([
      { code: "command_rejected", detail: "gain:invalid_index" },
      { code: "command_rejected", detail: "unknown:unknown_command" },
    ]);
  });

  it("AudioMixer が送るコマンドは、Worklet に、1 件も拒否されない（開始・音量の境界値）", async () => {
    const bridge = await startedBridge();

    bridge.mixer.setGain("microphone", 0);
    bridge.mixer.setGain("shared_audio", 4);
    bridge.pump();

    expect(bridge.faults).toEqual([]);
    expect(bridge.blocks).toHaveLength(1);
  });
});
