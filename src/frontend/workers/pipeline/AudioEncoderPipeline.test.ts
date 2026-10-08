/**
 * @jest-environment node
 */
// AudioEncoderPipeline（requirements.md 11.5〜11.7。issue #27）。AAC-LC の音声エンコード（WebCodecs の AudioEncoder）。
//   - 設定: AAC-LC（mp4a.40.2）・44.1 kHz・2 ch・128 kbps・aac 形式（生のフレーム。ADTS なし）。使えなければ audio_config_unsupported
//     （Linux・ChromeOS の Chrome、Windows の N エディションなど。30.1 の能力検出で、配信の開始は提供されない）
//   - 入力: #26 の PCM（インターリーブの 32 ビット浮動小数点）を AudioData にする。時刻は、累積サンプル数から算出する（audioTime）
//   - 出力: AAC-LC の 1 フレームは 1,024 サンプル。出力チャンクの時刻は、入力の累積サンプル数から算出する（エンコーダが返す時刻・実時計に頼らない。
//     差分を積み上げない: n 番目のチャンクの時刻 = audioTime(最初のサンプル + n × 1,024)）
//   - 音声は破棄しない。ブロックが連続していなければ（欠落・重複）、時刻の基準が崩れるので、続けず、audio_continuity_lost の故障
//   - 復号器設定（AudioSpecificConfig）は、エンコーダの最初の出力で得て保持する。エラーは型付きで通知する。close で資源を解放する
// モックの境界: AudioEncoder・AudioData は疑似。この環境（Linux の Chromium）では AAC の実エンコードを確認できない（Windows・macOS の Chrome でのユーザーテスト）。
import { audioTimeUs } from "@/core/clock";
import type { EncodedChunk } from "@/lib/pipeline/chunks";
import { buildAudioEncoderConfig } from "@/lib/pipeline/encoderConfig";
import { PipelineError } from "@/lib/pipeline/errors";
import type { PipelineFault } from "@/lib/pipeline/errors";
import { AudioEncoderPipeline } from "./AudioEncoderPipeline";
import { FAKE_AUDIO_SPECIFIC_CONFIG, FakeAudioData, FakeAudioDataFactory, FakeAudioEncoder, audioBlock } from "./test-support";

afterEach(() => {
  jest.restoreAllMocks();
});

function setup() {
  FakeAudioEncoder.reset();
  const chunks: EncodedChunk[] = [];
  const faults: PipelineFault[] = [];
  const dataFactory = new FakeAudioDataFactory();
  const pipeline = new AudioEncoderPipeline({
    AudioEncoder: FakeAudioEncoder.asConstructor(),
    AudioData: dataFactory.constructorLike,
    onChunk: (chunk) => chunks.push(chunk),
    onFault: (fault) => faults.push(fault),
  });
  const encoder = (): FakeAudioEncoder => FakeAudioEncoder.instances[FakeAudioEncoder.instances.length - 1];
  return { pipeline, chunks, faults, dataFactory, encoder };
}

async function configured() {
  const context = setup();
  await context.pipeline.configure();
  return context;
}

const sharedPcm = new Map<number, Float32Array>();

/** 無音の PCM（サンプル数ごとに 1 つを共有する。大量のブロックを流す試験で、メモリを使い切らない）。 */
function silentPcm(frames: number): Float32Array {
  const existing = sharedPcm.get(frames);
  if (existing !== undefined) {
    return existing;
  }
  const created = new Float32Array(frames * 2);
  sharedPcm.set(frames, created);
  return created;
}

/** 128 サンプル（既定）のブロックを、from から count 個、連続して流し込む。次の累積サンプル数を返す。 */
function feed(pipeline: AudioEncoderPipeline, from: number, count: number, frames = 128): number {
  let next = from;
  for (let index = 0; index < count; index += 1) {
    pipeline.encode({ firstSample: next, frames, pcm: silentPcm(frames) });
    next += frames;
  }
  return next;
}

async function codeOf(promise: Promise<unknown>): Promise<string> {
  try {
    await promise;
  } catch (error) {
    return error instanceof PipelineError ? error.code : `not a PipelineError: ${String(error)}`;
  }
  return "resolved";
}

describe("configure", () => {
  it("使えるか確かめてから設定する。設定は AAC-LC・44.1 kHz・2 ch・128 kbps・aac 形式", async () => {
    const { pipeline, encoder } = await configured();

    expect(FakeAudioEncoder.supportedChecks).toEqual([buildAudioEncoderConfig()]);
    expect(encoder().configureCalls).toEqual([buildAudioEncoderConfig()]);
    expect(encoder().configureCalls[0]).toEqual({ codec: "mp4a.40.2", sampleRate: 44_100, numberOfChannels: 2, bitrate: 128_000, aac: { format: "aac" } });
    expect(pipeline.isConfigured).toBe(true);
  });

  it("AAC が使えない環境（Linux の Chrome など。isConfigSupported が偽）: audio_config_unsupported。エンコーダは作らない（別の形式へ黙って切り替えない）", async () => {
    const { pipeline } = setup();
    FakeAudioEncoder.aacSupported = false;

    expect(await codeOf(pipeline.configure())).toBe("audio_config_unsupported");
    expect(FakeAudioEncoder.instances).toHaveLength(0);
    expect(pipeline.isConfigured).toBe(false);
  });

  it("isConfigSupported が例外を投げても audio_config_unsupported（元のエラーの名前を残す）", async () => {
    const { pipeline } = setup();
    jest.spyOn(FakeAudioEncoder, "isConfigSupported").mockRejectedValueOnce(new DOMException("boom", "NotSupportedError"));

    try {
      await pipeline.configure();
      throw new Error("should have thrown");
    } catch (error) {
      expect((error as PipelineError).code).toBe("audio_config_unsupported");
      expect((error as PipelineError).detail).toBe("NotSupportedError");
    }
  });

  it("エンコーダの configure が例外を投げたら audio_config_unsupported。作ったエンコーダは閉じる", async () => {
    const { pipeline } = setup();
    jest.spyOn(FakeAudioEncoder.prototype, "configure").mockImplementationOnce(() => {
      throw new TypeError("bad config");
    });

    expect(await codeOf(pipeline.configure())).toBe("audio_config_unsupported");
    expect(FakeAudioEncoder.instances[0].closeCalls).toBe(1);
  });

  it("設定済みのパイプラインへの 2 回目の configure は invalid_state", async () => {
    const { pipeline } = await configured();

    expect(await codeOf(pipeline.configure())).toBe("invalid_state");
  });
});

describe("入力（AudioData）", () => {
  it("#26 のブロックを、インターリーブの f32 の AudioData にする。時刻は、累積サンプル数から算出する（audioTime）", async () => {
    const { pipeline, dataFactory } = await configured();
    const block = audioBlock(896, 128);

    pipeline.encode(block);

    expect(dataFactory.created).toHaveLength(1);
    expect(dataFactory.created[0].init).toEqual({
      format: "f32",
      sampleRate: 44_100,
      numberOfChannels: 2,
      numberOfFrames: 128,
      timestamp: audioTimeUs(896),
      data: block.pcm,
    });
    expect(dataFactory.created[0].init.data).toBe(block.pcm);
  });

  it("AudioData は、符号化に渡したあとに閉じる。解放漏れが無い", async () => {
    const { pipeline, dataFactory } = await configured();

    feed(pipeline, 0, 20);

    expect(dataFactory.created).toHaveLength(20);
    expect(dataFactory.created.every((data: FakeAudioData) => data.closeCount === 1)).toBe(true);
  });

  it("時刻は、毎回、累積サンプル数から算出する（差分の積み上げをしない）: 1 時間分でも、audioTime と 1 マイクロ秒も違わない", async () => {
    const { pipeline, dataFactory } = await configured();
    const total = 44_100 * 3600;
    let next = 0;

    while (next + 4096 <= total) {
      pipeline.encode({ firstSample: next, frames: 4096, pcm: silentPcm(4096) });
      next += 4096;
    }

    const expected = dataFactory.created.map((_data, index) => audioTimeUs(index * 4096));
    expect(dataFactory.created.map((data) => data.init.timestamp)).toEqual(expected);
  });

  it("ブロックの PCM の長さがサンプル数 × 2 でなければ RangeError（呼び出しの誤り。状態は変わらない）", async () => {
    const { pipeline, dataFactory } = await configured();

    expect(() => pipeline.encode({ firstSample: 0, frames: 128, pcm: new Float32Array(100) })).toThrow(RangeError);
    expect(dataFactory.created).toHaveLength(0);
    expect(() => feed(pipeline, 0, 1)).not.toThrow();
  });

  it("設定の前・close のあとの encode は not_configured", async () => {
    const { pipeline } = setup();
    expect(() => pipeline.encode(audioBlock(0))).toThrow(PipelineError);

    const second = await configured();
    second.pipeline.close();
    expect(() => second.pipeline.encode(audioBlock(0))).toThrow(PipelineError);
  });
});

describe("出力（EncodedChunk）の時刻: 累積サンプル数から算出する", () => {
  it("AAC-LC の 1 フレーム = 1,024 サンプル（8 ブロック）ごとに 1 チャンク。時刻は audioTime(最初のサンプル + n × 1,024)。エンコーダが返した時刻は使わない", async () => {
    const { pipeline, chunks } = await configured();

    feed(pipeline, 0, 8 * 5);

    expect(chunks).toHaveLength(5);
    expect(chunks.map((chunk) => chunk.timestampUs)).toEqual([0, 1, 2, 3, 4].map((n) => audioTimeUs(n * 1024)));
    expect(chunks.map((chunk) => chunk.timestampUs)).toEqual([0, 23_220, 46_440, 69_660, 92_880]);
  });

  it("途中から始まる配信（最初のブロックの累積サンプル数が 0 でない）: その累積サンプル数が、最初のチャンクの時刻の起点", async () => {
    const { pipeline, chunks } = await configured();

    feed(pipeline, 5120, 16);

    expect(chunks.map((chunk) => chunk.timestampUs)).toEqual([audioTimeUs(5120), audioTimeUs(6144)]);
  });

  it("1 万チャンク（約 232 秒分）でも、時刻は audioTime(n × 1,024) と一致する（丸め誤差が積み上がらない）", async () => {
    const { pipeline, chunks } = await configured();

    feed(pipeline, 0, 10_000, 1024);

    expect(chunks).toHaveLength(10_000);
    for (let index = 0; index < chunks.length; index += 1) {
      if (chunks[index].timestampUs !== audioTimeUs(index * 1024)) {
        throw new Error(`chunk ${index}: ${chunks[index].timestampUs} !== ${audioTimeUs(index * 1024)}`);
      }
    }
  });

  it("時刻は逆行しない。種別は audio で、キーフレームではない（音声）。バイト列は生の AAC のまま", async () => {
    const { pipeline, chunks } = await configured();

    feed(pipeline, 0, 64);

    expect(chunks.every((chunk) => chunk.kind === "audio" && chunk.keyframe === false)).toBe(true);
    expect(chunks.every((chunk, index) => index === 0 || chunk.timestampUs > chunks[index - 1].timestampUs)).toBe(true);
    expect(Array.from(chunks[0].data)).toEqual([0x21, 0x10, 0x04]);
    expect(chunks[0].byteLength).toBe(3);
  });

  it("128 サンプルでないブロック（可変）でも、出力の時刻は、サンプル数だけで決まる", async () => {
    const { pipeline, chunks } = await configured();
    let next = 0;

    for (const frames of [300, 724, 500, 548, 1024]) {
      pipeline.encode(audioBlock(next, frames));
      next += frames;
    }

    expect(next).toBe(3096);
    expect(chunks.map((chunk) => chunk.timestampUs)).toEqual([0, 1024, 2048].map((n) => audioTimeUs(n)));
  });
});

describe("ブロックの連続性（時刻の基準）", () => {
  it.each([
    ["欠落（1 ブロック飛ばす）", 384],
    ["重複（同じブロックをもう一度）", 0],
    ["順序の入れ替わり", 1024],
  ])("%s は audio_continuity_lost の故障。以後は符号化しない（時刻の基準が崩れたまま続けない）", async (_name, nextFirstSample) => {
    const { pipeline, faults, dataFactory } = await configured();
    pipeline.encode(audioBlock(0, 128));
    pipeline.encode(audioBlock(128, 128));

    pipeline.encode(audioBlock(nextFirstSample, 128));
    pipeline.encode(audioBlock(256, 128));

    expect(faults).toEqual([{ code: "audio_continuity_lost", detail: null }]);
    expect(pipeline.isFaulted).toBe(true);
    expect(dataFactory.created).toHaveLength(2);
  });
});

describe("復号器設定（AudioSpecificConfig）", () => {
  it("最初の出力の前は、まだ得ていない（decoder_config_unavailable）。最初の出力で得る（AAC-LC・44.1 kHz・2 ch は 0x12 0x10）", async () => {
    const { pipeline } = await configured();
    expect(pipeline.hasDecoderConfig).toBe(false);
    expect(() => pipeline.configChunk()).toThrow(PipelineError);

    feed(pipeline, 0, 8);

    const config = pipeline.configChunk();
    expect(pipeline.hasDecoderConfig).toBe(true);
    expect(config).toMatchObject({ kind: "audio", codec: "mp4a.40.2" });
    expect(Array.from(config.description)).toEqual(Array.from(FAKE_AUDIO_SPECIFIC_CONFIG));
  });

  it("whenDecoderConfig は、最初の出力で解決する", async () => {
    const { pipeline } = await configured();
    const waiting = pipeline.whenDecoderConfig();

    feed(pipeline, 0, 8);

    expect((await waiting).kind).toBe("audio");
  });

  it("最初の出力に復号器設定が無い・形が正しくない: decoder_config_missing の故障。そのチャンクは渡さない。待っている呼び出しは拒否される", async () => {
    const { pipeline, encoder, faults, chunks } = await configured();
    encoder().description = new Uint8Array([0x12]);
    const waiting = pipeline.whenDecoderConfig();

    feed(pipeline, 0, 8);

    expect(faults).toEqual([{ code: "decoder_config_missing", detail: null }]);
    expect(chunks).toEqual([]);
    expect(await codeOf(waiting)).toBe("decoder_config_missing");
  });
});

describe("エンコーダのエラー（黙って止まらない）", () => {
  it("error コールバックを、型付きで通知する。以後の入力は符号化しない（呼び出しは例外にしない。音声のクロックを止めない）", async () => {
    const { pipeline, encoder, faults, dataFactory } = await configured();
    feed(pipeline, 0, 4);

    encoder().fail(new DOMException("device lost: Fake Mic 0", "EncodingError"));
    expect(() => feed(pipeline, 512, 4)).not.toThrow();

    expect(faults).toEqual([{ code: "audio_encoder_error", detail: "EncodingError" }]);
    expect(JSON.stringify(faults)).not.toContain("Fake Mic");
    expect(dataFactory.created).toHaveLength(4);
  });

  it("AudioData の作成に失敗しても、故障として 1 回だけ通知する", async () => {
    const { pipeline, dataFactory, faults } = await configured();
    dataFactory.failNext = true;

    pipeline.encode(audioBlock(0));
    pipeline.encode(audioBlock(128));

    expect(faults).toEqual([{ code: "audio_encoder_error", detail: "TypeError" }]);
  });

  it("encode が例外を投げても（エンコーダが閉じている、など）、故障として通知し、AudioData は閉じる", async () => {
    const { pipeline, encoder, faults, dataFactory } = await configured();
    jest.spyOn(encoder(), "encode").mockImplementation(() => {
      throw new DOMException("closed", "InvalidStateError");
    });

    pipeline.encode(audioBlock(0));

    expect(faults).toEqual([{ code: "audio_encoder_error", detail: "InvalidStateError" }]);
    expect(dataFactory.created[0].closeCount).toBe(1);
  });

  it("出力の通知先が例外を投げても、エンコーダのコールバックへ漏らさず、故障として通知する", async () => {
    FakeAudioEncoder.reset();
    const faults: PipelineFault[] = [];
    const pipeline = new AudioEncoderPipeline({
      AudioEncoder: FakeAudioEncoder.asConstructor(),
      AudioData: new FakeAudioDataFactory().constructorLike,
      onChunk: () => {
        throw new RangeError("consumer failed");
      },
      onFault: (fault) => faults.push(fault),
    });
    await pipeline.configure();

    expect(() => feed(pipeline, 0, 8)).not.toThrow();

    expect(faults).toEqual([{ code: "audio_encoder_error", detail: "RangeError" }]);
  });
});

describe("close", () => {
  it("エンコーダを閉じる。何度呼んでもよく、閉じるのは 1 回。待っている呼び出しは terminated で拒否される", async () => {
    const { pipeline, encoder } = await configured();
    const waiting = pipeline.whenDecoderConfig();

    pipeline.close();
    pipeline.close();

    expect(encoder().closeCalls).toBe(1);
    expect(pipeline.isConfigured).toBe(false);
    expect(await codeOf(waiting)).toBe("terminated");
  });

  it("設定する前の close は、何も起こさない", () => {
    expect(() => setup().pipeline.close()).not.toThrow();
  });

  it("flush はエンコーダの flush を待つ", async () => {
    const { pipeline } = await configured();

    await expect(pipeline.flush()).resolves.toBeUndefined();
  });
});
