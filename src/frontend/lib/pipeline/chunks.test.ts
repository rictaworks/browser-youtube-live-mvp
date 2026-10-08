/**
 * @jest-environment node
 */
// 符号化結果（EncodedChunk）と復号器設定（DecoderConfigChunk）の型（requirements.md 11.7・11.9、契約 ws-protocol.md の 5.3・5.4）。
//   - EncodedChunk は #25 の SendQueue（ChunkMeta）と FrameCodec の video/audio の本文（AVCC のまま・生の AAC のまま）にそのまま渡せる
//   - 音声のチャンクは、キーフレームではない（AAC の全フレームが独立だが、キーフレームの属性は映像のもの）
//   - 時刻は、メディアクロックのマイクロ秒（0 以上の安全整数）。実時計で採番しない
import { FrameCodec, decodeRawFrame } from "@/core/transport";
import { SendQueue } from "@/core/queue";
import { createDecoderConfigChunk, createEncodedChunk, isDecoderConfigChunk, isEncodedChunk } from "./chunks";
import type { EncodedChunk } from "./chunks";
import { PipelineError } from "./errors";

/** AVCDecoderConfigurationRecord の最小の例（版 1・Main・レベル 3.1・長さ 4 の NAL 長・SPS 0 個・PPS 0 個）。 */
const AVCC_RECORD = new Uint8Array([1, 0x4d, 0x40, 0x1f, 0xff, 0xe0, 0x00]);
/** AudioSpecificConfig（AAC-LC・44.1 kHz・2 ch）。 */
const AUDIO_SPECIFIC_CONFIG = new Uint8Array([0x12, 0x10]);

function video(timestampUs: number, keyframe: boolean, size = 4): EncodedChunk {
  return createEncodedChunk({ kind: "video", timestampUs, keyframe, data: new Uint8Array(size) });
}

describe("createEncodedChunk", () => {
  it("種別・時刻・キーフレームか・バイト列から作る。バイト数は、バイト列の長さ", () => {
    const data = new Uint8Array([0, 0, 0, 2, 0x65, 0x88]);

    const chunk = createEncodedChunk({ kind: "video", timestampUs: 33_333, keyframe: true, data });

    expect(chunk).toEqual({ kind: "video", timestampUs: 33_333, keyframe: true, byteLength: 6, data });
    expect(chunk.data).toBe(data);
  });

  it("音声は、キーフレームにしない（SendQueue の規則）", () => {
    expect(() => createEncodedChunk({ kind: "audio", timestampUs: 0, keyframe: true, data: new Uint8Array(1) })).toThrow(RangeError);
    expect(createEncodedChunk({ kind: "audio", timestampUs: 0, keyframe: false, data: new Uint8Array(1) }).keyframe).toBe(false);
  });

  it.each([
    ["種別が不明", { kind: "text", timestampUs: 0, keyframe: false, data: new Uint8Array(1) }],
    ["時刻が負", { kind: "video", timestampUs: -1, keyframe: false, data: new Uint8Array(1) }],
    ["時刻が小数", { kind: "video", timestampUs: 0.5, keyframe: false, data: new Uint8Array(1) }],
    ["時刻が NaN", { kind: "video", timestampUs: Number.NaN, keyframe: false, data: new Uint8Array(1) }],
    ["時刻が安全整数を超える", { kind: "video", timestampUs: 2 ** 53, keyframe: false, data: new Uint8Array(1) }],
    ["キーフレームの指定が真偽値でない", { kind: "video", timestampUs: 0, keyframe: 1, data: new Uint8Array(1) }],
    ["バイト列が Uint8Array でない", { kind: "video", timestampUs: 0, keyframe: false, data: [1, 2] }],
  ])("不正な入力は RangeError（%s）", (_name, input) => {
    expect(() => createEncodedChunk(input as unknown as Parameters<typeof createEncodedChunk>[0])).toThrow(RangeError);
  });

  it("空のバイト列は許す（0 バイトのチャンクを作る側の問題は、送る側が検査する）", () => {
    expect(createEncodedChunk({ kind: "video", timestampUs: 0, keyframe: false, data: new Uint8Array(0) }).byteLength).toBe(0);
  });
});

describe("isEncodedChunk（ワーカーから届いた値の検査）", () => {
  it("正しい形だけを真にする", () => {
    expect(isEncodedChunk(video(0, true))).toBe(true);
    expect(isEncodedChunk(createEncodedChunk({ kind: "audio", timestampUs: 23_220, keyframe: false, data: new Uint8Array(3) }))).toBe(true);
  });

  it.each([
    ["null", null],
    ["文字列", "chunk"],
    ["種別が違う", { kind: "x", timestampUs: 0, keyframe: false, byteLength: 1, data: new Uint8Array(1) }],
    ["バイト数がバイト列と合わない", { kind: "video", timestampUs: 0, keyframe: false, byteLength: 2, data: new Uint8Array(1) }],
    ["時刻が不正", { kind: "video", timestampUs: -5, keyframe: false, byteLength: 1, data: new Uint8Array(1) }],
    ["音声がキーフレーム", { kind: "audio", timestampUs: 0, keyframe: true, byteLength: 1, data: new Uint8Array(1) }],
    ["バイト列が無い", { kind: "video", timestampUs: 0, keyframe: false, byteLength: 1 }],
  ])("偽: %s", (_name, value) => {
    expect(isEncodedChunk(value)).toBe(false);
  });
});

describe("createDecoderConfigChunk（復号器設定。最初のメディアフレームより前に送る内容）", () => {
  it("映像: AVCDecoderConfigurationRecord（先頭が版 1）を保持する。渡したバイト列を書き換えても、保持した内容は変わらない", () => {
    const source = new Uint8Array(AVCC_RECORD);

    const config = createDecoderConfigChunk({ kind: "video", codec: "avc1.4D401F", description: source });
    source[1] = 0;

    expect(config.kind).toBe("video");
    expect(config.codec).toBe("avc1.4D401F");
    expect(Array.from(config.description)).toEqual(Array.from(AVCC_RECORD));
  });

  it("音声: AudioSpecificConfig（AAC-LC・44.1 kHz・2 ch は 0x12 0x10）", () => {
    const config = createDecoderConfigChunk({ kind: "audio", codec: "mp4a.40.2", description: AUDIO_SPECIFIC_CONFIG });

    expect(Array.from(config.description)).toEqual([0x12, 0x10]);
  });

  it.each([
    ["映像: 空", { kind: "video" as const, codec: "avc1.4D401F", description: new Uint8Array(0) }],
    ["映像: 版が 1 でない", { kind: "video" as const, codec: "avc1.4D401F", description: new Uint8Array([2, 0x4d, 0x40, 0x1f, 0xff, 0xe0, 0x00]) }],
    ["映像: 短すぎる", { kind: "video" as const, codec: "avc1.4D401F", description: new Uint8Array([1, 0x4d, 0x40]) }],
    ["音声: 空", { kind: "audio" as const, codec: "mp4a.40.2", description: new Uint8Array(0) }],
    ["音声: 短すぎる", { kind: "audio" as const, codec: "mp4a.40.2", description: new Uint8Array([0x12]) }],
  ])("不正な復号器設定は decoder_config_missing（黙って空の設定を送らない）: %s", (_name, input) => {
    expect(() => createDecoderConfigChunk(input)).toThrow(PipelineError);
    try {
      createDecoderConfigChunk(input);
    } catch (error) {
      expect((error as PipelineError).code).toBe("decoder_config_missing");
    }
  });

  it("isDecoderConfigChunk は、作ったものを真、他を偽にする", () => {
    expect(isDecoderConfigChunk(createDecoderConfigChunk({ kind: "audio", codec: "mp4a.40.2", description: AUDIO_SPECIFIC_CONFIG }))).toBe(true);
    expect(isDecoderConfigChunk({ kind: "audio", codec: "mp4a.40.2" })).toBe(false);
    expect(isDecoderConfigChunk(null)).toBe(false);
  });
});

describe("#25 の部品にそのまま渡せる", () => {
  it("SendQueue（ChunkMeta）へ積み、取り出せる。映像と音声が到着順に出る", () => {
    const queue = new SendQueue<EncodedChunk>();
    const audio = createEncodedChunk({ kind: "audio", timestampUs: 0, keyframe: false, data: new Uint8Array(5) });

    expect(queue.enqueue(video(0, true, 10)).accepted).toBe(true);
    expect(queue.enqueue(audio).accepted).toBe(true);

    expect(queue.dequeue()?.kind).toBe("video");
    expect(queue.dequeue()).toBe(audio);
  });

  it("FrameCodec の video/audio のメッセージへ、本文を変えずに（AVCC のまま・生の AAC のまま）入れられる。時刻とキーフレームの属性が、ヘッダに載る", () => {
    const codec = new FrameCodec();
    const avcc = new Uint8Array([0, 0, 0, 3, 0x65, 0x88, 0x84]);
    const key = createEncodedChunk({ kind: "video", timestampUs: 2_000_000, keyframe: true, data: avcc });
    const aac = createEncodedChunk({ kind: "audio", timestampUs: 23_220, keyframe: false, data: new Uint8Array([0x21, 0x10, 0x04]) });

    const videoFrame = decodeRawFrame(codec.encode({ type: "video", timestampUs: key.timestampUs, keyframe: key.keyframe, payload: key.data }), "browser_to_relay");
    const audioFrame = decodeRawFrame(codec.encode({ type: "audio", timestampUs: aac.timestampUs, payload: aac.data }), "browser_to_relay");

    expect(videoFrame.keyframe).toBe(true);
    expect(videoFrame.timestampUs).toBe(BigInt(2_000_000));
    expect(Array.from(videoFrame.body)).toEqual(Array.from(avcc));
    expect(audioFrame.keyframe).toBe(false);
    expect(audioFrame.timestampUs).toBe(BigInt(23_220));
    expect(Array.from(audioFrame.body)).toEqual([0x21, 0x10, 0x04]);
  });
});
