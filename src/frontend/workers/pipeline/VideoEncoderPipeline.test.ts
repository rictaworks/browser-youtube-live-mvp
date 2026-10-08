/**
 * @jest-environment node
 */
// VideoEncoderPipeline（requirements.md 11.7・12。issue #27）。H.264 の映像エンコード（WebCodecs の VideoEncoder）。
//   - 設定: コーデックは能力検出の結果（Main か Constrained Baseline）・プロファイルの解像度・30 fps・固定ビットレート・低遅延（並べ替えフレームなし）・avc 形式
//   - キーフレーム: 2 秒（60 フレーム）ごとに keyFrame: true。forceKeyframe で次のフレームをキーフレームにする（滞留 4 秒超・復帰時）
//   - 入力待ち（encodeQueueSize）が 2 フレームを超えるときは、当該フレームを符号化せず捨てる（符号化の前なので、参照の連鎖を壊さない）。破棄を数える
//   - 復号器設定（decoderConfig.description）は、エンコーダの最初の出力で得て保持し、configChunk で返す。再設定のあとも再取得できる
//   - 時刻は、入力フレームの timestamp（videoTime(フレーム番号)）から付ける。realtime のエンコーダは、内部でフレームを間引き得るので、入力 1 = 出力 1 を前提にしない
//   - エンコーダのエラーは、型付きで通知する（黙って止まらない）。close で資源を解放する
// モックの境界: VideoEncoder は疑似（設定・入力・出力の記録）。実際の H.264 の符号化は、test/ の実ブラウザの確認（Playwright の Chromium）。
import { videoTimeUs } from "@/core/clock";
import { LIMITS } from "@/core/contract";
import type { Profile } from "@/core/contract";
import type { VideoCodec } from "@/core/transport";
import type { DecoderConfigChunk, EncodedChunk } from "@/lib/pipeline/chunks";
import { buildVideoEncoderConfig } from "@/lib/pipeline/encoderConfig";
import type { PipelineFault } from "@/lib/pipeline/errors";
import { PipelineError } from "@/lib/pipeline/errors";
import { VideoEncoderPipeline } from "./VideoEncoderPipeline";
import { FAKE_AVCC_DESCRIPTION, FakeVideoEncoder, FrameLedger, asVideoFrame } from "./test-support";

const MAIN = LIMITS.video.codec_main;
const BASELINE = LIMITS.video.codec_constrained_baseline;

afterEach(() => {
  jest.restoreAllMocks();
});

function setup() {
  FakeVideoEncoder.reset();
  const chunks: EncodedChunk[] = [];
  const faults: PipelineFault[] = [];
  const changes: DecoderConfigChunk[] = [];
  const ledger = new FrameLedger();
  const pipeline = new VideoEncoderPipeline({
    VideoEncoder: FakeVideoEncoder.asConstructor(),
    onChunk: (chunk) => chunks.push(chunk),
    onFault: (fault) => faults.push(fault),
    onDecoderConfigChanged: (config) => changes.push(config),
  });
  const frameAt = (index: number) => ledger.create(1280, 720, videoTimeUs(index));
  const encoder = (): FakeVideoEncoder => FakeVideoEncoder.instances[FakeVideoEncoder.instances.length - 1];
  return { pipeline, chunks, faults, changes, ledger, frameAt, encoder };
}

async function configured(codec: VideoCodec = MAIN, kbps = 4500, profile: Profile = "720p") {
  const context = setup();
  await context.pipeline.configure(profile, codec, kbps);
  return context;
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
  it("使えるか確かめてから設定する。設定は、低遅延・固定ビットレート・AVCC・プロファイルの解像度・30 fps", async () => {
    const { pipeline, encoder } = await configured(MAIN, 4500);

    const expected = buildVideoEncoderConfig("720p", MAIN, 4500);
    expect(FakeVideoEncoder.supportedChecks).toEqual([expected]);
    expect(encoder().configureCalls).toEqual([expected]);
    expect(encoder().configureCalls[0]).toMatchObject({ codec: "avc1.4D401F", width: 1280, height: 720, bitrate: 4_500_000, framerate: 30, bitrateMode: "constant", latencyMode: "realtime", avc: { format: "avc" } });
    expect(pipeline.isConfigured).toBe(true);
    expect(pipeline.profile).toBe("720p");
    expect(pipeline.codec).toBe(MAIN);
    expect(pipeline.bitrateKbps).toBe(4500);
  });

  it("Main が使えない環境の Constrained Baseline（軽量 480p）: 渡されたコーデックで設定する（Main へ黙って戻さない）", async () => {
    const { pipeline, encoder } = await configured(BASELINE, 1500, "480p");

    expect(encoder().configureCalls[0]).toMatchObject({ codec: "avc1.42E01F", width: 854, height: 480, bitrate: 1_500_000 });
    expect(pipeline.codec).toBe(BASELINE);
    expect(pipeline.profile).toBe("480p");
  });

  it("エンコーダが、その設定を使えない（isConfigSupported が偽）: video_config_unsupported。エンコーダは作らない・設定しない", async () => {
    const { pipeline } = setup();
    FakeVideoEncoder.supportedCodecs = new Set([BASELINE]);

    expect(await codeOf(pipeline.configure("720p", MAIN, 4500))).toBe("video_config_unsupported");
    expect(FakeVideoEncoder.instances).toHaveLength(0);
    expect(pipeline.isConfigured).toBe(false);
  });

  it("使えないと分かったあとでも、別のコーデックで設定し直せる（呼び出し側の判断。パイプラインは勝手に切り替えない）", async () => {
    const { pipeline } = setup();
    FakeVideoEncoder.supportedCodecs = new Set([BASELINE]);
    await codeOf(pipeline.configure("720p", MAIN, 4500));

    await pipeline.configure("720p", BASELINE, 4500);

    expect(pipeline.isConfigured).toBe(true);
    expect(pipeline.codec).toBe(BASELINE);
  });

  it("isConfigSupported が例外を投げても video_config_unsupported（元のエラーの名前を残す）", async () => {
    const { pipeline } = setup();
    jest.spyOn(FakeVideoEncoder, "isConfigSupported").mockRejectedValueOnce(new DOMException("boom", "NotSupportedError"));

    try {
      await pipeline.configure("720p", MAIN, 4500);
      throw new Error("should have thrown");
    } catch (error) {
      expect((error as PipelineError).code).toBe("video_config_unsupported");
      expect((error as PipelineError).detail).toBe("NotSupportedError");
    }
  });

  it("エンコーダの configure が例外を投げたら video_config_unsupported。作ったエンコーダは閉じる", async () => {
    const { pipeline } = setup();
    jest.spyOn(FakeVideoEncoder.prototype, "configure").mockImplementationOnce(() => {
      throw new TypeError("bad config");
    });

    expect(await codeOf(pipeline.configure("720p", MAIN, 4500))).toBe("video_config_unsupported");
    expect(FakeVideoEncoder.instances[0].closeCalls).toBe(1);
    expect(pipeline.isConfigured).toBe(false);
  });

  it("ビットレートがプロファイルの範囲外: bitrate_out_of_range。エンコーダには触れない", async () => {
    const { pipeline } = setup();

    expect(await codeOf(pipeline.configure("720p", MAIN, 7000))).toBe("bitrate_out_of_range");
    expect(FakeVideoEncoder.supportedChecks).toHaveLength(0);
  });

  it("プロファイルは配信の開始時に確定し、配信中に変更しない: 設定済みのパイプラインへの 2 回目の configure は invalid_state", async () => {
    const { pipeline } = await configured();

    expect(await codeOf(pipeline.configure("480p", MAIN, 1500))).toBe("invalid_state");
    expect(pipeline.profile).toBe("720p");
  });
});

describe("encode とキーフレーム（2 秒 = 60 フレームごと）", () => {
  it("最初のフレームはキーフレーム。次は差分", async () => {
    const { pipeline, frameAt, encoder } = await configured();

    pipeline.encode(asVideoFrame(frameAt(0)));
    pipeline.encode(asVideoFrame(frameAt(1)));

    expect(encoder().encodeCalls.map((call) => call.keyFrame)).toEqual([true, false]);
  });

  it("180 フレーム（6 秒）: キーフレームは 0・60・120 番目だけ（時刻は 0・2・4 秒）", async () => {
    const { pipeline, frameAt, encoder, chunks } = await configured();

    for (let index = 0; index < 180; index += 1) {
      expect(pipeline.encode(asVideoFrame(frameAt(index)))).toBe("encoded");
    }

    const keyIndexes = encoder().encodeCalls.flatMap((call, index) => (call.keyFrame ? [index] : []));
    expect(keyIndexes).toEqual([0, 60, 120]);
    expect(chunks.filter((chunk) => chunk.keyframe).map((chunk) => chunk.timestampUs)).toEqual([0, 2_000_000, 4_000_000]);
  });

  it("時刻は、入力フレームの timestamp のまま（実時計で採番しない）。出力の時刻は逆行しない", async () => {
    const { pipeline, frameAt, chunks } = await configured();

    for (let index = 0; index < 90; index += 1) {
      pipeline.encode(asVideoFrame(frameAt(index)));
    }

    expect(chunks.map((chunk) => chunk.timestampUs)).toEqual(Array.from({ length: 90 }, (_unused, index) => videoTimeUs(index)));
  });

  it("forceKeyframe: 次のフレームだけがキーフレーム。そこから 2 秒後に、次の定期のキーフレーム", async () => {
    const { pipeline, frameAt, encoder } = await configured();
    for (let index = 0; index < 10; index += 1) {
      pipeline.encode(asVideoFrame(frameAt(index)));
    }

    pipeline.forceKeyframe();
    for (let index = 10; index < 80; index += 1) {
      pipeline.encode(asVideoFrame(frameAt(index)));
    }

    const keyIndexes = encoder().encodeCalls.flatMap((call, index) => (call.keyFrame ? [index] : []));
    expect(keyIndexes).toEqual([0, 10, 70]);
  });

  it("入力待ちで捨てたフレームが、キーフレームの番だったら、次に符号化するフレームがキーフレームになる（キーフレームが抜けない）", async () => {
    const { pipeline, frameAt, encoder, ledger } = await configured();
    for (let index = 0; index < 60; index += 1) {
      pipeline.encode(asVideoFrame(frameAt(index)));
    }
    encoder().encodeQueueSize = 3;
    const dropped = frameAt(60);
    expect(pipeline.encode(asVideoFrame(dropped))).toBe("dropped_queue_full");
    encoder().encodeQueueSize = 0;

    pipeline.encode(asVideoFrame(frameAt(61)));

    expect(encoder().encodeCalls[encoder().encodeCalls.length - 1]).toMatchObject({ timestamp: videoTimeUs(61), keyFrame: true });
    expect(dropped.closeCount).toBe(1);
    expect(ledger.openCount).toBe(0);
  });

  it("強制のキーフレームの要求も、捨てたフレームでは消費しない（次に符号化するフレームで満たす）", async () => {
    const { pipeline, frameAt, encoder } = await configured();
    pipeline.encode(asVideoFrame(frameAt(0)));
    pipeline.forceKeyframe();
    encoder().encodeQueueSize = 5;
    pipeline.encode(asVideoFrame(frameAt(1)));
    encoder().encodeQueueSize = 0;

    pipeline.encode(asVideoFrame(frameAt(2)));

    expect(encoder().encodeCalls.map((call) => call.keyFrame)).toEqual([true, true]);
  });

  it("フレームは、符号化に渡したあとに閉じる（渡す時点では閉じていない）。解放漏れが無い", async () => {
    const { pipeline, frameAt, encoder, ledger } = await configured();

    for (let index = 0; index < 10; index += 1) {
      pipeline.encode(asVideoFrame(frameAt(index)));
    }

    expect(encoder().encodeCalls.every((call) => !call.frameClosedAtCall)).toBe(true);
    expect(ledger.openCount).toBe(0);
    expect(ledger.doubleClosedCount).toBe(0);
  });

  it("設定の前の encode は not_configured。渡されたフレームは、閉じる（解放漏れを作らない）", async () => {
    const { pipeline, frameAt, ledger } = setup();
    const frame = frameAt(0);

    expect(() => pipeline.encode(asVideoFrame(frame))).toThrow(PipelineError);
    expect(frame.closeCount).toBe(1);
    expect(ledger.openCount).toBe(0);
  });

  it("close のあとの encode も not_configured で、フレームを閉じる", async () => {
    const { pipeline, frameAt } = await configured();
    pipeline.close();
    const frame = frameAt(0);

    expect(() => pipeline.encode(asVideoFrame(frame))).toThrow(PipelineError);
    expect(frame.closeCount).toBe(1);
  });
});

describe("入力待ちが 2 フレームを超えたら、符号化せず捨てる（実時間性を優先）", () => {
  it.each([
    [0, "encoded"],
    [1, "encoded"],
    [2, "encoded"],
    [3, "dropped_queue_full"],
    [10, "dropped_queue_full"],
  ] as const)("encodeQueueSize = %i -> %s（2 までは符号化し、2 を超えたら捨てる）", async (queueSize, expected) => {
    const { pipeline, frameAt, encoder } = await configured();
    encoder().encodeQueueSize = queueSize;

    expect(pipeline.encode(asVideoFrame(frameAt(0)))).toBe(expected);
    expect(encoder().encodeCalls).toHaveLength(expected === "encoded" ? 1 : 0);
  });

  it("捨てた数を数える（健全性の「破棄フレーム数」へ渡す）。符号化した数とは別", async () => {
    const { pipeline, frameAt, encoder } = await configured();

    pipeline.encode(asVideoFrame(frameAt(0)));
    encoder().encodeQueueSize = 4;
    pipeline.encode(asVideoFrame(frameAt(1)));
    pipeline.encode(asVideoFrame(frameAt(2)));
    encoder().encodeQueueSize = 0;
    pipeline.encode(asVideoFrame(frameAt(3)));

    expect(pipeline.droppedBeforeEncodeCount).toBe(2);
    expect(pipeline.encodedFrameCount).toBe(2);
  });

  it("捨てたあとの差分フレームも、復号できる（捨てたのは符号化の前なので、参照の連鎖は、符号化した最後のフレームから続く）: キーフレームを要求しない", async () => {
    const { pipeline, frameAt, encoder } = await configured();
    pipeline.encode(asVideoFrame(frameAt(0)));
    encoder().encodeQueueSize = 3;
    pipeline.encode(asVideoFrame(frameAt(1)));
    encoder().encodeQueueSize = 0;

    pipeline.encode(asVideoFrame(frameAt(2)));

    expect(encoder().encodeCalls.map((call) => call.keyFrame)).toEqual([true, false]);
  });
});

describe("出力（EncodedChunk）", () => {
  it("種別・時刻・キーフレームか・バイト列。バイト列は AVCC のまま（加工しない）", async () => {
    const { pipeline, frameAt, chunks } = await configured();

    pipeline.encode(asVideoFrame(frameAt(0)));
    pipeline.encode(asVideoFrame(frameAt(1)));

    expect(chunks).toHaveLength(2);
    expect(chunks[0]).toMatchObject({ kind: "video", timestampUs: 0, keyframe: true, byteLength: 12 });
    expect(Array.from(chunks[0].data.slice(0, 4))).toEqual([0, 0, 0, 8]);
    expect(chunks[1]).toMatchObject({ kind: "video", timestampUs: 33_333, keyframe: false, byteLength: 8 });
  });

  it("realtime のエンコーダが内部でフレームを間引いても（出力が入力より少ない）、故障にも破棄にもしない。時刻は生き残った入力のもの", async () => {
    const { pipeline, frameAt, encoder, chunks, faults } = await configured();
    encoder().dropNextInputs = 1;

    pipeline.encode(asVideoFrame(frameAt(0)));
    pipeline.encode(asVideoFrame(frameAt(1)));
    pipeline.encode(asVideoFrame(frameAt(2)));

    expect(chunks.map((chunk) => chunk.timestampUs)).toEqual([videoTimeUs(1), videoTimeUs(2)]);
    expect(pipeline.droppedBeforeEncodeCount).toBe(0);
    expect(pipeline.encodedFrameCount).toBe(3);
    expect(faults).toEqual([]);
  });

  it("出力が遅れて届く（入力待ちが積み上がる）エンコーダでも、出力の順と時刻は変わらない", async () => {
    const { pipeline, frameAt, encoder, chunks } = await configured();
    encoder().holdOutputs = true;

    for (let index = 0; index < 5; index += 1) {
      pipeline.encode(asVideoFrame(frameAt(index)));
    }
    expect(chunks).toHaveLength(0);
    encoder().flushOutputs();

    expect(chunks.map((chunk) => chunk.timestampUs)).toEqual(Array.from({ length: 5 }, (_unused, index) => videoTimeUs(index)));
  });
});

describe("復号器設定（decoderConfig.description）", () => {
  it("最初の出力の前は、まだ得ていない: hasDecoderConfig は偽、configChunk は decoder_config_unavailable", async () => {
    const { pipeline } = await configured();

    expect(pipeline.hasDecoderConfig).toBe(false);
    expect(() => pipeline.configChunk()).toThrow(PipelineError);
    try {
      pipeline.configChunk();
    } catch (error) {
      expect((error as PipelineError).code).toBe("decoder_config_unavailable");
    }
  });

  it("最初の出力で得て保持する。configChunk は、映像の復号器設定（AVCDecoderConfigurationRecord）を返す", async () => {
    const { pipeline, frameAt } = await configured();

    pipeline.encode(asVideoFrame(frameAt(0)));

    const config = pipeline.configChunk();
    expect(pipeline.hasDecoderConfig).toBe(true);
    expect(config.kind).toBe("video");
    expect(config.codec).toBe("avc1.4D401F");
    expect(Array.from(config.description)).toEqual(Array.from(FAKE_AVCC_DESCRIPTION));
  });

  it("whenDecoderConfig: 最初の出力で解決する（出力の前に待ち始めても）。得たあとに呼べば、すぐ解決する", async () => {
    const { pipeline, frameAt } = await configured();
    const waiting = pipeline.whenDecoderConfig();

    pipeline.encode(asVideoFrame(frameAt(0)));

    expect((await waiting).kind).toBe("video");
    expect((await pipeline.whenDecoderConfig()).codec).toBe("avc1.4D401F");
  });

  it("返した設定を書き換えても、保持している設定は変わらない", async () => {
    const { pipeline, frameAt } = await configured();
    pipeline.encode(asVideoFrame(frameAt(0)));

    pipeline.configChunk().description[1] = 0;

    expect(pipeline.configChunk().description[1]).toBe(0x4d);
  });

  it("再設定（setBitrate）のあと、エンコーダが同じ内容の設定を返しても、変化として通知しない。再取得はできる", async () => {
    const { pipeline, frameAt, changes } = await configured();
    pipeline.encode(asVideoFrame(frameAt(0)));

    pipeline.setBitrate(3500);
    pipeline.encode(asVideoFrame(frameAt(1)));

    expect(changes).toEqual([]);
    expect(Array.from(pipeline.configChunk().description)).toEqual(Array.from(FAKE_AVCC_DESCRIPTION));
  });

  it("再設定のあとに、内容の違う設定が返ったら、変化として通知し、configChunk も新しい内容になる（中継へ設定を再送するため）", async () => {
    const { pipeline, frameAt, changes, encoder } = await configured();
    pipeline.encode(asVideoFrame(frameAt(0)));
    const changed = new Uint8Array(FAKE_AVCC_DESCRIPTION);
    changed[3] = 0x20;

    pipeline.setBitrate(3500);
    encoder().description = changed;
    pipeline.encode(asVideoFrame(frameAt(1)));

    expect(changes).toHaveLength(1);
    expect(changes[0].description[3]).toBe(0x20);
    expect(pipeline.configChunk().description[3]).toBe(0x20);
  });

  it.each([
    ["description が無い", undefined],
    ["空", new Uint8Array(0)],
    ["版が 1 でない", new Uint8Array([2, 0x4d, 0x40, 0x1f, 0xff, 0xe1, 0x00])],
  ])("最初の出力の復号器設定が不正（%s）: decoder_config_missing の故障。そのチャンクは渡さない。待っている呼び出しは拒否される", async (_name, description) => {
    const { pipeline, frameAt, encoder, faults, chunks } = await configured();
    encoder().description = description;
    const waiting = pipeline.whenDecoderConfig();

    pipeline.encode(asVideoFrame(frameAt(0)));

    expect(faults).toEqual([{ code: "decoder_config_missing", detail: null }]);
    expect(chunks).toEqual([]);
    expect(pipeline.isFaulted).toBe(true);
    expect(await codeOf(waiting)).toBe("decoder_config_missing");
  });

  it("close の前に待っていた whenDecoderConfig は、terminated で拒否される（待ち続けない）", async () => {
    const { pipeline } = await configured();
    const waiting = pipeline.whenDecoderConfig();

    pipeline.close();

    expect(await codeOf(waiting)).toBe("terminated");
  });
});

describe("setBitrate（適応制御の目標。再設定）", () => {
  it("同じコーデック・解像度・低遅延・固定のまま、ビットレートだけを変えて configure し直す", async () => {
    const { pipeline, encoder } = await configured(MAIN, 4500);

    pipeline.setBitrate(3150);

    expect(encoder().configureCalls).toHaveLength(2);
    expect(encoder().configureCalls[1]).toEqual(buildVideoEncoderConfig("720p", MAIN, 3150));
    expect(pipeline.bitrateKbps).toBe(3150);
  });

  it("パイプラインは、再設定でキーフレームを強制しない。エンコーダが再設定でキーフレームを出したときは、そのまま渡し、定期のキーフレームの起点にする", async () => {
    const { pipeline, frameAt, encoder, chunks } = await configured();
    for (let index = 0; index < 10; index += 1) {
      pipeline.encode(asVideoFrame(frameAt(index)));
    }

    pipeline.setBitrate(3500);
    for (let index = 10; index < 80; index += 1) {
      pipeline.encode(asVideoFrame(frameAt(index)));
    }

    // 疑似のエンコーダは、再設定の直後の出力をキーフレームにする（実際のエンコーダが、再設定で IDR を出し得ることの疑似）。要求したキーフレームではない
    expect(encoder().encodeCalls[10].keyFrame).toBe(false);
    expect(chunks[10].keyframe).toBe(true);
    // 定期のキーフレームは、実際に出たキーフレーム（10 番）から 2 秒後（70 番）。0 番から数えた 60 番ではない
    expect(encoder().encodeCalls.flatMap((call, index) => (call.keyFrame ? [index] : []))).toEqual([0, 70]);
    expect(chunks.filter((chunk) => chunk.keyframe).map((chunk) => chunk.timestampUs)).toEqual([0, videoTimeUs(10), videoTimeUs(70)]);
  });

  it.each([2999, 6001, 4500.5, Number.NaN])("範囲外の目標（%s）は bitrate_out_of_range。エンコーダは再設定しない", async (kbps) => {
    const { pipeline, encoder } = await configured();

    expect(() => pipeline.setBitrate(kbps)).toThrow(PipelineError);
    expect(encoder().configureCalls).toHaveLength(1);
    expect(pipeline.bitrateKbps).toBe(4500);
  });

  it("設定の前は not_configured", () => {
    const { pipeline } = setup();

    expect(() => pipeline.setBitrate(4000)).toThrow(PipelineError);
  });

  it("エンコーダの再設定が例外を投げたら、故障（video_encoder_error）として通知する", async () => {
    const { pipeline, encoder, faults } = await configured();
    jest.spyOn(encoder(), "configure").mockImplementationOnce(() => {
      throw new DOMException("closed", "InvalidStateError");
    });

    pipeline.setBitrate(3500);

    expect(faults).toEqual([{ code: "video_encoder_error", detail: "InvalidStateError" }]);
    expect(pipeline.isFaulted).toBe(true);
  });
});

describe("エンコーダのエラー（黙って止まらない）", () => {
  it("error コールバックを、型付きで通知する。以後のフレームは符号化せず、閉じる", async () => {
    const { pipeline, frameAt, encoder, faults, ledger } = await configured();
    pipeline.encode(asVideoFrame(frameAt(0)));

    encoder().fail(new DOMException("hardware failure at /dev/video0", "EncodingError"));
    const outcome = pipeline.encode(asVideoFrame(frameAt(1)));

    expect(faults).toEqual([{ code: "video_encoder_error", detail: "EncodingError" }]);
    expect(pipeline.isFaulted).toBe(true);
    expect(outcome).toBe("skipped_faulted");
    expect(encoder().encodeCalls).toHaveLength(1);
    expect(ledger.openCount).toBe(0);
  });

  it("encode が例外を投げても（エンコーダが閉じている、など）、故障として 1 回だけ通知し、フレームを閉じる", async () => {
    const { pipeline, frameAt, encoder, faults, ledger } = await configured();
    jest.spyOn(encoder(), "encode").mockImplementation(() => {
      throw new DOMException("closed", "InvalidStateError");
    });

    const first = pipeline.encode(asVideoFrame(frameAt(0)));
    const second = pipeline.encode(asVideoFrame(frameAt(1)));

    expect(first).toBe("skipped_faulted");
    expect(second).toBe("skipped_faulted");
    expect(faults).toEqual([{ code: "video_encoder_error", detail: "InvalidStateError" }]);
    expect(ledger.openCount).toBe(0);
  });

  it("出力の通知先（onChunk）が例外を投げても、エンコーダのコールバックの中へ漏らさず、故障として通知する", async () => {
    FakeVideoEncoder.reset();
    const faults: PipelineFault[] = [];
    const pipeline = new VideoEncoderPipeline({
      VideoEncoder: FakeVideoEncoder.asConstructor(),
      onChunk: () => {
        throw new RangeError("consumer failed");
      },
      onFault: (fault) => faults.push(fault),
    });
    await pipeline.configure("720p", MAIN, 4500);
    const ledger = new FrameLedger();

    expect(() => pipeline.encode(asVideoFrame(ledger.create(1280, 720, 0)))).not.toThrow();

    expect(faults).toEqual([{ code: "video_encoder_error", detail: "RangeError" }]);
  });

  it("エラーのメッセージ（デバイスの名前などを含み得る）を、故障の通知に含めない", async () => {
    const { pipeline, encoder, faults } = await configured();

    encoder().fail(new DOMException("Fake Camera 0 failed", "EncodingError"));

    expect(JSON.stringify(faults)).not.toContain("Fake Camera");
    expect(pipeline.isFaulted).toBe(true);
  });
});

describe("close と flush", () => {
  it("close はエンコーダを閉じる。何度呼んでもよく、閉じるのは 1 回", async () => {
    const { pipeline, encoder } = await configured();

    pipeline.close();
    pipeline.close();

    expect(encoder().closeCalls).toBe(1);
    expect(pipeline.isConfigured).toBe(false);
  });

  it("close のあとは、出力が届いても、通知しない", async () => {
    const { pipeline, frameAt, encoder, chunks } = await configured();
    encoder().holdOutputs = true;
    pipeline.encode(asVideoFrame(frameAt(0)));

    pipeline.close();
    encoder().flushOutputs();

    expect(chunks).toEqual([]);
  });

  it("設定する前の close は、何も起こさない", () => {
    const { pipeline } = setup();

    expect(() => pipeline.close()).not.toThrow();
  });

  it("flush はエンコーダの flush を待つ（出力を出し切る）", async () => {
    const { pipeline, frameAt, encoder, chunks } = await configured();
    encoder().holdOutputs = true;
    pipeline.encode(asVideoFrame(frameAt(0)));

    await pipeline.flush();

    expect(encoder().flushCalls).toBe(1);
    expect(chunks).toHaveLength(1);
  });
});
