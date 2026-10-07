/**
 * @jest-environment node
 */
// UplinkProbe（requirements.md 11.8・24.1、ws-protocol.md の 5.2）：回線計測。
//   measure(channel, clock)：ProbeChannel（sendProbe・onProbeResult）と、時計（nowMs・wait）を注入し、3 秒間、最大 6,000 kbps 相当の計測データ
//   （32 KB 程度）をペース配分して送り、中継の probe_result（実効スループット kbps）を受け取って返す。結果が来なければ（3 秒 + 猶予）タイムアウトの
//   エラー（黙ってプロファイルを決めない）。この計測は、YouTube 資源の準備より前（呼び出し順は #28）。
// 時計・待ちは、仮想の時計（ManualClock）で動かす。実時計・タイマを使わず、結果は毎回同じ。
import { LIMITS } from "../contract";
import { selectProfile } from "../profile";
import { planProbeSends } from "./probePlan";
import { DEFAULT_RESULT_GRACE_MS, ProbeResultError, ProbeSendError, ProbeTimeoutError, UplinkProbe } from "./UplinkProbe";
import type { ProbeChannel, ProbeClock } from "./types";

/** 仮想の時計：wait は、仮想の時刻が進むまで解決しない。run が、時刻を、次の予約へ進める。 */
class ManualClock implements ProbeClock {
  private now = 0;
  private sequence = 0;
  private timers: Array<{ at: number; sequence: number; fire: () => void }> = [];

  nowMs(): number {
    return this.now;
  }

  wait(milliseconds: number): Promise<void> {
    return new Promise((resolve) => {
      this.timers.push({ at: this.now + Math.max(0, milliseconds), sequence: this.sequence++, fire: resolve });
    });
  }

  /** テスト側の出来事（受領応答など）を、仮想の時刻 atMs に予約する。 */
  at(atMs: number, fire: () => void): void {
    this.timers.push({ at: atMs, sequence: this.sequence++, fire });
  }

  /** promise が確定するまで、予約を時刻順に進める。確定したら、その結果（または例外）を返す。 */
  async run<T>(promise: Promise<T>, limitMs = 60_000): Promise<{ value?: T; error?: unknown; settledAtMs: number }> {
    const deadlineMs = this.now + limitMs;
    let settled: { value?: T; error?: unknown } | undefined;
    let settledAtMs = -1;
    promise.then(
      (value) => {
        settled = { value };
        settledAtMs = this.now;
      },
      (error: unknown) => {
        settled = { error };
        settledAtMs = this.now;
      },
    );
    for (let guard = 0; guard < 100_000; guard += 1) {
      await new Promise<void>((resolve) => setImmediate(resolve));
      if (settled !== undefined) {
        return { ...settled, settledAtMs };
      }
      if (this.timers.length === 0 || this.now > deadlineMs) {
        break;
      }
      this.timers.sort((a, b) => a.at - b.at || a.sequence - b.sequence);
      const next = this.timers.shift() as { at: number; sequence: number; fire: () => void };
      this.now = Math.max(this.now, next.at);
      next.fire();
    }
    throw new Error(`the promise did not settle (virtual time ${this.now} ms, timers ${this.timers.length})`);
  }
}

interface Sent {
  readonly atMs: number;
  readonly bytes: Uint8Array;
}

/** 疑似の ProbeChannel：送ったものを記録する。結果の受信の登録・解除を数える。 */
class FakeChannel implements ProbeChannel {
  readonly sent: Sent[] = [];
  private readonly callbacks = new Set<(throughputKbps: number) => void>();
  registrations = 0;

  constructor(
    private readonly clock: ManualClock,
    private readonly onSend: (bytes: Uint8Array, channel: FakeChannel) => void | Promise<void> = () => undefined,
  ) {}

  sendProbe(bytes: Uint8Array): void | Promise<void> {
    this.sent.push({ atMs: this.clock.nowMs(), bytes });
    return this.onSend(bytes, this);
  }

  onProbeResult(callback: (throughputKbps: number) => void): () => void {
    this.registrations += 1;
    this.callbacks.add(callback);
    return () => {
      this.callbacks.delete(callback);
    };
  }

  /** 登録されている受信の数（解除されたか）。 */
  get listeners(): number {
    return this.callbacks.size;
  }

  deliver(throughputKbps: unknown): void {
    for (const callback of [...this.callbacks]) {
      callback(throughputKbps as number);
    }
  }
}

const WINDOW_MS = LIMITS.line_probe.duration_seconds * 1000;
const WIRE_BYTES = LIMITS.line_probe.message_bytes_hint + LIMITS.ws_frame.header_bytes;
/** 中継の規則（契約）で、受けた量から結果を作る：メッセージ全体のバイト数の合計 x 8 / 3,000 の切り捨て */
const relayThroughputKbps = (messages: number): number => Math.floor((messages * WIRE_BYTES * 8) / WINDOW_MS);

describe("契約との対応", () => {
  test("既定の猶予は 5 秒（仮置き。契約は『3 秒 + 猶予』とだけ定める）", () => {
    expect(DEFAULT_RESULT_GRACE_MS).toBe(5000);
  });
});

describe("UplinkProbe.measure：正常（中継が、3 秒後に、結果を返す）", () => {
  /** 中継の疑似：最初の計測データを受けて 3 秒後に、受けた量から結果を返す（受信の遅れ latencyMs を含む）。 */
  function relayThatAnswers(clock: ManualClock, latencyMs = 0): FakeChannel {
    let firstReceivedAt: number | undefined;
    let received = 0;
    const channel: FakeChannel = new FakeChannel(clock, () => {
      received += 1;
      if (firstReceivedAt === undefined) {
        firstReceivedAt = clock.nowMs() + latencyMs;
        const windowEnd = firstReceivedAt + WINDOW_MS;
        // 窓の終わりまでに受けた量。送信が、窓の終わりまでに完了している前提（シナリオが、それを保証する）
        clock.at(windowEnd, () => channel.deliver(relayThroughputKbps(received)));
      }
    });
    return channel;
  }

  test("68 メッセージを、計画どおりの時刻に送り、中継の結果（5,945 kbps）を返す。720p を選べる", async () => {
    const clock = new ManualClock();
    const channel = relayThatAnswers(clock);
    const outcome = await clock.run(new UplinkProbe().measure(channel, clock));
    expect(outcome.error).toBeUndefined();
    expect(outcome.value).toBe(relayThroughputKbps(68));
    expect(outcome.value).toBe(5945);
    const plan = planProbeSends({ durationMs: WINDOW_MS, maxRateKbps: 6000, bodyBytes: 32_768, headerBytes: 17 });
    expect(channel.sent.map((item) => item.atMs)).toEqual(plan.map((send) => send.offsetMs));
    expect(channel.sent.every((item) => item.bytes.length === 32_768)).toBe(true);
    expect(selectProfile(outcome.value as number)).toMatchObject({ kind: "selected", profile: "720p" });
  });

  test("結果を受けるのは、最初の送信から 3 秒後（受信の遅れ込み）。送信は、3 秒の窓の外へ出ない", () => {
    const clock = new ManualClock();
    const channel = relayThatAnswers(clock, 40);
    return clock.run(new UplinkProbe().measure(channel, clock)).then((outcome) => {
      expect(outcome.settledAtMs).toBe(44 + 40 + WINDOW_MS);
      expect(Math.max(...channel.sent.map((item) => item.atMs))).toBeLessThan(WINDOW_MS);
    });
  });

  test("受信の登録は 1 回で、終わったら、必ず解除する（成功しても、失敗しても、漏らさない）", async () => {
    const clock = new ManualClock();
    const channel = relayThatAnswers(clock);
    await clock.run(new UplinkProbe().measure(channel, clock));
    expect(channel.registrations).toBe(1);
    expect(channel.listeners).toBe(0);
  });

  test("最初の計測データを送る前に、結果の受信を登録する（取りこぼさない）", async () => {
    const clock = new ManualClock();
    let listenersAtFirstSend = -1;
    const channel: FakeChannel = new FakeChannel(clock, (_bytes, self) => {
      if (listenersAtFirstSend < 0) {
        listenersAtFirstSend = self.listeners;
      }
    });
    clock.at(5_000, () => channel.deliver(1234));
    await clock.run(new UplinkProbe().measure(channel, clock));
    expect(listenersAtFirstSend).toBe(1);
  });

  test("結果が 0 kbps でも、そのまま返す（回線不足の判定は、プロファイル選定の担当）", async () => {
    const clock = new ManualClock();
    const channel = new FakeChannel(clock);
    clock.at(3100, () => channel.deliver(0));
    const outcome = await clock.run(new UplinkProbe().measure(channel, clock));
    expect(outcome.value).toBe(0);
    expect(selectProfile(outcome.value as number)).toEqual({ kind: "insufficient_bandwidth" });
  });

  test.each([
    ["4,100 kbps（720p の閾値）", 4100],
    ["1,200 kbps（480p の閾値）", 1200],
    ["1,199 kbps（回線不足）", 1199],
  ])("結果 %s を、そのまま返す", async (_label, kbps) => {
    const clock = new ManualClock();
    const channel = new FakeChannel(clock);
    clock.at(3200, () => channel.deliver(kbps));
    expect((await clock.run(new UplinkProbe().measure(channel, clock))).value).toBe(kbps);
  });

  test("結果が、送信の途中で来たら（想定外）、そこで終わる：それ以上は送らず、その値を返す", async () => {
    const clock = new ManualClock();
    const channel = new FakeChannel(clock);
    clock.at(1000, () => channel.deliver(777));
    const outcome = await clock.run(new UplinkProbe().measure(channel, clock));
    expect(outcome.value).toBe(777);
    expect(outcome.settledAtMs).toBe(1000);
    expect(channel.sent.length).toBeLessThan(68);
    expect(Math.max(...channel.sent.map((item) => item.atMs))).toBeLessThanOrEqual(1000);
    expect(channel.listeners).toBe(0);
  });

  test("結果が 2 回届いても、最初の 1 つだけを使う", async () => {
    const clock = new ManualClock();
    const channel = new FakeChannel(clock);
    clock.at(3100, () => {
      channel.deliver(5000);
      channel.deliver(1);
    });
    expect((await clock.run(new UplinkProbe().measure(channel, clock))).value).toBe(5000);
  });

  test("同じ instance で、続けて 2 回計測できる（状態を持ち越さない）", async () => {
    const probe = new UplinkProbe();
    for (const kbps of [3000, 4500]) {
      const clock = new ManualClock();
      const channel = new FakeChannel(clock);
      clock.at(3100, () => channel.deliver(kbps));
      expect((await clock.run(probe.measure(channel, clock))).value).toBe(kbps);
    }
  });
});

describe("UplinkProbe.measure：結果が来ない（3 秒 + 猶予でタイムアウト。黙ってプロファイルを決めない）", () => {
  test("3 秒の窓で送り切り、さらに猶予（5 秒）を待って、ProbeTimeoutError。受信は解除される", async () => {
    const clock = new ManualClock();
    const channel = new FakeChannel(clock);
    const outcome = await clock.run(new UplinkProbe().measure(channel, clock));
    expect(outcome.error).toBeInstanceOf(ProbeTimeoutError);
    expect((outcome.error as ProbeTimeoutError).code).toBe("probe_timeout");
    expect(outcome.settledAtMs).toBe(WINDOW_MS + DEFAULT_RESULT_GRACE_MS);
    expect(channel.sent).toHaveLength(68);
    expect(channel.listeners).toBe(0);
  });

  test("猶予を指定できる（1 秒 -> 4 秒でタイムアウト）", async () => {
    const clock = new ManualClock();
    const channel = new FakeChannel(clock);
    const outcome = await clock.run(new UplinkProbe({ resultGraceMs: 1000 }).measure(channel, clock));
    expect(outcome.error).toBeInstanceOf(ProbeTimeoutError);
    expect(outcome.settledAtMs).toBe(4000);
  });

  test("期限ちょうどより前の結果は受け取る。期限を過ぎた結果は、タイムアウトのあとなので、使わない", async () => {
    const early = new ManualClock();
    const earlyChannel = new FakeChannel(early);
    early.at(WINDOW_MS + DEFAULT_RESULT_GRACE_MS - 1, () => earlyChannel.deliver(2500));
    expect((await early.run(new UplinkProbe().measure(earlyChannel, early))).value).toBe(2500);

    const late = new ManualClock();
    const lateChannel = new FakeChannel(late);
    late.at(WINDOW_MS + DEFAULT_RESULT_GRACE_MS + 1, () => lateChannel.deliver(2500));
    const outcome = await late.run(new UplinkProbe().measure(lateChannel, late));
    expect(outcome.error).toBeInstanceOf(ProbeTimeoutError);
  });

  test("タイムアウトのエラーは、符号と数値（猶予・送ったメッセージ数）だけを持つ", async () => {
    const clock = new ManualClock();
    const outcome = await clock.run(new UplinkProbe().measure(new FakeChannel(clock), clock));
    expect((outcome.error as Error).message).toMatch(/68/);
  });
});

describe("UplinkProbe.measure：送信の失敗（黙って続けない）", () => {
  test("sendProbe が例外を投げたら、ProbeSendError（何番目か・原因つき）。以後は送らず、受信は解除される", async () => {
    const clock = new ManualClock();
    const failure = new Error("socket is closed");
    const channel = new FakeChannel(clock, () => {
      throw failure;
    });
    const outcome = await clock.run(new UplinkProbe().measure(channel, clock));
    expect(outcome.error).toBeInstanceOf(ProbeSendError);
    const error = outcome.error as ProbeSendError;
    expect(error.code).toBe("probe_send_failed");
    expect(error.messageIndex).toBe(0);
    expect(error.cause).toBe(failure);
    expect(channel.sent).toHaveLength(1);
    expect(channel.listeners).toBe(0);
  });

  test("sendProbe の Promise が失敗しても、同じ（3 つ目で失敗）", async () => {
    const clock = new ManualClock();
    const channel = new FakeChannel(clock, (_bytes, self) => (self.sent.length === 3 ? Promise.reject(new Error("write failed")) : undefined));
    const outcome = await clock.run(new UplinkProbe().measure(channel, clock));
    expect(outcome.error).toBeInstanceOf(ProbeSendError);
    expect((outcome.error as ProbeSendError).messageIndex).toBe(2);
    expect(channel.sent).toHaveLength(3);
  });

  test("sendProbe が、送り終えるまで時間がかかる（送信側の詰まり）とき、窓（3 秒）を過ぎたら、送らない。結果は、猶予まで待つ", async () => {
    const clock = new ManualClock();
    // 1 メッセージの送信に 100 ms かかる：計画の間隔（約 44 ms）より遅いので、3 秒の窓に、約 30 メッセージしか入らない
    const channel = new FakeChannel(clock, () => clock.wait(100));
    clock.at(3500, () => channel.deliver(900));
    const outcome = await clock.run(new UplinkProbe().measure(channel, clock));
    expect(outcome.value).toBe(900);
    expect(channel.sent.length).toBeGreaterThanOrEqual(29);
    expect(channel.sent.length).toBeLessThanOrEqual(31);
    expect(Math.max(...channel.sent.map((item) => item.atMs))).toBeLessThan(WINDOW_MS);
  });
});

describe("UplinkProbe.measure：不正な結果（推測せず、エラー）", () => {
  test.each([
    ["負", -1],
    ["小数", 5200.5],
    ["NaN", Number.NaN],
    ["無限大", Number.POSITIVE_INFINITY],
    ["文字列", "5200"],
    ["null", null],
    ["安全整数を超える", Number.MAX_SAFE_INTEGER + 1],
  ])("結果が %s なら ProbeResultError", async (_label, value) => {
    const clock = new ManualClock();
    const channel = new FakeChannel(clock);
    clock.at(3100, () => channel.deliver(value));
    const outcome = await clock.run(new UplinkProbe().measure(channel, clock));
    expect(outcome.error).toBeInstanceOf(ProbeResultError);
    expect((outcome.error as ProbeResultError).code).toBe("probe_result_invalid");
    expect(channel.listeners).toBe(0);
  });
});

describe("UplinkProbe：計測データと設定", () => {
  test("計測データは、毎回、違う内容（圧縮で小さくならない）。同じ種で、同じ列（決定的）", async () => {
    const run = async (seed: number): Promise<string[]> => {
      const clock = new ManualClock();
      const channel = new FakeChannel(clock);
      clock.at(3100, () => channel.deliver(1000));
      await clock.run(new UplinkProbe({ seed }).measure(channel, clock));
      return channel.sent.map((item) => Buffer.from(item.bytes.subarray(0, 32)).toString("hex"));
    };
    const first = await run(11);
    expect(new Set(first).size).toBe(first.length);
    expect(await run(11)).toEqual(first);
    expect(await run(12)).not.toEqual(first);
  });

  test("設定：窓・最大レート・メッセージの大きさを変えられる（計画の長さが変わる）", async () => {
    const clock = new ManualClock();
    const channel = new FakeChannel(clock);
    clock.at(2100, () => channel.deliver(1000));
    await clock.run(new UplinkProbe({ durationMs: 2000, maxRateKbps: 2000, messageBytes: 4096 }).measure(channel, clock));
    const plan = planProbeSends({ durationMs: 2000, maxRateKbps: 2000, bodyBytes: 4096, headerBytes: 17 });
    expect(channel.sent).toHaveLength(plan.length);
    expect(channel.sent.map((item) => item.atMs)).toEqual(plan.map((send) => send.offsetMs));
  });

  test.each([
    ["窓が 0", { durationMs: 0 }],
    ["最大レートが 0", { maxRateKbps: 0 }],
    ["メッセージが 0 バイト", { messageBytes: 0 }],
    ["猶予が負", { resultGraceMs: -1 }],
    ["猶予が小数", { resultGraceMs: 1.5 }],
    ["種が 0", { seed: 0 }],
  ])("設定が不正（%s）は RangeError", (_label, options) => {
    expect(() => new UplinkProbe(options)).toThrow(RangeError);
  });

  test("猶予 0 は正しい（窓の終わりで、結果が無ければ、すぐタイムアウト）", async () => {
    const clock = new ManualClock();
    const outcome = await clock.run(new UplinkProbe({ resultGraceMs: 0 }).measure(new FakeChannel(clock), clock));
    expect(outcome.error).toBeInstanceOf(ProbeTimeoutError);
    expect(outcome.settledAtMs).toBe(WINDOW_MS);
  });

  test("時計が、最初から進んでいても（nowMs が 0 でない）、窓は、開始時刻からの相対", async () => {
    const clock = new ManualClock();
    await clock.run(clock.wait(1_000_000));
    const startedAt = clock.nowMs();
    const channel = new FakeChannel(clock);
    clock.at(startedAt + 3100, () => channel.deliver(4200));
    const outcome = await clock.run(new UplinkProbe().measure(channel, clock));
    expect(outcome.value).toBe(4200);
    expect(channel.sent[0].atMs - startedAt).toBe(44);
  });

  test("channel・clock が不正なら、推測せず TypeError ではなく RangeError", async () => {
    await expect(new UplinkProbe().measure(null as unknown as ProbeChannel, new ManualClock())).rejects.toBeInstanceOf(RangeError);
    await expect(new UplinkProbe().measure(new FakeChannel(new ManualClock()), null as unknown as ProbeClock)).rejects.toBeInstanceOf(RangeError);
  });
});
