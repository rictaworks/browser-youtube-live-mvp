// Worklet とのメッセージの形（public/worklets/stream-mixer-processor.js の冒頭に、同じ定義がある）。
//   メインスレッド -> Worklet: コマンド（gain・start）。processorOptions は、Worklet の作成時に渡す設定
//   Worklet -> 送り先: ブロック（block）・拒否（rejected）。受け取る側は、形を信用せず、検査する
import vm from "node:vm";
import { createMixerParameters } from "./MixerCore";
import { createProcessorOptions, parseWorkletMessage } from "./workletProtocol";
import { WorkletProtocolError } from "./errors";

function block(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return { type: "block", firstSample: 0, frames: 128, pcm: new Float32Array(256), ...overrides };
}

describe("createProcessorOptions", () => {
  it("パラメータに、入力ごとの初期の音量を加えた設定を作る（Worklet は、係数を計算せず、この値を使う）", () => {
    const parameters = createMixerParameters();

    expect(createProcessorOptions(parameters, [1, 0.6])).toEqual({ ...parameters, gains: [1, 0.6] });
  });

  it("音量の配列は、コピーする（呼び出し側の配列を、後から書き換えても影響しない）", () => {
    const gains = [1, 0.6];

    const options = createProcessorOptions(createMixerParameters(), gains);
    gains[0] = 0;

    expect(options.gains).toEqual([1, 0.6]);
  });

  it("不正な音量（NaN・負・上限超え・空）は RangeError", () => {
    const parameters = createMixerParameters();

    expect(() => createProcessorOptions(parameters, [1, Number.NaN])).toThrow(RangeError);
    expect(() => createProcessorOptions(parameters, [-1, 0.6])).toThrow(RangeError);
    expect(() => createProcessorOptions(parameters, [1, parameters.gainMax + 1])).toThrow(RangeError);
    expect(() => createProcessorOptions(parameters, [])).toThrow(RangeError);
  });
});

describe("parseWorkletMessage", () => {
  it("ブロック: 累積サンプル数・サンプル数・PCM（長さ = サンプル数 × 2）を、そのまま返す", () => {
    const pcm = new Float32Array(256);

    const message = parseWorkletMessage(block({ firstSample: 384, pcm }));

    expect(message).toEqual({ type: "block", firstSample: 384, frames: 128, pcm });
    expect(message.type === "block" && message.pcm).toBe(pcm);
  });

  it("ブロック: サンプル数は 128 でなくてもよい（長さが、サンプル数 × 2 に合えばよい）", () => {
    expect(parseWorkletMessage(block({ frames: 64, pcm: new Float32Array(128) })).type).toBe("block");
  });

  it("ブロック: PCM は、別の実行領域（realm）で作られた Float32Array でもよい（instanceof ではなく、型の名前で判定する）。Float64Array などは不可", () => {
    const foreign = vm.runInNewContext("new Float32Array(256)") as Float32Array;

    expect(foreign instanceof Float32Array).toBe(false);
    expect(parseWorkletMessage(block({ pcm: foreign })).type).toBe("block");
    expect(() => parseWorkletMessage(block({ pcm: new Float64Array(256) }))).toThrow(WorkletProtocolError);
    expect(() => parseWorkletMessage(block({ pcm: new Uint8Array(256) }))).toThrow(WorkletProtocolError);
    expect(() => parseWorkletMessage(block({ pcm: { length: 256, buffer: new ArrayBuffer(1024) } }))).toThrow(WorkletProtocolError);
  });

  it("拒否: コマンド名（無ければ null）と、理由", () => {
    expect(parseWorkletMessage({ type: "rejected", command: "gain", reason: "invalid_value" })).toEqual({ type: "rejected", command: "gain", reason: "invalid_value" });
    expect(parseWorkletMessage({ type: "rejected", command: null, reason: "malformed" })).toEqual({ type: "rejected", command: null, reason: "malformed" });
  });

  it.each([
    ["null", null, "not_an_object"],
    ["数値", 5, "not_an_object"],
    ["文字列", "block", "not_an_object"],
    ["配列", [], "unknown_type"],
    ["type が無い", {}, "unknown_type"],
    ["未知の type", { type: "ack" }, "unknown_type"],
    ["ブロック: 累積サンプル数が負", block({ firstSample: -1 }), "invalid_first_sample"],
    ["ブロック: 累積サンプル数が小数", block({ firstSample: 1.5 }), "invalid_first_sample"],
    ["ブロック: 累積サンプル数が NaN", block({ firstSample: Number.NaN }), "invalid_first_sample"],
    ["ブロック: 累積サンプル数が安全整数を超える", block({ firstSample: Number.MAX_SAFE_INTEGER + 2 }), "invalid_first_sample"],
    ["ブロック: 累積サンプル数が文字列", block({ firstSample: "0" }), "invalid_first_sample"],
    ["ブロック: サンプル数が 0", block({ frames: 0, pcm: new Float32Array(0) }), "invalid_frames"],
    ["ブロック: サンプル数が小数", block({ frames: 1.5 }), "invalid_frames"],
    ["ブロック: サンプル数が無い", block({ frames: undefined }), "invalid_frames"],
    ["ブロック: PCM が無い", block({ pcm: undefined }), "invalid_pcm"],
    ["ブロック: PCM が Float32Array でない", block({ pcm: Array.from({ length: 256 }, () => 0) }), "invalid_pcm"],
    ["ブロック: PCM の長さが合わない", block({ pcm: new Float32Array(255) }), "invalid_pcm"],
    ["拒否: 理由が未知", { type: "rejected", command: "gain", reason: "because" }, "invalid_reason"],
    ["拒否: コマンドが文字列でも null でもない", { type: "rejected", command: 5, reason: "malformed" }, "invalid_command"],
  ])("不正: %s は、WorkletProtocolError（%s）", (_name, data, reason) => {
    let thrown: unknown;
    try {
      parseWorkletMessage(data);
    } catch (error) {
      thrown = error;
    }

    expect(thrown).toBeInstanceOf(WorkletProtocolError);
    expect((thrown as WorkletProtocolError).reason).toBe(reason);
  });
});
