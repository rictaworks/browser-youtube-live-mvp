/**
 * @jest-environment node
 */
// 適応制御のシミュレーション（requirements.md 12 章・23.3）：回線の悪化と回復を模した、閉じた輪。
//   エンコーダ（目標ビットレートで、毎 100 ms に映像 1 チャンク・音声 1 チャンクを作る）-> SendQueue -> 回線（容量 kbps の先入れ先出しの管。
//   容量は時刻で変わる）-> 中継の受領応答（500 ms 間隔）-> SendQueue.backlogMs -> BitrateGovernor（1 秒ごと）-> 目標・全破棄・再接続・劣化
// 時刻はすべて、シミュレーション内の仮想の時刻（メディアクロックに当たる）。実時計・乱数・タイマを使わない。結果は、毎回同じ。
//
// 検査するのは、目標の推移・全破棄・再接続・劣化の出入りが、12 章の規則から予想できる範囲に入ること。数値の窓は、
// 回線の容量と送出量の差から、滞留時間の増え方を見積もったもの（各シナリオの説明に、見積りを書く）。
import { SendQueue } from "../queue";
import type { ChunkMeta } from "../queue";
import { BitrateGovernor } from "./BitrateGovernor";

const STEP_MS = 100;
const STEPS_PER_SECOND = 1000 / STEP_MS;
const ACK_EVERY_STEPS = 5; // 500 ms 間隔の受領応答
const KEYFRAME_EVERY_STEPS = 20; // 2 秒
const AUDIO_KBPS = 128;
const AUDIO_BYTES_PER_STEP = (AUDIO_KBPS * 1000 * STEP_MS) / 1000 / 8;

interface SimChunk extends ChunkMeta {
  readonly label: string;
}

interface Scenario {
  readonly seconds: number;
  /** 回線の容量（kbps）。時刻（秒）の関数。0 は、不通 */
  readonly capacityKbps: (second: number) => number;
  readonly startTargetKbps: number;
  readonly minKbps: number;
  readonly maxKbps: number;
  /** 再接続の指示で、止める */
  readonly stopOnReconnect?: boolean;
}

interface LogEntry {
  readonly second: number;
  readonly event: string;
}

interface SimResult {
  readonly log: readonly LogEntry[];
  /** 各秒の評価のあとの目標 */
  readonly targets: readonly number[];
  /** 各秒の評価の、滞留時間（評価できなければ undefined） */
  readonly backlogs: ReadonlyArray<number | undefined>;
  readonly reconnectAtSec: number | undefined;
  readonly reconnectCause: string | undefined;
}

function simulate(scenario: Scenario): SimResult {
  const queue = new SendQueue<SimChunk>();
  const governor = new BitrateGovernor();
  const log: LogEntry[] = [];
  const targets: number[] = [];
  const backlogs: Array<number | undefined> = [];
  const inflight: Array<{ kind: "video" | "audio"; timestampUs: number; completionMs: number }> = [];

  let target = scenario.startTargetKbps;
  let degraded = false;
  let keyframePending = true;
  let linkFreeMs = 0;
  let ackedVideoUs: number | undefined;
  let ackedAudioUs: number | undefined;
  let reconnectAtSec: number | undefined;
  let reconnectCause: string | undefined;

  for (let step = 1; step <= scenario.seconds * STEPS_PER_SECOND; step += 1) {
    const nowMs = step * STEP_MS;
    const timestampUs = nowMs * 1000;

    // エンコーダ：目標ビットレートで、映像 1 チャンク（2 秒ごとと、指示のあとにキーフレーム）と、音声 1 チャンク
    const keyframe = keyframePending || step % KEYFRAME_EVERY_STEPS === 1;
    keyframePending = false;
    queue.enqueue({ label: `V${step}`, kind: "video", keyframe, timestampUs, byteLength: Math.round((target * 1000 * STEP_MS) / 1000 / 8) });
    queue.enqueue({ label: `A${step}`, kind: "audio", keyframe: false, timestampUs, byteLength: AUDIO_BYTES_PER_STEP });

    // 送信：取り出した（送信した）チャンクは、すぐに、回線の管へ入る（先入れ先出し。容量は、送り始めた時刻の値）
    for (let chunk = queue.dequeue(); chunk !== undefined; chunk = queue.dequeue()) {
      const startMs = Math.max(nowMs, linkFreeMs);
      const capacity = scenario.capacityKbps(startMs / 1000);
      const completionMs = capacity > 0 ? startMs + (chunk.byteLength * 8) / capacity : Number.POSITIVE_INFINITY;
      linkFreeMs = completionMs;
      inflight.push({ kind: chunk.kind, timestampUs: chunk.timestampUs, completionMs });
    }

    // 中継の受領応答（500 ms 間隔）：その時点で受領し終えた、映像・音声の最新のメディア時刻
    if (step % ACK_EVERY_STEPS === 0) {
      for (let index = inflight.length - 1; index >= 0; index -= 1) {
        const item = inflight[index];
        if (item.completionMs <= nowMs) {
          if (item.kind === "video") {
            ackedVideoUs = Math.max(ackedVideoUs ?? 0, item.timestampUs);
          } else {
            ackedAudioUs = Math.max(ackedAudioUs ?? 0, item.timestampUs);
          }
          inflight.splice(index, 1);
        }
      }
    }

    // 適応制御（毎秒）
    if (step % STEPS_PER_SECOND === 0) {
      const second = nowMs / 1000;
      const backlogMs = queue.backlogMs(ackedVideoUs, ackedAudioUs);
      backlogs.push(backlogMs);
      const decision = governor.evaluate({
        nowSec: second,
        backlogMs,
        dropTimesSec: queue.dropHistorySec(),
        targetKbps: target,
        minKbps: scenario.minKbps,
        maxKbps: scenario.maxKbps,
        ackedVideoUs,
        degraded,
      });
      for (const event of decision.events) {
        if (event.kind === "bitrate_down" || event.kind === "bitrate_up") {
          log.push({ second, event: `${event.kind}:${event.fromKbps}->${event.toKbps}` });
        } else {
          log.push({ second, event: event.kind });
        }
      }
      target = decision.targetKbps;
      degraded = decision.degraded;
      targets.push(target);
      if (decision.discardAllVideo) {
        queue.discardAllVideo(); // 送信待ちは空（すぐ回線の管へ渡している）。全破棄の指示は、破棄の履歴に残る
        keyframePending = decision.requestKeyframe;
      }
      if (decision.reconnect) {
        reconnectAtSec ??= second;
        reconnectCause ??= decision.reconnectCause;
        log.push({ second, event: `reconnect:${String(decision.reconnectCause)}` });
        if (scenario.stopOnReconnect === true) {
          break;
        }
      }
    }
  }
  return { log, targets, backlogs, reconnectAtSec, reconnectCause };
}

const firstAt = (result: SimResult, prefix: string, fromSec = 0): number | undefined => result.log.find((entry) => entry.event.startsWith(prefix) && entry.second >= fromSec)?.second;
const secondsOf = (result: SimResult, event: string): number[] => result.log.filter((entry) => entry.event === event).map((entry) => entry.second);
const countOf = (result: SimResult, prefix: string): number => result.log.filter((entry) => entry.event.startsWith(prefix)).length;
/** 第 second 秒の評価の、滞留時間（ミリ秒）。評価できなければ undefined。 */
const backlogAt = (result: SimResult, second: number): number | undefined => result.backlogs[second - 1];
const range = (from: number, to: number): number[] => Array.from({ length: Math.max(0, to - from + 1) }, (_, index) => from + index);
const over = (result: SimResult, seconds: readonly number[], thresholdMs: number): boolean => seconds.every((second) => (backlogAt(result, second) ?? 0) > thresholdMs);
const atMost = (result: SimResult, seconds: readonly number[], thresholdMs: number): boolean => seconds.every((second) => (backlogAt(result, second) ?? Number.POSITIVE_INFINITY) <= thresholdMs);

describe("シナリオ A：健全な回線（容量が、送出量に対して十分）", () => {
  // 容量 20,000 kbps。滞留時間は、ほぼ 100 ms（受領応答の粒度）で、いつも 0.3 秒未満。破棄が無いので、毎秒 10% 引き上げ、上限（6,000）で止まる
  const result = simulate({ seconds: 40, capacityKbps: () => 20_000, startTargetKbps: 4500, minKbps: 3000, maxKbps: 6000 });

  test("目標は、4,500 から、毎秒 10% ずつ上がり、上限 6,000 で止まる（4,500 -> 4,950 -> 5,445 -> 5,990 -> 6,000）", () => {
    expect(result.targets.slice(0, 5)).toEqual([4950, 5445, 5990, 6000, 6000]);
    expect(Math.max(...result.targets)).toBe(6000);
  });

  test("引き下げ・全破棄・劣化・再接続は、起きない", () => {
    expect(countOf(result, "bitrate_down")).toBe(0);
    expect(countOf(result, "video_dropped")).toBe(0);
    expect(countOf(result, "degraded")).toBe(0);
    expect(result.reconnectAtSec).toBeUndefined();
  });

  test("滞留時間は、受領応答の粒度の範囲（0.3 秒未満）", () => {
    expect(result.backlogs.every((backlog) => backlog !== undefined && backlog < 300)).toBe(true);
  });
});

describe("シナリオ B：回線が悪化し（容量が、上限の送出量を下回る）、回復する", () => {
  // 0 から 20 秒：容量 20,000 kbps（目標は上限 6,000 へ）。20 から 50 秒：容量 3,500 kbps。50 秒以降：容量 20,000 kbps。
  //   上限の送出量 6,128 kbps（映像 6,000 + 音声 128）を、容量 3,500 kbps の管へ入れると、滞留時間は、毎秒 約 0.43 秒ずつ増える。
  //   管の中には、引き下げの前に作った大きいチャンクが残るので、滞留時間は、引き下げのあともしばらく増え続け、4 秒を超える（その間は、全破棄が指示される）。
  //   下限の送出量 3,128 kbps は、容量 3,500 kbps より小さいので、滞留時間は、やがて減り始めるが、1.5 秒を超える状態は、回線の回復まで続く。
  // 検査は、12 章の規則を、滞留時間の系列に当てて導いた値（引き下げ・全破棄・劣化の出入り・引き上げが、規則どおりの秒に起きること）と照らす。
  const result = simulate({ seconds: 90, capacityKbps: (second) => (second >= 20 && second < 50 ? 3_500 : 20_000), startTargetKbps: 4500, minKbps: 3000, maxKbps: 6000 });

  test("悪化の前に、目標は上限に達している", () => {
    expect(result.targets[19]).toBe(6000);
  });

  test("条件 1：滞留時間が 1.5 秒を超える評価が 2 回連続した評価で、30% 引き下げる（6,000 -> 4,200）。数え直して、2 回ごとに引き下げ、下限に達する", () => {
    const firstTwice = range(21, 90).find((second) => over(result, [second - 1, second], 1500));
    expect(firstTwice).toBeDefined();
    const downs = result.log.filter((entry) => entry.event.startsWith("bitrate_down"));
    expect(downs.slice(0, 2).map((entry) => [entry.second, entry.event])).toEqual([
      [firstTwice, "bitrate_down:6000->4200"],
      [(firstTwice as number) + 2, "bitrate_down:4200->3000"],
    ]);
    expect(downs).toHaveLength(2);
  });

  test("条件 3：全破棄は、滞留時間が 4 秒を超えた評価だけで、超えた評価では毎回、指示される", () => {
    const expected = range(1, 90).filter((second) => (backlogAt(result, second) ?? 0) > 4000);
    expect(expected.length).toBeGreaterThan(0);
    expect(secondsOf(result, "video_dropped")).toEqual(expected);
  });

  test("条件 6：下限に達した評価から、逼迫（1.5 秒超）が 20 秒続いたとき、劣化に入る", () => {
    const floorSecond = result.log.find((entry) => entry.event.endsWith("->3000"))?.second as number;
    expect(over(result, range(floorSecond, floorSecond + 20), 1500)).toBe(true);
    expect(secondsOf(result, "degraded_started")).toEqual([floorSecond + 20]);
  });

  test("条件 7：回線の回復（50 秒）で、滞留時間が 1.5 秒以下に戻ってから 10 秒続いたとき、劣化が解除される", () => {
    const relaxed = range(50, 90).find((second) => (backlogAt(result, second) ?? Number.POSITIVE_INFINITY) <= 1500) as number;
    expect(atMost(result, range(relaxed, relaxed + 10), 1500)).toBe(true);
    expect(secondsOf(result, "degraded_cleared")).toEqual([relaxed + 10]);
  });

  test("条件 2：最後の全破棄から 10 秒あとで、滞留時間が 0.3 秒未満になった最初の評価から、毎秒 10% 引き上げ、上限 6,000 に戻る", () => {
    const lastDrop = Math.max(...secondsOf(result, "video_dropped"));
    const firstUp = range(50, 90).find((second) => (backlogAt(result, second) ?? Number.POSITIVE_INFINITY) < 300 && second - lastDrop >= 10) as number;
    expect(firstAt(result, "bitrate_up", 50)).toBe(firstUp);
    expect(result.log.filter((entry) => entry.event.startsWith("bitrate_up") && entry.second >= firstUp).map((entry) => entry.event)).toEqual([
      "bitrate_up:3000->3300",
      "bitrate_up:3300->3630",
      "bitrate_up:3630->3993",
      "bitrate_up:3993->4393",
      "bitrate_up:4393->4833",
      "bitrate_up:4833->5317",
      "bitrate_up:5317->5849",
      "bitrate_up:5849->6000",
    ]);
    expect(result.targets[89]).toBe(6000);
  });

  test("目標は、いつも、下限から上限の範囲。変更は、毎秒 1 回まで（1 秒に 2 つの出来事が無い）。再接続の指示は無い", () => {
    expect(result.targets.every((target) => target >= 3000 && target <= 6000)).toBe(true);
    const bitrateEventSeconds = result.log.filter((entry) => entry.event.startsWith("bitrate_")).map((entry) => entry.second);
    expect(new Set(bitrateEventSeconds).size).toBe(bitrateEventSeconds.length);
    expect(result.reconnectAtSec).toBeUndefined();
  });
});

describe("シナリオ C：下限でも足りない回線（容量が、下限の送出量をわずかに下回る）で、劣化し、回線の回復で、解除される", () => {
  // 下限 3,000 kbps から始める。0 から 60 秒：容量 2,900 kbps（下限の送出量 3,128 kbps を、わずかに下回る）。60 秒以降：容量 5,000 kbps。
  //   最初の評価（1 秒）は、滞留時間が 0.3 秒未満で破棄も無いので、目標を 3,300 へ上げる。送出量 3,428 kbps は、容量を上回り、滞留時間が増えて、10 秒ほどで引き下げられ、下限に戻る
  //   下限の送出量 3,128 kbps も、容量を上回るので、滞留時間は、毎秒 約 0.08 秒ずつ増え続け、劣化（下限で逼迫が 20 秒継続）に入り、4 秒を超えると、毎回、全破棄が指示される
  //   容量が 5,000 kbps に回復すると、滞留時間は、毎秒 約 0.6 秒ずつ減る
  const result = simulate({ seconds: 100, capacityKbps: (second) => (second < 60 ? 2_900 : 5_000), startTargetKbps: 3000, minKbps: 3000, maxKbps: 6000 });

  test("条件 6：下限に戻った評価から、逼迫が 20 秒続いたとき、劣化に入る（出来事 degraded_started は 1 回）", () => {
    const floorSecond = result.log.find((entry) => entry.event === "bitrate_down:3300->3000")?.second as number;
    expect(over(result, range(floorSecond, floorSecond + 20), 1500)).toBe(true);
    expect(secondsOf(result, "degraded_started")).toEqual([floorSecond + 20]);
  });

  test("条件 3：全破棄は、滞留時間が 4 秒を超えた評価だけで、超えた評価では毎回、指示される。それより前には、無い", () => {
    const expected = range(1, 100).filter((second) => (backlogAt(result, second) ?? 0) > 4000);
    expect(expected.length).toBeGreaterThanOrEqual(3);
    expect(secondsOf(result, "video_dropped")).toEqual(expected);
    // 超えている間は、毎回（連続）
    expect(expected.every((second, index) => index === 0 || second === expected[index - 1] + 1)).toBe(true);
  });

  test("条件 7：回線の回復（60 秒）のあと、滞留時間が 1.5 秒以下に戻ってから 10 秒続いたとき、劣化が解除される（出来事は 1 回）", () => {
    const relaxed = range(60, 100).find((second) => (backlogAt(result, second) ?? Number.POSITIVE_INFINITY) <= 1500) as number;
    expect(atMost(result, range(relaxed, relaxed + 10), 1500)).toBe(true);
    expect(secondsOf(result, "degraded_cleared")).toEqual([relaxed + 10]);
  });

  test("条件 2：最後の全破棄から 10 秒のあいだは、目標を引き上げない。10 秒経って、滞留時間が 0.3 秒未満になった最初の評価から、引き上げる", () => {
    const lastDrop = Math.max(...secondsOf(result, "video_dropped"));
    const upsAfterDrop = result.log.filter((entry) => entry.event.startsWith("bitrate_up") && entry.second > lastDrop);
    const firstUp = range(lastDrop + 1, 100).find((second) => (backlogAt(result, second) ?? Number.POSITIVE_INFINITY) < 300 && second - lastDrop >= 10) as number;
    expect(upsAfterDrop[0].second).toBe(firstUp);
    expect(firstUp).toBeGreaterThanOrEqual(lastDrop + 10);
  });

  test("再接続の指示は無い（滞留時間は 8 秒を超えない）。目標は、いつも、下限から上限の範囲", () => {
    expect(result.reconnectAtSec).toBeUndefined();
    expect(Math.max(...result.backlogs.map((backlog) => backlog ?? 0))).toBeLessThan(8000);
    expect(result.targets.every((target) => target >= 3000 && target <= 6000)).toBe(true);
  });
});

describe("シナリオ D：回線の不通（受領応答が止まる）", () => {
  // 30 秒まで、容量 20,000 kbps。30 秒以降、不通（何も届かない）。受領済みの映像の時刻が、30 秒ごろから進まない -> 10 秒後に再接続（条件 4）。
  //   滞留時間は、30 秒から毎秒 1 秒ずつ増え、4 秒を超える 34 秒ごろから全破棄の指示。8 秒の継続（条件 5）は、条件 4 より遅い
  const result = simulate({ seconds: 60, capacityKbps: (second) => (second < 30 ? 20_000 : 0), startTargetKbps: 4500, minKbps: 3000, maxKbps: 6000, stopOnReconnect: true });

  test("受領応答が止まって 10 秒後（40 から 42 秒）に、再接続が指示される。原因は、映像の受領済み時刻が進まないこと", () => {
    expect(result.reconnectAtSec).toBeDefined();
    expect(result.reconnectAtSec as number).toBeGreaterThanOrEqual(40);
    expect(result.reconnectAtSec as number).toBeLessThanOrEqual(42);
    expect(result.reconnectCause).toBe("video_ack_stalled");
  });

  test("再接続の前に、滞留時間が 4 秒を超えて、全破棄が指示されている。劣化には、至らない", () => {
    const firstDrop = firstAt(result, "video_dropped");
    expect(firstDrop).toBeDefined();
    expect(firstDrop as number).toBeGreaterThanOrEqual(33);
    expect(firstDrop as number).toBeLessThan(result.reconnectAtSec as number);
    expect(countOf(result, "degraded")).toBe(0);
  });
});

describe("シナリオ E：受領応答が、1 つも来ない接続", () => {
  // 最初から不通。受領応答が無い間は、滞留時間を評価しない（undefined）ので、目標の変更も、全破棄も、劣化も無い。
  // ただし、条件 4 は、最初の評価（1 秒）から数えるので、11 秒に再接続が指示される
  const result = simulate({ seconds: 30, capacityKbps: () => 0, startTargetKbps: 4500, minKbps: 3000, maxKbps: 6000, stopOnReconnect: true });

  test("滞留時間は、評価できない（undefined）。0 として扱わない", () => {
    expect(result.backlogs.every((backlog) => backlog === undefined)).toBe(true);
  });

  test("目標の変更・全破棄・劣化は無く、最初の評価から 10 秒後（11 秒）に、再接続が指示される", () => {
    expect(result.log.map((entry) => entry.event)).toEqual(["reconnect:video_ack_stalled"]);
    expect(result.reconnectAtSec).toBe(11);
    expect(result.targets.every((target) => target === 4500)).toBe(true);
  });
});

describe("決定的：同じシナリオは、毎回、同じ結果", () => {
  test("シナリオ C を 2 回実行して、出来事の記録・目標・滞留時間が、一致する", () => {
    const scenario: Scenario = { seconds: 100, capacityKbps: (second) => (second < 60 ? 2_900 : 5_000), startTargetKbps: 3000, minKbps: 3000, maxKbps: 6000 };
    expect(JSON.stringify(simulate(scenario))).toBe(JSON.stringify(simulate(scenario)));
  });
});
