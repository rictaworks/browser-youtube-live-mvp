/**
 * @jest-environment node
 */
// DecoderConfigHolder（requirements.md 11.7・11.10。issue #27）。エンコーダが返す復号器設定（decoderConfig.description）の保持。
// 映像（AVCDecoderConfigurationRecord）と音声（AudioSpecificConfig）で、同じ規則を使う。
//   - 最初の出力で得る。形が正しくなければ decoder_config_missing（黙って空の設定を送らない）
//   - 得たあとに内容が変わったら、変化として通知する（中継へ設定を再送するため）。同じ内容なら通知しない
//   - 返すのはコピー（返した値を書き換えても、保持している設定は変わらない）
//   - 待っている呼び出しは、得たら解決し、故障・終了で拒否される（待ち続けない）
import { PipelineError } from "@/lib/pipeline/errors";
import { DecoderConfigHolder } from "./DecoderConfigHolder";
import { FAKE_AUDIO_SPECIFIC_CONFIG, FAKE_AVCC_DESCRIPTION } from "./test-support";
import type { DecoderConfigChunk } from "@/lib/pipeline/chunks";

async function codeOf(promise: Promise<unknown>): Promise<string> {
  try {
    await promise;
  } catch (error) {
    return error instanceof PipelineError ? error.code : `not a PipelineError: ${String(error)}`;
  }
  return "resolved";
}

function expectCode(action: () => unknown, code: string): void {
  try {
    action();
  } catch (error) {
    expect(error).toBeInstanceOf(PipelineError);
    expect((error as PipelineError).code).toBe(code);
    return;
  }
  throw new Error(`expected ${code}, but nothing was thrown`);
}

describe("得る", () => {
  it("映像: 最初の設定を保持する。コピーを返す", () => {
    const holder = new DecoderConfigHolder("video");

    expect(holder.has).toBe(false);
    holder.accept({ codec: "avc1.4D401F", description: FAKE_AVCC_DESCRIPTION });

    expect(holder.has).toBe(true);
    const config = holder.current();
    expect(config).toMatchObject({ kind: "video", codec: "avc1.4D401F" });
    expect(Array.from(config.description)).toEqual(Array.from(FAKE_AVCC_DESCRIPTION));
    config.description[0] = 9;
    expect(holder.current().description[0]).toBe(1);
  });

  it("音声: AudioSpecificConfig を保持する", () => {
    const holder = new DecoderConfigHolder("audio");

    holder.accept({ codec: "mp4a.40.2", description: FAKE_AUDIO_SPECIFIC_CONFIG });

    expect(Array.from(holder.current().description)).toEqual([0x12, 0x10]);
  });

  it("ArrayBuffer でも、そのビュー（部分）でも受け取る。ビューは、範囲だけを読む", () => {
    const holder = new DecoderConfigHolder("audio");
    const buffer = new Uint8Array([0xff, 0x12, 0x10, 0xff]).buffer;

    holder.accept({ codec: "mp4a.40.2", description: new Uint8Array(buffer, 1, 2) });

    expect(Array.from(holder.current().description)).toEqual([0x12, 0x10]);
    const second = new DecoderConfigHolder("audio");
    second.accept({ codec: "mp4a.40.2", description: new Uint8Array([0x12, 0x10]).buffer });
    expect(Array.from(second.current().description)).toEqual([0x12, 0x10]);
  });

  it("まだ得ていなければ、current は decoder_config_unavailable", () => {
    expectCode(() => new DecoderConfigHolder("video").current(), "decoder_config_unavailable");
  });
});

describe("不備は decoder_config_missing", () => {
  it.each([
    ["最初の設定に description が無い", undefined],
    ["description が配列でもビューでもない", "text"],
    ["空", new Uint8Array(0)],
  ])("%s", (_name, description) => {
    const holder = new DecoderConfigHolder("audio");

    expectCode(() => holder.accept({ codec: "mp4a.40.2", description }), "decoder_config_missing");
    expect(holder.has).toBe(false);
  });

  it("得たあとの設定に description が無いのは、前の設定のまま（再設定の出力が、設定を省くことがある）", () => {
    const holder = new DecoderConfigHolder("video");
    holder.accept({ codec: "avc1.4D401F", description: FAKE_AVCC_DESCRIPTION });

    expect(() => holder.accept({ codec: "avc1.4D401F" })).not.toThrow();

    expect(Array.from(holder.current().description)).toEqual(Array.from(FAKE_AVCC_DESCRIPTION));
  });

  it("得たあとでも、形が正しくない設定は decoder_config_missing（保持している設定は変えない）", () => {
    const holder = new DecoderConfigHolder("video");
    holder.accept({ codec: "avc1.4D401F", description: FAKE_AVCC_DESCRIPTION });

    expectCode(() => holder.accept({ codec: "avc1.4D401F", description: new Uint8Array([2, 0, 0, 0, 0, 0, 0]) }), "decoder_config_missing");

    expect(holder.current().description[0]).toBe(1);
  });
});

describe("変化の通知", () => {
  it("最初に得たときは通知しない。同じ内容なら通知しない。内容かコーデックが変わったら通知する", () => {
    const changes: DecoderConfigChunk[] = [];
    const holder = new DecoderConfigHolder("video", (config) => changes.push(config));

    holder.accept({ codec: "avc1.4D401F", description: FAKE_AVCC_DESCRIPTION });
    holder.accept({ codec: "avc1.4D401F", description: new Uint8Array(FAKE_AVCC_DESCRIPTION) });
    expect(changes).toEqual([]);

    const changed = new Uint8Array(FAKE_AVCC_DESCRIPTION);
    changed[3] = 0x20;
    holder.accept({ codec: "avc1.4D401F", description: changed });
    holder.accept({ codec: "avc1.42E01F", description: changed });

    expect(changes.map((config) => [config.codec, config.description[3]])).toEqual([
      ["avc1.4D401F", 0x20],
      ["avc1.42E01F", 0x20],
    ]);
    expect(holder.current().codec).toBe("avc1.42E01F");
  });
});

describe("待つ", () => {
  it("得たら、待っていた呼び出しがすべて解決する。得たあとに待てば、すぐ解決する", async () => {
    const holder = new DecoderConfigHolder("video");
    const first = holder.wait();
    const second = holder.wait();

    holder.accept({ codec: "avc1.4D401F", description: FAKE_AVCC_DESCRIPTION });

    expect((await first).kind).toBe("video");
    expect((await second).codec).toBe("avc1.4D401F");
    expect((await holder.wait()).codec).toBe("avc1.4D401F");
  });

  it("rejectAll: 待っていた呼び出しを拒否する。そのあとの wait も、同じ理由で拒否される（待ち続けない）", async () => {
    const holder = new DecoderConfigHolder("audio");
    const waiting = holder.wait();

    holder.rejectAll(new PipelineError("audio_encoder_error"));

    expect(await codeOf(waiting)).toBe("audio_encoder_error");
    expect(await codeOf(holder.wait())).toBe("audio_encoder_error");
  });

  it("得たあとに rejectAll しても、得た設定は返せる（終了のあとでも、すでに得た設定を読める）", async () => {
    const holder = new DecoderConfigHolder("audio");
    holder.accept({ codec: "mp4a.40.2", description: FAKE_AUDIO_SPECIFIC_CONFIG });

    holder.rejectAll(new PipelineError("terminated"));

    expect(holder.current().kind).toBe("audio");
    expect((await holder.wait()).kind).toBe("audio");
  });
});
