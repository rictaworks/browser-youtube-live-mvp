// UplinkProbe：回線計測（requirements.md 11.8・24.1、ws-protocol.md の 5.2）。
//
// 中継への接続が成立し（accepted を受けたあと）、YouTube 資源の準備より前に、上り回線の実効スループットを計測する（呼び出しの順は、#28）。
//   1. 結果の受信（ProbeChannel.onProbeResult）を登録する（最初のデータを送る前。取りこぼさない）
//   2. 3 秒間、最大 6,000 kbps 相当で、32 KB 程度の計測データを、ペース配分して送る（planProbeSends。時刻は、注入した時計の wait で待つ）
//      送信が詰まる（sendProbe の Promise が遅い）場合は、詰まった分、送るメッセージが減る。窓（3 秒）を過ぎたら、送らない
//      送信の完了待ちは、窓の終わりと競わせる。窓の終わりまでに解決しない送信（bufferedAmount が減らない不通の回線など）は打ち切り、待ち続けない
//   3. 中継の probe_result（受けた量から作った実効スループット kbps）を受け取り、返す（プロファイルの選定は、selectProfile）
//   4. 窓が終わってから、猶予（既定 5 秒）のあいだに結果が来なければ、ProbeTimeoutError（黙ってプロファイルを決めない）。
//      送信が詰まっていても、窓 + 猶予（既定 8 秒）で、必ず終わる
// 状態を持たない（同じ instance で、続けて計測できる）。時計・待ち・送信は、すべて注入（実時計・タイマ・WebSocket を参照しない）。
// 計測データの中身は、決定的な擬似乱数（圧縮で、実際より速く測れないように）。

import { LIMITS } from "../contract";
import { ProbePayloadGenerator, assertProbeSeed } from "./probePayload";
import { planProbeSends } from "./probePlan";
import type { ProbeSend } from "./probePlan";
import type { ProbeChannel, ProbeClock, UplinkProbeOptions } from "./types";

/** 窓（計測の長さ）が終わってから、結果を待つ猶予（ミリ秒）。契約は「3 秒 + 猶予」とだけ定める。往復の遅れ（数百ミリ秒）に、余裕を見た仮置き。 */
export const DEFAULT_RESULT_GRACE_MS = 5000;

/** 計測データの擬似乱数の、既定の種（黄金比の 32 ビットの定数）。 */
const DEFAULT_SEED = 0x9e3779b9;

const MILLISECONDS_PER_SECOND = 1000;

/**
 * 結果が、3 秒 + 猶予のうちに届かなかった。符号と、待った時間・送り終えたメッセージ数と、窓の終わりに送信が終わっていなかったメッセージの番号
 * （stalledMessageIndex。0 始まり。送信が詰まったとき。無ければ undefined）だけを持つ。
 */
export class ProbeTimeoutError extends Error {
  readonly code = "probe_timeout";

  constructor(
    readonly waitedMs: number,
    readonly sentMessages: number,
    readonly stalledMessageIndex?: number,
  ) {
    const stalled = stalledMessageIndex === undefined ? "" : `; message ${stalledMessageIndex} was still being sent when the window ended`;
    super(`no probe result within ${waitedMs} ms after the window started (${sentMessages} probe messages were sent${stalled})`);
    this.name = "ProbeTimeoutError";
  }
}

/** 計測データを送れなかった（sendProbe の失敗）。何番目か（0 始まり）と、原因（cause）を持つ。 */
export class ProbeSendError extends Error {
  readonly code = "probe_send_failed";

  constructor(
    readonly messageIndex: number,
    cause: unknown,
  ) {
    super(`failed to send probe message ${messageIndex}`, { cause });
    this.name = "ProbeSendError";
  }
}

/** 計測結果が、0 以上の整数（kbps）でなかった。値は、エラーに含めない。 */
export class ProbeResultError extends Error {
  readonly code = "probe_result_invalid";

  constructor() {
    super("the probe result must be a non-negative safe integer (kbps)");
    this.name = "ProbeResultError";
  }
}

type Outcome = { readonly kind: "result"; readonly throughputKbps: number } | { readonly kind: "invalid" };

/** 送信の結果（値）。 */
type SendSettlement = { readonly kind: "sent" } | { readonly kind: "failed"; readonly cause: unknown };

/** 送信の完了待ちが、競争で負けた理由（値）。 */
const RESULT_ARRIVED = "result_arrived" as const;
const WINDOW_ENDED = "window_ended" as const;

/**
 * 送信を始め、完了（解決）か失敗（拒否・同期の例外）を、値として返す。この Promise は拒否しない。
 * 窓の終わりで打ち切った（競争に負けた）送信が、あとで拒否されても、未処理の拒否にならない（打ち切ったあとの解決・拒否は、無視する）。
 */
async function settleSend(channel: ProbeChannel, bytes: Uint8Array): Promise<SendSettlement> {
  try {
    await channel.sendProbe(bytes);
    return { kind: "sent" };
  } catch (cause) {
    return { kind: "failed", cause };
  }
}

function assertChannel(channel: unknown): asserts channel is ProbeChannel {
  const candidate = channel as Partial<ProbeChannel> | null;
  if (typeof candidate !== "object" || candidate === null || typeof candidate.sendProbe !== "function" || typeof candidate.onProbeResult !== "function") {
    throw new RangeError("channel must provide sendProbe and onProbeResult");
  }
}

function assertClock(clock: unknown): asserts clock is ProbeClock {
  const candidate = clock as Partial<ProbeClock> | null;
  if (typeof candidate !== "object" || candidate === null || typeof candidate.nowMs !== "function" || typeof candidate.wait !== "function") {
    throw new RangeError("clock must provide nowMs and wait");
  }
}

export class UplinkProbe {
  private readonly durationMs: number;
  private readonly resultGraceMs: number;
  private readonly seed: number;
  private readonly plan: readonly ProbeSend[];

  /** 設定は、契約の値が既定。不正な設定は RangeError。 */
  constructor(options: UplinkProbeOptions = {}) {
    this.durationMs = options.durationMs ?? LIMITS.line_probe.duration_seconds * MILLISECONDS_PER_SECOND;
    this.resultGraceMs = options.resultGraceMs ?? DEFAULT_RESULT_GRACE_MS;
    this.seed = options.seed ?? DEFAULT_SEED;
    if (!Number.isSafeInteger(this.resultGraceMs) || this.resultGraceMs < 0) {
      throw new RangeError(`resultGraceMs must be a non-negative safe integer: ${String(this.resultGraceMs)}`);
    }
    // 種と、計画（窓・レート・大きさの検査を含む）を、ここで検査する（不正な設定を、計測の開始まで持ち越さない）
    assertProbeSeed(this.seed);
    this.plan = planProbeSends({
      durationMs: this.durationMs,
      maxRateKbps: options.maxRateKbps ?? LIMITS.line_probe.max_rate_kbps,
      bodyBytes: options.messageBytes ?? LIMITS.line_probe.message_bytes_hint,
      headerBytes: LIMITS.ws_frame.header_bytes,
    });
  }

  /**
   * 計測して、実効スループット（kbps。0 以上の整数）を返す。
   *   - 結果が来ない（窓 + 猶予）：ProbeTimeoutError。送信が詰まっていても（sendProbe が解決しなくても）、窓の終わりで送信を打ち切り、猶予を待って、必ず終わる
   *   - 送信の失敗（窓の終わりまでの、sendProbe の拒否・同期の例外）：ProbeSendError（以後は送らない）。打ち切ったあとの拒否は、無視する
   *   - 結果が 0 以上の整数でない：ProbeResultError
   * どの場合も、結果の受信は、解除する。結果が窓の途中で届いたら（想定外）、そこで終わる（それ以上は送らず、その値を返す）。
   * 待ち（clock.wait）は、ペースの待ちのほかに、窓の終わり 1 本と、猶予 1 本だけ（送信ごとに、期限の待ちを作らない）。
   */
  async measure(channel: ProbeChannel, clock: ProbeClock): Promise<number> {
    assertChannel(channel);
    assertClock(clock);

    let outcome: Outcome | undefined;
    let notifyArrival: () => void = () => undefined;
    const arrived = new Promise<void>((resolve) => {
      notifyArrival = resolve;
    });
    const currentOutcome = (): Outcome | undefined => outcome;

    // 最初のデータを送る前に登録する。結果は 1 回だけ受け取る（以後の呼び出しは、無視する）
    const unsubscribe = channel.onProbeResult((throughputKbps) => {
      if (outcome !== undefined) {
        return;
      }
      outcome = Number.isSafeInteger(throughputKbps) && throughputKbps >= 0 ? { kind: "result", throughputKbps } : { kind: "invalid" };
      notifyArrival();
    });
    if (typeof unsubscribe !== "function") {
      throw new RangeError("onProbeResult must return an unsubscribe function");
    }

    const payloads = new ProbePayloadGenerator(this.seed);
    let sent = 0;
    let stalledMessageIndex: number | undefined;
    try {
      const startMs = clock.nowMs();
      // 窓の終わりの待ちは、ここで 1 本だけ作る。ペースの待ちと、各送信の完了待ちを、これと競わせる（送信ごとに作ると、期限まで、タイマが計画の数だけ残る）
      let windowClosed = false;
      const isWindowClosed = (): boolean => windowClosed;
      const windowEnded = clock.wait(Math.max(0, startMs + this.durationMs - clock.nowMs())).then(() => {
        windowClosed = true;
        return WINDOW_ENDED;
      });
      const resultArrived = arrived.then(() => RESULT_ARRIVED);

      for (const send of this.plan) {
        if (currentOutcome() !== undefined || isWindowClosed()) {
          break;
        }
        const waitMs = startMs + send.offsetMs - clock.nowMs();
        if (waitMs > 0) {
          await Promise.race([clock.wait(waitMs), resultArrived, windowEnded]);
        }
        if (currentOutcome() !== undefined || isWindowClosed() || clock.nowMs() - startMs >= this.durationMs) {
          break;
        }
        // 送信の完了（解決）を、結果の到着・窓の終わりと競わせる。窓の終わりまでに解決しない送信は、打ち切る（待ち続けない）
        const settled = await Promise.race([settleSend(channel, payloads.next(send.bodyBytes)), resultArrived, windowEnded]);
        if (settled === RESULT_ARRIVED) {
          break;
        }
        if (settled === WINDOW_ENDED) {
          stalledMessageIndex = send.index;
          break;
        }
        if (settled.kind === "failed") {
          throw new ProbeSendError(send.index, settled.cause);
        }
        sent += 1;
      }

      if (currentOutcome() === undefined) {
        const remainingMs = startMs + this.durationMs + this.resultGraceMs - clock.nowMs();
        if (remainingMs > 0) {
          await Promise.race([arrived, clock.wait(remainingMs)]);
        }
      }

      const final = currentOutcome();
      if (final === undefined) {
        throw new ProbeTimeoutError(this.durationMs + this.resultGraceMs, sent, stalledMessageIndex);
      }
      if (final.kind === "invalid") {
        throw new ProbeResultError();
      }
      return final.throughputKbps;
    } finally {
      unsubscribe();
    }
  }
}
