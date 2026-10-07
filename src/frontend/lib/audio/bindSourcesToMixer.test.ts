// bindSourcesToMixer（requirements.md 11.2・13.1。issue #26）。SourceManager の状態の変化を、AudioMixer の混合対象の追加・解除へ伝える。
//   - マイク・共有音声が取得済みになったら、混合へ加える。喪失・解除・未取得へ戻ったら、混合から外す（皆無になれば、無音を生成し続ける）
//   - 配信中の追加・解除でも、ストリーム（AudioContext・Worklet）を再生成しない。映像のソース（カメラ・画面共有）の変化は、混合に関係しない
//   - 結びつけた時点で、すでに取得済みのソースも、混合へ加える
import { FakeMediaDevices, FakeTrack, domError, rejectWith, respondWith } from "@/lib/sources/test-support";
import { SourceManager } from "@/lib/sources/SourceManager";
import { AudioMixer } from "./AudioMixer";
import { bindSourcesToMixer } from "./bindSourcesToMixer";
import { AudioMixerError } from "./errors";
import { FakeAudioEnvironment } from "./test-support";

interface Harness {
  readonly devices: FakeMediaDevices;
  readonly manager: SourceManager;
  readonly env: FakeAudioEnvironment;
  readonly mixer: AudioMixer;
  readonly errors: unknown[];
}

function createHarness(devices: FakeMediaDevices = new FakeMediaDevices()): Harness {
  const errors: unknown[] = [];
  const env = new FakeAudioEnvironment();
  const manager = new SourceManager({ mediaDevices: devices.asMediaDevices(), onError: (error) => errors.push(error) });
  const mixer = new AudioMixer({ environment: env.asEnvironment(), onListenerError: (error) => errors.push(error) });
  return { devices, manager, env, mixer, errors };
}

describe("bindSourcesToMixer", () => {
  it("マイクが取得済みになったら混合の入力 0 へ、共有音声（画面共有と同じ取得）は入力 1 へ加える", async () => {
    const harness = createHarness();
    bindSourcesToMixer(harness.manager, harness.mixer);
    await harness.mixer.start();

    await harness.manager.attach("microphone");
    await harness.manager.attach("screen");

    const [micSource, sharedSource] = harness.env.context.sources;
    expect(micSource.stream.tracks).toEqual([harness.devices.createdTracks[0]]);
    expect(micSource.connections).toEqual([{ destination: harness.env.node, output: 0, input: 0 }]);
    expect(sharedSource.stream.tracks).toEqual([harness.devices.createdTracks[2]]);
    expect(sharedSource.connections).toEqual([{ destination: harness.env.node, output: 0, input: 1 }]);
    expect(harness.errors).toEqual([]);
  });

  it("結びつけた時点で、すでに取得済みのソースも、混合へ加える（開始の前でも）", async () => {
    const harness = createHarness();
    await harness.manager.attach("microphone");

    bindSourcesToMixer(harness.manager, harness.mixer);
    expect(harness.mixer.hasSource("microphone")).toBe(true);
    await harness.mixer.start();

    expect(harness.env.context.sources).toHaveLength(1);
  });

  it("トラックが終了（喪失）したら、混合から外す。混合は止まらず、無音を出し続ける（皆無でも、AudioContext・Worklet は、そのまま）", async () => {
    const harness = createHarness();
    bindSourcesToMixer(harness.manager, harness.mixer);
    await harness.mixer.start();
    await harness.manager.attach("microphone");
    const micSource = harness.env.context.sources[0];

    harness.devices.createdTracks[0].end();

    expect(harness.mixer.hasSource("microphone")).toBe(false);
    expect(micSource.disconnectCount).toBe(1);
    expect(harness.mixer.status).toBe("running");
    expect(harness.env.contexts).toHaveLength(1);
    expect(harness.env.workletNodes).toHaveLength(1);
    expect(harness.env.node.disconnectCount).toBe(0);
  });

  it("画面共有の終了は、共有音声も混合から外す", async () => {
    const harness = createHarness();
    bindSourcesToMixer(harness.manager, harness.mixer);
    await harness.mixer.start();
    await harness.manager.attach("screen");
    expect(harness.mixer.hasSource("shared_audio")).toBe(true);

    harness.devices.createdTracks[0].end();

    expect(harness.mixer.hasSource("shared_audio")).toBe(false);
  });

  it("解除（detach）で、混合から外す。画面共有の解除は、共有音声も外す", async () => {
    const harness = createHarness();
    bindSourcesToMixer(harness.manager, harness.mixer);
    await harness.mixer.start();
    await harness.manager.attach("microphone");
    await harness.manager.attach("screen");

    harness.manager.detach("microphone");
    harness.manager.detach("screen");

    expect(harness.mixer.hasSource("microphone")).toBe(false);
    expect(harness.mixer.hasSource("shared_audio")).toBe(false);
  });

  it("共有音声が無い画面共有（音声トラックが無い）では、混合に何も加えない", async () => {
    const harness = createHarness(new FakeMediaDevices({ sharedAudio: false }));
    bindSourcesToMixer(harness.manager, harness.mixer);
    await harness.mixer.start();

    await harness.manager.attach("screen");

    expect(harness.mixer.hasSource("shared_audio")).toBe(false);
    expect(harness.env.context.sources).toEqual([]);
  });

  it("映像のソース（カメラ・画面共有）の変化だけでは、混合の接続は変わらない", async () => {
    const harness = createHarness(new FakeMediaDevices({ sharedAudio: false }));
    bindSourcesToMixer(harness.manager, harness.mixer);
    await harness.mixer.start();

    await harness.manager.attach("camera");
    await harness.manager.attach("screen");
    harness.manager.detach("camera");

    expect(harness.env.context.sources).toEqual([]);
  });

  it("拒否・失敗では、混合へ加えない。再取得（lost -> active）で、あらためて加える", async () => {
    const harness = createHarness();
    bindSourcesToMixer(harness.manager, harness.mixer);
    await harness.mixer.start();
    harness.devices.queueUserMedia(rejectWith(domError("NotAllowedError")));
    await harness.manager.attach("microphone");
    expect(harness.mixer.hasSource("microphone")).toBe(false);

    await harness.manager.attach("microphone");
    harness.devices.createdTracks[0].end();
    await harness.manager.attach("microphone");

    expect(harness.mixer.hasSource("microphone")).toBe(true);
    expect(harness.env.context.sources).toHaveLength(2);
  });

  it("デバイスの変更（別のマイクで取得し直す）: 古いソースを外し、新しいソースを加える。ストリームは再生成しない", async () => {
    const harness = createHarness();
    bindSourcesToMixer(harness.manager, harness.mixer);
    await harness.mixer.start();
    await harness.manager.attach("microphone", "DEVICE-mic-A");

    await harness.manager.attach("microphone", "DEVICE-mic-B");

    const [oldSource, newSource] = harness.env.context.sources;
    expect(oldSource.disconnectCount).toBe(1);
    expect(newSource.connections).toEqual([{ destination: harness.env.node, output: 0, input: 0 }]);
    expect(harness.env.contexts).toHaveLength(1);
    expect(harness.env.workletNodes).toHaveLength(1);
  });

  it("結びつけを解除したあとの変化は、混合へ伝えない", async () => {
    const harness = createHarness();
    const unbind = bindSourcesToMixer(harness.manager, harness.mixer);
    await harness.mixer.start();

    unbind();
    await harness.manager.attach("microphone");

    expect(harness.mixer.hasSource("microphone")).toBe(false);
  });

  it("混合へ加えられないトラックは、例外にして、取得の処理を止めず、例外の処理へ渡す", async () => {
    const harness = createHarness();
    bindSourcesToMixer(harness.manager, harness.mixer);
    await harness.mixer.start();
    const dead = new FakeTrack("audio");
    dead.stop();
    harness.devices.queueUserMedia(respondWith(dead));

    const handle = await harness.manager.attach("microphone");

    expect(handle.state).toBe("lost");
    expect(harness.mixer.hasSource("microphone")).toBe(false);
    expect(harness.errors).toHaveLength(1);
    expect(harness.errors[0]).toBeInstanceOf(AudioMixerError);
    expect((harness.errors[0] as AudioMixerError).code).toBe("invalid_track");
  });
});
