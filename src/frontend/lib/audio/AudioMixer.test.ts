// AudioMixer（requirements.md 11.2・11.5・11.6・13.1。issue #26）。AudioContext 上の AudioWorklet で、マイクと共有音声を混合する。
//   - AudioContext は、サンプリング周波数 44,100 Hz。開始の操作（クリック）の中で resume する。Worklet は、ソースの有無にかかわらず止まらない
//   - グラフ: マイク -> ミキサー（入力 0）・共有音声 -> ミキサー（入力 1）。ミキサーの出力は、出力先（destination）へつながない
//     （配信者自身への音声の折り返し再生をしない。出力は、ノードが処理され続けるための、終端のノードだけへ）
//   - 処理周期ごとに、PCM のブロックと累積サンプル数を、メッセージポートで送る（購読者へ、または転送した MessagePort へ）
//   - AudioContext の停止（suspended・interrupted・端末の休止）で onStall、再開で onResume
//
// モックの境界: AudioContext・AudioWorkletNode・各ノード・MessagePort・タイマは疑似（test-support.ts）。接続と呼び出しの順序を検査する。
// 数値処理は、Worklet のファイルを疑似のスコープで実行するテスト（streamMixerProcessor.test.ts）が保証する。実ブラウザの確認は、test/ の実機の確認。
import { FakeTrack, flushPromises } from "@/lib/sources/test-support";
import { AudioMixer } from "./AudioMixer";
import type { AudioMixerFault, AudioMixerOptions } from "./AudioMixer";
import { DEFAULT_MIXER_GAINS, MIXER_GAIN_MAX, MIXER_INPUT_KINDS, MIXER_PROCESSOR_NAME, MIXER_SAMPLE_RATE_HZ, MIXER_START_TIMEOUT_MS, MIXER_WORKLET_MODULE_URL } from "./config";
import type { MixerInputKind } from "./config";
import { AudioMixerError } from "./errors";
import { createMixerParameters } from "./MixerCore";
import { FakeAudioEnvironment } from "./test-support";
import type { FakeContextBehavior } from "./test-support";
import type { MixedAudioBlock } from "./workletProtocol";

interface Harness {
  readonly mixer: AudioMixer;
  readonly env: FakeAudioEnvironment;
  readonly events: string[];
  readonly blocks: MixedAudioBlock[];
  readonly faults: AudioMixerFault[];
  readonly errors: unknown[];
  readonly diagnostics: { event: string; fields: Record<string, unknown> }[];
}

function createHarness(behavior: FakeContextBehavior = {}, mixerOptions: Partial<AudioMixerOptions> = {}): Harness {
  const env = new FakeAudioEnvironment();
  env.behavior = behavior;
  const events: string[] = [];
  const blocks: MixedAudioBlock[] = [];
  const faults: AudioMixerFault[] = [];
  const errors: unknown[] = [];
  const diagnostics: { event: string; fields: Record<string, unknown> }[] = [];
  const mixer = new AudioMixer({
    environment: env.asEnvironment(),
    onListenerError: (error) => errors.push(error),
    onDiagnostic: (event, fields) => diagnostics.push({ event, fields }),
    ...mixerOptions,
  });
  mixer.subscribe({
    onBlock: (block) => blocks.push(block),
    onStall: () => events.push("stall"),
    onResume: () => events.push("resume"),
    onFault: (fault) => faults.push(fault),
  });
  return { mixer, env, events, blocks, faults, errors, diagnostics };
}

async function startedHarness(behavior: FakeContextBehavior = {}, mixerOptions: Partial<AudioMixerOptions> = {}): Promise<Harness> {
  const harness = createHarness(behavior, mixerOptions);
  await harness.mixer.start();
  return harness;
}

/** 失敗するはずの Promise を待ち、拒否の理由を返す（成功したら null）。 */
function outcomeOf(promise: Promise<unknown>): Promise<unknown> {
  return promise.then(
    () => null,
    (error: unknown) => error,
  );
}

function errorCodeOf(error: unknown): string | null {
  return error instanceof AudioMixerError ? error.code : null;
}

function audioTrack(label = "LABEL-microphone"): FakeTrack {
  return new FakeTrack("audio", { label });
}

describe("開始（start）", () => {
  it("AudioContext を 44,100 Hz で作り、resume と addModule を、呼び出しの中（await の前）で同期的に呼ぶ（開始のクリックの中で resume する）", async () => {
    const harness = createHarness();

    const starting = harness.mixer.start();

    expect(harness.env.contextOptions).toEqual([{ sampleRate: 44_100 }]);
    expect(MIXER_SAMPLE_RATE_HZ).toBe(44_100);
    expect(harness.env.context.callLog).toEqual(["resume", `addModule:${MIXER_WORKLET_MODULE_URL}`]);
    await starting;
  });

  it("状態は、idle -> starting -> running", async () => {
    const harness = createHarness();
    expect(harness.mixer.status).toBe("idle");

    const starting = harness.mixer.start();
    expect(harness.mixer.status).toBe("starting");
    await starting;

    expect(harness.mixer.status).toBe("running");
  });

  it("Worklet のノードを、設定の名前で、2 入力（マイク・共有音声）・1 出力（2 チャンネル）・明示の 2 チャンネル（スピーカー解釈）で作る。設定は processorOptions", async () => {
    const harness = await startedHarness();

    expect(harness.env.workletNodes).toHaveLength(1);
    expect(harness.env.node.name).toBe(MIXER_PROCESSOR_NAME);
    expect(harness.env.node.options).toEqual({
      numberOfInputs: 2,
      numberOfOutputs: 1,
      outputChannelCount: [2],
      channelCount: 2,
      channelCountMode: "explicit",
      channelInterpretation: "speakers",
      processorOptions: { ...createMixerParameters(), gains: [1, 0.6] },
    });
  });

  it("ミキサーの出力は、終端のノード（MediaStreamAudioDestinationNode）へだけつなぐ。出力先（destination）へは、どのノードからも、つながっていない", async () => {
    const harness = await startedHarness();
    harness.mixer.addSource("microphone", audioTrack().asTrack());
    harness.mixer.addSource("shared_audio", audioTrack().asTrack());

    expect(harness.env.context.sinks).toHaveLength(1);
    expect(harness.env.node.connections).toEqual([{ destination: harness.env.context.sinks[0], output: undefined, input: undefined }]);
    expect(harness.env.connectionsInto(harness.env.context.destination)).toEqual([]);
  });

  it("開始のコマンド（{type: start}）を 1 回送る。転送する MessagePort は無い（ブロックは、メインスレッドへ届く）", async () => {
    const harness = await startedHarness();

    expect(harness.env.node.port.posted).toEqual([{ data: { type: "start" }, transfer: [] }]);
  });

  it("sink（MessagePort）を渡すと、開始のコマンドで Worklet へ転送する（ブロックは、そのポート（配信パイプラインのワーカー）へ直接届く）", async () => {
    const harness = createHarness();
    const sink = { kind: "fake-message-port" } as unknown as MessagePort;

    await harness.mixer.start({ sink });

    expect(harness.env.node.port.posted).toEqual([{ data: { type: "start" }, transfer: [sink] }]);
  });

  it("開始のあと、購読者へ、状態の変化（停止・再開）は通知されない（開始そのものは、呼び出し元が知っている）", async () => {
    const harness = await startedHarness();

    expect(harness.events).toEqual([]);
    expect(harness.faults).toEqual([]);
  });

  describe("開始の失敗（失敗したら、AudioContext を閉じ、idle へ戻る。もう一度 start できる）", () => {
    async function expectFailure(harness: Harness, code: string): Promise<AudioMixerError> {
      const error = await outcomeOf(harness.mixer.start());

      expect(errorCodeOf(error)).toBe(code);
      expect(harness.mixer.status).toBe("idle");
      expect(harness.env.context.closeCount).toBe(1);
      return error as AudioMixerError;
    }

    it("AudioContext が 44,100 Hz で作られなかった（別の周波数のまま続けない）: sample_rate_unsupported。resume・addModule は呼ばない", async () => {
      const harness = createHarness({ sampleRate: 48_000 });

      await expectFailure(harness, "sample_rate_unsupported");

      expect(harness.env.context.callLog).toEqual(["close"]);
      expect(harness.env.workletNodes).toEqual([]);
    });

    it("AudioContext の作成が NotSupportedError: sample_rate_unsupported（その周波数を指定できない環境）。想定外のエラーは unexpected", async () => {
      const unsupported = createHarness();
      unsupported.env.contextError = new DOMException("x", "NotSupportedError");
      const unexpected = createHarness();
      unexpected.env.contextError = new TypeError("x");

      expect(errorCodeOf(await outcomeOf(unsupported.mixer.start()))).toBe("sample_rate_unsupported");
      expect(errorCodeOf(await outcomeOf(unexpected.mixer.start()))).toBe("unexpected");
      expect(unsupported.mixer.status).toBe("idle");
      expect(unexpected.mixer.status).toBe("idle");
    });

    it("AudioWorklet が無い環境（セキュアでない文脈）: unsupported", async () => {
      const harness = createHarness({ withoutAudioWorklet: true });

      await expectFailure(harness, "unsupported");
    });

    it("Worklet のモジュールを読み込めない: worklet_load_failed。エラーの文面を、メッセージに含めない。ノードは作らない", async () => {
      const harness = createHarness({ addModule: "reject" });

      const error = await expectFailure(harness, "worklet_load_failed");

      expect(error.message).not.toContain("LABEL-SECRET-MODULE");
      expect(harness.env.workletNodes).toEqual([]);
    });

    it("Worklet のノードを作れない: worklet_create_failed", async () => {
      const harness = createHarness();
      harness.env.workletNodeError = new DOMException("processor not registered", "InvalidStateError");

      await expectFailure(harness, "worklet_create_failed");
    });

    it("resume が、解決も拒否もしない（自動再生の制限で止まったまま）: 待ち時間の上限で、context_not_running。タイマは後始末される", async () => {
      const harness = createHarness({ resume: "blocked" });

      const failure = outcomeOf(harness.mixer.start());
      await flushPromises();
      expect(harness.env.pendingTimerDelays).toEqual([MIXER_START_TIMEOUT_MS]);
      harness.env.fireTimers();
      const error = await failure;

      expect(errorCodeOf(error)).toBe("context_not_running");
      expect(harness.mixer.status).toBe("idle");
      expect(harness.env.context.closeCount).toBe(1);
      expect(harness.env.pendingTimerCount).toBe(0);
    });

    it("待ち時間の上限は、設定で変えられる", async () => {
      const harness = createHarness({ resume: "blocked" }, { startTimeoutMs: 1234 });

      const failure = outcomeOf(harness.mixer.start());
      await flushPromises();

      expect(harness.env.pendingTimerDelays).toEqual([1234]);
      harness.env.fireTimers();
      await failure;
    });

    it("resume は解決したが、実行状態でない: context_not_running。タイマは後始末される", async () => {
      const harness = createHarness({ resume: "stay_suspended" });

      await expectFailure(harness, "context_not_running");

      expect(harness.env.pendingTimerCount).toBe(0);
    });

    it("resume が拒否された: context_not_running（元のエラーは cause）", async () => {
      const harness = createHarness({ resume: "reject" });

      const error = await expectFailure(harness, "context_not_running");

      expect((error.cause as { name: string }).name).toBe("InvalidStateError");
    });

    it("addModule が失敗したあとの resume の拒否を、未処理の拒否にしない", async () => {
      const harness = createHarness({ addModule: "reject", resume: "reject" });

      await expectFailure(harness, "worklet_load_failed");
      await flushPromises();
    });

    it("失敗したあと、もう一度 start できる（新しい AudioContext）", async () => {
      const harness = createHarness({ addModule: "reject" });
      await outcomeOf(harness.mixer.start());
      harness.env.behavior = {};

      await harness.mixer.start();

      expect(harness.env.contexts).toHaveLength(2);
      expect(harness.mixer.status).toBe("running");
    });
  });

  it("開始中・実行中の start は、invalid_state（二重に開始しない）", async () => {
    const harness = createHarness();
    const first = harness.mixer.start();

    expect(errorCodeOf(await outcomeOf(harness.mixer.start()))).toBe("invalid_state");
    await first;
    expect(errorCodeOf(await outcomeOf(harness.mixer.start()))).toBe("invalid_state");
    expect(harness.env.contexts).toHaveLength(1);
  });

  it("開始の途中で stop すると、start は aborted で失敗し、AudioContext は 1 回だけ閉じる。ノードは作らない", async () => {
    const harness = createHarness({ addModule: "pending" });
    const failure = outcomeOf(harness.mixer.start());
    await flushPromises();

    const stopping = harness.mixer.stop();
    harness.env.context.addModuleControl.resolve();
    const error = await failure;
    await stopping;

    expect(errorCodeOf(error)).toBe("aborted");
    expect(harness.env.workletNodes).toEqual([]);
    expect(harness.env.context.closeCount).toBe(1);
    expect(harness.mixer.status).toBe("stopped");
  });
});

describe("停止（stop）", () => {
  it("ソースとノードを外し、AudioContext を閉じる。イベントの購読を解除する。以後のメッセージ・状態の変化は無視する", async () => {
    const harness = await startedHarness();
    harness.mixer.addSource("microphone", audioTrack().asTrack());
    const context = harness.env.context;
    const node = harness.env.node;
    const source = context.sources[0];

    await harness.mixer.stop();

    expect(harness.mixer.status).toBe("stopped");
    expect(context.closeCount).toBe(1);
    expect(source.disconnectCount).toBe(1);
    expect(node.disconnectCount).toBe(1);
    expect(node.processorErrorListenerCount).toBe(0);
    expect(node.port.onmessage).toBeNull();
    context.setState("suspended");
    node.failProcessor();
    expect(harness.events).toEqual([]);
    expect(harness.faults).toEqual([]);
  });

  it("停止は、何度呼んでもよい。開始前の stop も、何も起こさない", async () => {
    const harness = createHarness();

    await harness.mixer.stop();
    await harness.mixer.start();
    await harness.mixer.stop();
    await harness.mixer.stop();

    expect(harness.env.context.closeCount).toBe(1);
  });

  it("停止のあと、再び start できる（新しい AudioContext・Worklet。登録していたソースは、つなぎ直される。音量も保たれる）", async () => {
    const harness = await startedHarness();
    const mic = audioTrack();
    harness.mixer.addSource("microphone", mic.asTrack());
    harness.mixer.setGain("shared_audio", 0.3);
    await harness.mixer.stop();

    await harness.mixer.start();

    expect(harness.env.contexts).toHaveLength(2);
    expect(harness.env.workletNodes).toHaveLength(2);
    expect(harness.env.contexts[1].sources).toHaveLength(1);
    expect(harness.env.contexts[1].sources[0].connections).toEqual([{ destination: harness.env.node, output: 0, input: 0 }]);
    expect((harness.env.node.options.processorOptions as { gains: number[] }).gains).toEqual([1, 0.3]);
    expect(harness.mixer.status).toBe("running");
  });
});

describe("ソースの追加・解除（配信中にも行える。ストリームを再生成しない）", () => {
  it("マイクは入力 0、共有音声は入力 1 へつなぐ（ストリームは、そのトラックだけ）。出力先（destination）へは、つながない", async () => {
    const harness = await startedHarness();
    const mic = audioTrack("LABEL-mic");
    const shared = audioTrack("LABEL-shared");

    harness.mixer.addSource("microphone", mic.asTrack());
    harness.mixer.addSource("shared_audio", shared.asTrack());

    const [micSource, sharedSource] = harness.env.context.sources;
    expect(micSource.stream.tracks).toEqual([mic]);
    expect(sharedSource.stream.tracks).toEqual([shared]);
    expect(micSource.connections).toEqual([{ destination: harness.env.node, output: 0, input: 0 }]);
    expect(sharedSource.connections).toEqual([{ destination: harness.env.node, output: 0, input: 1 }]);
    expect(harness.env.connectionsInto(harness.env.context.destination)).toEqual([]);
    expect(harness.mixer.hasSource("microphone")).toBe(true);
    expect(harness.mixer.hasSource("shared_audio")).toBe(true);
  });

  it("開始の前に加えたソースは、開始のときにつなぐ", async () => {
    const harness = createHarness();
    const mic = audioTrack();
    harness.mixer.addSource("microphone", mic.asTrack());
    expect(harness.mixer.hasSource("microphone")).toBe(true);

    await harness.mixer.start();

    expect(harness.env.context.sources).toHaveLength(1);
    expect(harness.env.context.sources[0].connections).toEqual([{ destination: harness.env.node, output: 0, input: 0 }]);
  });

  it("解除すると、接続を外す。解除は、何度呼んでもよい。他のソースへ影響しない", async () => {
    const harness = await startedHarness();
    harness.mixer.addSource("microphone", audioTrack().asTrack());
    harness.mixer.addSource("shared_audio", audioTrack().asTrack());
    const [micSource, sharedSource] = harness.env.context.sources;

    harness.mixer.removeSource("microphone");
    harness.mixer.removeSource("microphone");

    expect(micSource.disconnectCount).toBe(1);
    expect(sharedSource.disconnectCount).toBe(0);
    expect(harness.mixer.hasSource("microphone")).toBe(false);
    expect(harness.mixer.hasSource("shared_audio")).toBe(true);
    expect(harness.env.node.disconnectCount).toBe(0);
  });

  it("同じ種別のソースを、あらためて加えると、置き換える（古い接続を外し、新しいトラックをつなぐ）", async () => {
    const harness = await startedHarness();
    const first = audioTrack("LABEL-a");
    const second = audioTrack("LABEL-b");
    harness.mixer.addSource("microphone", first.asTrack());

    harness.mixer.addSource("microphone", second.asTrack());

    const [oldSource, newSource] = harness.env.context.sources;
    expect(oldSource.disconnectCount).toBe(1);
    expect(newSource.stream.tracks).toEqual([second]);
    expect(newSource.connections).toEqual([{ destination: harness.env.node, output: 0, input: 0 }]);
  });

  it("音声でないトラック・すでに終了したトラックは、invalid_track（登録しない）。不明な種別は RangeError", async () => {
    const harness = await startedHarness();
    const ended = audioTrack();
    ended.stop();

    expect(() => harness.mixer.addSource("microphone", new FakeTrack("video").asTrack())).toThrow(AudioMixerError);
    expect(() => harness.mixer.addSource("microphone", ended.asTrack())).toThrow(AudioMixerError);
    expect(() => harness.mixer.addSource("camera" as MixerInputKind, audioTrack().asTrack())).toThrow(RangeError);
    expect(() => harness.mixer.removeSource("camera" as MixerInputKind)).toThrow(RangeError);
    expect(harness.mixer.hasSource("microphone")).toBe(false);
    expect(harness.env.context.sources).toEqual([]);
  });

  it("ソースが 1 つも無くても、ミキサーは止まらない（開始したまま。無音のブロックを出し続けるのは Worklet）", async () => {
    const harness = await startedHarness();

    expect(harness.mixer.status).toBe("running");
    expect(harness.env.context.sources).toEqual([]);
    harness.mixer.addSource("microphone", audioTrack().asTrack());
    harness.mixer.removeSource("microphone");
    expect(harness.mixer.status).toBe("running");
    expect(harness.env.context.state).toBe("running");
  });
});

describe("音量（共有音声の既定の比率は、マイクの 0.6 倍）", () => {
  it("既定は、マイク 1・共有音声 0.6。processorOptions の音量も、この値", async () => {
    const harness = await startedHarness();

    expect(harness.mixer.getGain("microphone")).toBe(1);
    expect(harness.mixer.getGain("shared_audio")).toBe(0.6);
    expect(DEFAULT_MIXER_GAINS.shared_audio / DEFAULT_MIXER_GAINS.microphone).toBe(0.6);
    expect((harness.env.node.options.processorOptions as { gains: number[] }).gains).toEqual([1, 0.6]);
  });

  it("オプションで、初期の音量を変えられる（指定しない種別は既定のまま）", async () => {
    const harness = await startedHarness({}, { gains: { shared_audio: 0.3 } });

    expect(harness.mixer.getGain("microphone")).toBe(1);
    expect(harness.mixer.getGain("shared_audio")).toBe(0.3);
    expect((harness.env.node.options.processorOptions as { gains: number[] }).gains).toEqual([1, 0.3]);
  });

  it("開始のあとの setGain は、コマンド（{type: gain, index, value}）を Worklet へ送る", async () => {
    const harness = await startedHarness();

    harness.mixer.setGain("shared_audio", 0.8);
    harness.mixer.setGain("microphone", 0);

    expect(harness.env.node.commands.slice(1)).toEqual([
      { type: "gain", index: 1, value: 0.8 },
      { type: "gain", index: 0, value: 0 },
    ]);
    expect(harness.mixer.getGain("shared_audio")).toBe(0.8);
    expect(harness.mixer.getGain("microphone")).toBe(0);
  });

  it("開始の前の setGain は、記録して、Worklet の作成時の設定に含める（コマンドは送らない）", async () => {
    const harness = createHarness();

    harness.mixer.setGain("shared_audio", 0.25);
    await harness.mixer.start();

    expect((harness.env.node.options.processorOptions as { gains: number[] }).gains).toEqual([1, 0.25]);
    expect(harness.env.node.commands).toEqual([{ type: "start" }]);
  });

  it.each([
    ["NaN", Number.NaN],
    ["無限大", Number.POSITIVE_INFINITY],
    ["負", -0.1],
    ["上限を超える値", MIXER_GAIN_MAX + 0.001],
  ])("不正な音量（%s）は RangeError。記録も、コマンドも、変えない", async (_name, value) => {
    const harness = await startedHarness();

    expect(() => harness.mixer.setGain("shared_audio", value)).toThrow(RangeError);

    expect(harness.mixer.getGain("shared_audio")).toBe(0.6);
    expect(harness.env.node.commands).toEqual([{ type: "start" }]);
  });

  it("上限ちょうど・0 は設定できる。不明な種別は RangeError", async () => {
    const harness = await startedHarness();

    expect(() => harness.mixer.setGain("microphone", MIXER_GAIN_MAX)).not.toThrow();
    expect(() => harness.mixer.setGain("microphone", 0)).not.toThrow();
    expect(() => harness.mixer.setGain("camera" as MixerInputKind, 1)).toThrow(RangeError);
    expect(() => harness.mixer.getGain("camera" as MixerInputKind)).toThrow(RangeError);
  });

  it("オプションの音量が不正なら、構築で RangeError", () => {
    const env = new FakeAudioEnvironment();

    expect(() => new AudioMixer({ environment: env.asEnvironment(), gains: { shared_audio: Number.NaN } })).toThrow(RangeError);
    expect(() => new AudioMixer({ environment: env.asEnvironment(), gains: { microphone: -1 } })).toThrow(RangeError);
  });

  it("入力の種別は、設定の並び（マイク・共有音声）で、Worklet の入力の番号に対応する", () => {
    expect([...MIXER_INPUT_KINDS]).toEqual(["microphone", "shared_audio"]);
  });
});

describe("Worklet からのメッセージ", () => {
  it("ブロックを、購読者へ渡す（累積サンプル数・サンプル数・PCM。PCM はコピーせず、そのまま）", async () => {
    const harness = await startedHarness();
    const pcm = new Float32Array(256);

    harness.env.node.port.receive({ type: "block", firstSample: 128, frames: 128, pcm });

    expect(harness.blocks).toEqual([{ firstSample: 128, frames: 128, pcm }]);
    expect(harness.blocks[0].pcm).toBe(pcm);
    expect(Object.keys(harness.blocks[0]).sort()).toEqual(["firstSample", "frames", "pcm"]);
  });

  it("決められた形でないメッセージは、破棄して、障害（malformed_message）として通知する（例外を投げない）", async () => {
    const harness = await startedHarness();

    harness.env.node.port.receive({ type: "block", firstSample: -1, frames: 128, pcm: new Float32Array(256) });
    harness.env.node.port.receive("not an object");

    expect(harness.blocks).toEqual([]);
    expect(harness.faults).toEqual([
      { code: "malformed_message", detail: "invalid_first_sample" },
      { code: "malformed_message", detail: "not_an_object" },
    ]);
  });

  it("Worklet が不正なコマンドを拒否したら、障害（command_rejected）として通知する", async () => {
    const harness = await startedHarness();

    harness.env.node.port.receive({ type: "rejected", command: "gain", reason: "invalid_value" });
    harness.env.node.port.receive({ type: "rejected", command: null, reason: "malformed" });

    expect(harness.faults).toEqual([
      { code: "command_rejected", detail: "gain:invalid_value" },
      { code: "command_rejected", detail: "none:malformed" },
    ]);
  });

  it("購読の解除のあとは、通知されない", async () => {
    const harness = await startedHarness();
    const onBlock = jest.fn();
    const unsubscribe = harness.mixer.subscribe({ onBlock });

    unsubscribe();
    harness.env.node.port.receive({ type: "block", firstSample: 0, frames: 128, pcm: new Float32Array(256) });

    expect(onBlock).not.toHaveBeenCalled();
  });

  it("購読者の例外は、他の購読者を止めず、例外の処理へ渡す", async () => {
    const harness = await startedHarness();
    const failure = new Error("listener failure");
    harness.mixer.subscribe({
      onBlock: () => {
        throw failure;
      },
    });
    const after = jest.fn();
    harness.mixer.subscribe({ onBlock: after });

    harness.env.node.port.receive({ type: "block", firstSample: 0, frames: 128, pcm: new Float32Array(256) });

    expect(harness.errors).toEqual([failure]);
    expect(after).toHaveBeenCalledTimes(1);
    expect(harness.blocks).toHaveLength(1);
  });
});

describe("AudioContext の停止と再開（メディアクロックへ: 停止は onAudioStall・再開は onAudioResume）", () => {
  it("suspended で停止、running で再開を通知する。同じ状態の繰り返しでは、重ねて通知しない", async () => {
    const harness = await startedHarness();

    harness.env.context.setState("suspended");
    harness.env.context.setState("suspended");
    expect(harness.mixer.status).toBe("stalled");
    harness.env.context.setState("running");
    harness.env.context.setState("running");

    expect(harness.events).toEqual(["stall", "resume"]);
    expect(harness.mixer.status).toBe("running");
  });

  it.each(["interrupted", "closed", "suspended"] as const)("%s も、停止として通知する（端末の休止・音声出力の中断）", async (state) => {
    const harness = await startedHarness();

    harness.env.context.setState(state);

    expect(harness.events).toEqual(["stall"]);
  });

  it("停止から別の停止状態へ移っても、停止の通知は 1 回（interrupted -> suspended）", async () => {
    const harness = await startedHarness();

    harness.env.context.setState("interrupted");
    harness.env.context.setState("suspended");
    harness.env.context.setState("running");

    expect(harness.events).toEqual(["stall", "resume"]);
  });

  it("開始中の状態の変化（初回の resume による running）は、通知しない", async () => {
    const harness = createHarness({ initialState: "suspended" });

    await harness.mixer.start();

    expect(harness.events).toEqual([]);
  });

  it("Worklet のプロセッサが例外を起こしたら（processorerror）、停止と障害（processor_error）を通知する。状態は faulted。重ねて通知しない", async () => {
    const harness = await startedHarness();

    harness.env.node.failProcessor();
    harness.env.node.failProcessor();

    expect(harness.events).toEqual(["stall"]);
    expect(harness.faults).toEqual([{ code: "processor_error", detail: null }]);
    expect(harness.mixer.status).toBe("faulted");
  });

  it("障害のあとの、AudioContext の状態の変化は、通知しない。stop はできる", async () => {
    const harness = await startedHarness();
    harness.env.node.failProcessor();
    harness.events.length = 0;

    harness.env.context.setState("suspended");
    harness.env.context.setState("running");
    await harness.mixer.stop();

    expect(harness.events).toEqual([]);
    expect(harness.mixer.status).toBe("stopped");
  });
});

describe("診断（デバイス名・ラベル・トラックの識別子を、ログへ出さない）", () => {
  it("開始・ソースの追加と解除・音量・停止・障害が、種別と符号で追える。トラックのラベルは、含まれない", async () => {
    const harness = createHarness({ addModule: "resolve" });
    await harness.mixer.start();
    harness.mixer.addSource("microphone", audioTrack("LABEL-SECRET-MIC").asTrack());
    harness.mixer.setGain("shared_audio", 0.5);
    harness.mixer.removeSource("microphone");
    harness.env.node.port.receive("garbage");
    await harness.mixer.stop();

    const text = JSON.stringify(harness.diagnostics);
    expect(text).not.toContain("LABEL-SECRET-MIC");
    const events = harness.diagnostics.map((entry) => entry.event);
    expect(events).toEqual(expect.arrayContaining(["mixer_start", "mixer_started", "mixer_source_added", "mixer_source_removed", "mixer_gain", "mixer_fault", "mixer_stopped"]));
    expect(harness.diagnostics.find((entry) => entry.event === "mixer_source_added")?.fields).toEqual({ kind: "microphone" });
    expect(harness.diagnostics.find((entry) => entry.event === "mixer_gain")?.fields).toEqual({ kind: "shared_audio", value: 0.5 });
    expect(harness.diagnostics.find((entry) => entry.event === "mixer_fault")?.fields).toEqual({ code: "malformed_message", detail: "not_an_object" });
  });

  it("開始の失敗は、符号で追える（元のエラーの文面は出さない）", async () => {
    const harness = createHarness({ addModule: "reject" });

    await outcomeOf(harness.mixer.start());

    const failed = harness.diagnostics.find((entry) => entry.event === "mixer_start_failed");
    expect(failed?.fields).toEqual({ code: "worklet_load_failed" });
    expect(JSON.stringify(harness.diagnostics)).not.toContain("LABEL-SECRET-MODULE");
  });
});
