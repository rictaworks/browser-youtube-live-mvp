/**
 * @jest-environment node
 */
// LagGuard（requirements.md 11.6・12・27。issue #27）。ワーカーが音声のブロックの処理に遅れていること（処理待ちが積み上がっていること）を検知する。
//
// 背景: 音声のブロック（128 サンプル = 約 2.9 ミリ秒）は、音声のスレッドから、一定の間隔で、ワーカーへ直接届く。ワーカーが 1 フレームの合成に時間を取られる
// （GPU が無い環境・負荷の高い端末）と、その間に届いたブロックがポートの待ちに積み上がり、あとでまとめて（続けて）処理される。
// 合成を毎回行うと、遅れを取り戻せず、待ちが増え続ける（停止などの制御メッセージも、待ちの後ろに回る）。そこで、遅れている間は、合成を飛ばす
// （映像のフレーム番号は、音声の累積サンプル数から決まるので、飛ばしても時刻は正しい。符号化の前に捨てるので、参照の連鎖を壊さない）。
//
// 検知の方法: 待ちの深さを推定する。ブロックのイベントの timeStamp（ワーカーが処理を始めた時刻。実測で確認済み: 待ちの間に積み上がったイベントは、
// 処理が始まった時刻の値を持つ）の進みと、音声の累積サンプル数の進み（ブロックが作られた時刻の進み）の差が、待ちの深さの変化になる。
// 差の最小値を基準（待ちが無いときの値）として、基準からの超過が、待ちの深さ。
// 待ちが ENTER（100 ミリ秒）を超えたら遅れ、EXIT（30 ミリ秒）を下回ったら戻る（ヒステリシス）。
// 旧方式（続けて処理された塊の長さ）は、遅れの原因である合成そのものが、塊の連続を断ち切るため、検知できなかった（実測で確認）。
import { BACKLOG_DRIFT_ALLOWANCE, BACKLOG_ENTER_MS, BACKLOG_EXIT_MS, BACKLOG_MAX_BEHIND_MS } from "@/lib/pipeline/config";
import { LagGuard } from "./LagGuard";

const BLOCK_FRAMES = 128;
const SAMPLE_RATE = 44_100;
const PERIOD_MS = (BLOCK_FRAMES * 1000) / SAMPLE_RATE;
const START_MS = 1000;

/** ブロック index が作られた時刻に、waitMs だけ待たされて、処理が始まった時刻。 */
function stampOf(index: number, waitMs: number): number {
  return START_MS + index * PERIOD_MS + waitMs;
}

function run(guard: LagGuard, count: number, waitOf: (index: number) => number, firstIndex = 0): boolean[] {
  return Array.from({ length: count }, (_unused, offset) => guard.observe(stampOf(firstIndex + offset, waitOf(firstIndex + offset)), BLOCK_FRAMES));
}

describe("遅れていない", () => {
  it("周期どおりに処理される（待ちが一定）: 遅れではない。待ちの深さは 0", () => {
    const guard = new LagGuard();

    const results = run(guard, 400, () => 5);

    expect(results.every((behind) => !behind)).toBe(true);
    expect(guard.backlogMs).toBe(0);
  });

  it("待ちのゆらぎ（0 から 30 ミリ秒）があっても、遅れではない", () => {
    const guard = new LagGuard();

    const results = run(guard, 600, (index) => (index * 7) % 31);

    expect(results.every((behind) => !behind)).toBe(true);
    expect(guard.backlogMs).toBeLessThanOrEqual(30);
  });

  it("最初のブロックは、基準になる。遅れではない（比べる相手が無い）", () => {
    expect(new LagGuard().observe(123.4, BLOCK_FRAMES)).toBe(false);
  });

  it("1 回の合成に 40 ミリ秒かかった程度（映像 1 フレーム強）では、遅れとしない", () => {
    const guard = new LagGuard();
    run(guard, 20, () => 0);

    // 40 ミリ秒の塞がりのあと、続けて処理されて、待ちが解ける
    const results = run(guard, 40, (index) => Math.max(0, 40 - (index - 20) * (PERIOD_MS - 0.5)), 20);

    expect(results.every((behind) => !behind)).toBe(true);
  });
});

describe("待ちが積み上がった（1 回の処理が長くかかった）", () => {
  /** 20 ブロックは周期どおり。そのあと stallMs の塞がり。以後は、1 ブロック 0.5 ミリ秒で続けて処理して、待ちを解く。 */
  function stallThenDrain(guard: LagGuard, stallMs: number): { flags: boolean[]; waits: number[] } {
    run(guard, 20, () => 0);
    const flags: boolean[] = [];
    const waits: number[] = [];
    let previousStamp = stampOf(19, 0);
    for (let index = 20; index < 20 + 400; index += 1) {
      const produced = stampOf(index, 0);
      const stamp = index === 20 ? produced + stallMs : Math.max(produced, previousStamp + 0.5);
      waits.push(stamp - produced);
      flags.push(guard.observe(stamp, BLOCK_FRAMES));
      previousStamp = stamp;
    }
    return { flags, waits };
  }

  it("400 ミリ秒の塞がりのあと: 最初のブロックから遅れ。待ちが 30 ミリ秒を下回るまで続き、そのあと戻る", () => {
    const guard = new LagGuard();

    const { flags, waits } = stallThenDrain(guard, 400);

    expect(flags[0]).toBe(true);
    flags.forEach((behind, index) => {
      if (waits[index] > BACKLOG_EXIT_MS + 1) {
        expect(behind).toBe(true);
      }
      if (waits[index] < BACKLOG_EXIT_MS - 1) {
        expect(behind).toBe(false);
      }
    });
    expect(flags[flags.length - 1]).toBe(false);
    // 戻ったあとは、再び遅れにならない
    const firstFalse = flags.indexOf(false);
    expect(flags.slice(firstFalse).every((behind) => !behind)).toBe(true);
    // 待ちを解くのに、塞がりの長さに比例した数のブロックがかかる（400 ミリ秒 = 約 138 ブロック分が、0.5 ミリ秒ずつで解ける）
    expect(firstFalse).toBeGreaterThan(100);
    expect(firstFalse).toBeLessThan(200);
  });

  it("待ちの深さを返す: 塞がりの直後は、塞がりの長さに近い", () => {
    const guard = new LagGuard();

    stallThenDrain(guard, 400);

    // 最後は解けている
    expect(guard.backlogMs).toBeLessThan(BACKLOG_EXIT_MS);
    const second = new LagGuard();
    run(second, 20, () => 0);
    second.observe(stampOf(20, 400), BLOCK_FRAMES);
    expect(second.backlogMs).toBeGreaterThan(395);
    expect(second.backlogMs).toBeLessThan(405);
  });

  it("待ちが ENTER 未満（60 ミリ秒）だけなら、入らない", () => {
    const guard = new LagGuard();
    run(guard, 20, () => 0);

    const results = run(guard, 50, () => 60, 20);

    expect(BACKLOG_ENTER_MS).toBeGreaterThan(60);
    expect(results.every((behind) => !behind)).toBe(true);
  });

  it("入ったあと、待ちが ENTER と EXIT の間（60 ミリ秒）まで減っても、EXIT を下回るまでは遅れのまま（ヒステリシス）", () => {
    const guard = new LagGuard();
    run(guard, 20, () => 0);
    // 待ちは、1 ブロックあたり (周期 - 処理時間) より速くは減らない（時刻は逆行しない）。150 ミリ秒 -> 60 ミリ秒 -> 少し保つ -> 10 ミリ秒
    const waits: number[] = [150, 150, 150];
    const drain = (to: number): void => {
      while (waits[waits.length - 1] > to) {
        waits.push(Math.max(to, waits[waits.length - 1] - (PERIOD_MS - 0.5)));
      }
    };
    drain(60);
    const holdStart = waits.length;
    waits.push(60, 60, 60, 60, 60);
    const holdEnd = waits.length;
    drain(10);
    const results = run(guard, waits.length, (index) => waits[index - 20], 20);

    expect(results.slice(0, holdEnd).every((behind) => behind)).toBe(true);
    expect(holdEnd - holdStart).toBe(5);
    waits.forEach((wait, index) => {
      if (index >= holdEnd) {
        expect(results[index]).toBe(wait >= BACKLOG_EXIT_MS);
      }
    });
    expect(results[results.length - 1]).toBe(false);
  });
});

describe("基準のずれ", () => {
  it("音声のクロックが実時間より 300 ppm 遅い（10 分間）: 遅れと誤判定しない（基準が追従する）", () => {
    const guard = new LagGuard();
    const blocks = Math.round((600 * SAMPLE_RATE) / BLOCK_FRAMES);
    let behindCount = 0;

    for (let index = 0; index < blocks; index += 1) {
      const produced = START_MS + index * PERIOD_MS;
      if (guard.observe(produced * (1 + 300e-6), BLOCK_FRAMES)) {
        behindCount += 1;
      }
    }

    expect(BACKLOG_DRIFT_ALLOWANCE).toBeGreaterThan(300e-6);
    expect(behindCount).toBe(0);
  });

  it("基準が急にずれた（5 秒。停止・再開の通知が無い）: 遅れの状態は BACKLOG_MAX_BEHIND_MS で打ち切り、新しい基準にする", () => {
    const guard = new LagGuard();
    run(guard, 50, () => 0);

    const results = run(guard, Math.ceil(((BACKLOG_MAX_BEHIND_MS + 2000) * SAMPLE_RATE) / 1000 / BLOCK_FRAMES), () => 5000, 50);

    expect(results[0]).toBe(true);
    const behindMs = results.filter((behind) => behind).length * PERIOD_MS;
    expect(behindMs).toBeGreaterThanOrEqual(BACKLOG_MAX_BEHIND_MS - PERIOD_MS * 2);
    expect(behindMs).toBeLessThanOrEqual(BACKLOG_MAX_BEHIND_MS + PERIOD_MS * 2);
    expect(results[results.length - 1]).toBe(false);
    expect(guard.backlogMs).toBeLessThan(BACKLOG_EXIT_MS);
  });
});

describe("入力が信用できないとき: 遅れとしない（継続側）", () => {
  it.each([
    ["undefined", undefined],
    ["NaN", Number.NaN],
    ["文字列", "12"],
    ["無限大", Number.POSITIVE_INFINITY],
    ["null", null],
  ])("timeStamp が %s", (_name, stamp) => {
    const guard = new LagGuard();
    run(guard, 20, () => 0);

    expect(guard.observe(stamp, BLOCK_FRAMES)).toBe(false);
    expect(guard.observe(stamp, BLOCK_FRAMES)).toBe(false);
  });

  it.each([0, -1, 1.5, Number.NaN])("ブロックのサンプル数が %s", (frames) => {
    expect(new LagGuard().observe(1000, frames)).toBe(false);
  });

  it("時刻が逆行したら（異なるポートなどで起こり得る）、基準をやり直す。遅れとしない", () => {
    const guard = new LagGuard();
    run(guard, 20, () => 0);
    guard.observe(stampOf(20, 500), BLOCK_FRAMES);

    expect(guard.observe(10, BLOCK_FRAMES)).toBe(false);
    expect(guard.backlogMs).toBe(0);
  });

  it("timeStamp が欠けたら、基準をやり直す（欠けた前後を、続いたものとして数えない）", () => {
    const guard = new LagGuard();
    run(guard, 20, () => 0);
    guard.observe(undefined, BLOCK_FRAMES);

    // 欠けたあとの最初のブロックは、新しい基準。大きな時刻のずれがあっても、遅れとしない
    expect(guard.observe(stampOf(20, 800), BLOCK_FRAMES)).toBe(false);
    expect(run(guard, 10, () => 800, 21).every((behind) => !behind)).toBe(true);
  });
});

describe("reset", () => {
  it("基準と待ちの状態を忘れる（新しい配信・新しいポートの最初から・音声の停止と再開）", () => {
    const guard = new LagGuard();
    run(guard, 20, () => 0);
    expect(guard.observe(stampOf(20, 500), BLOCK_FRAMES)).toBe(true);

    guard.reset();

    expect(guard.backlogMs).toBe(0);
    expect(guard.observe(stampOf(21, 900), BLOCK_FRAMES)).toBe(false);
    expect(run(guard, 10, () => 900, 22).every((behind) => !behind)).toBe(true);
  });
});

describe("待ちのモデルでの収束（合成が遅い環境の疑似）", () => {
  /**
   * ワーカーを 1 つのスレッドの待ち行列として疑似する。ブロックは周期どおりに作られ、ワーカーは順に処理する。
   * 1 ブロックの処理は baseMs。映像のフレームの境界（1,470 サンプルごと）では、遅れていなければ、合成に composeMs かかる。
   * timeStamp は、処理を始めた時刻。待ち = 処理を始めた時刻 - 作られた時刻。
   */
  function simulate(composeMs: number, seconds: number, guard = new LagGuard()) {
    const baseMs = 0.5;
    const blocks = Math.round((seconds * SAMPLE_RATE) / BLOCK_FRAMES);
    let finished = 0;
    let samples = 0;
    let frameIndex = 0;
    let composed = 0;
    let skipped = 0;
    const waits: number[] = [];
    for (let index = 0; index < blocks; index += 1) {
      const produced = START_MS + index * PERIOD_MS;
      const started = Math.max(produced, finished);
      const behind = guard.observe(started, BLOCK_FRAMES);
      samples += BLOCK_FRAMES;
      const due = Math.floor(samples / 1470) - frameIndex;
      frameIndex += due;
      let duration = baseMs;
      if (due > 0) {
        if (behind) {
          skipped += due;
        } else {
          composed += due;
          duration += composeMs * due;
        }
      }
      finished = started + duration;
      waits.push(started - produced);
    }
    return { composed, skipped, waits };
  }

  it("合成が速い（10 ミリ秒）: 1 フレームも飛ばさない。待ちは小さい", () => {
    const { composed, skipped, waits } = simulate(10, 20);

    expect(skipped).toBe(0);
    expect(composed).toBe(Math.floor((20 * SAMPLE_RATE) / 1470));
    expect(Math.max(...waits)).toBeLessThan(30);
  });

  it("合成が遅い（400 ミリ秒。フレームの周期の 12 倍）: 待ちは積み上がり続けず、1 秒未満に収まる。合成は続く（飛ばしながら）", () => {
    const { composed, skipped, waits } = simulate(400, 30);

    const afterWarmUp = waits.slice(Math.floor(waits.length / 5));
    expect(Math.max(...afterWarmUp)).toBeLessThan(1000);
    expect(composed).toBeGreaterThanOrEqual(30);
    expect(skipped).toBeGreaterThan(composed);
  });

  it("合成が非常に遅い（3 秒）: 待ちは 4 秒未満に収まる（制御メッセージは、待ちの深さの分だけ遅れて処理される）", () => {
    const { waits } = simulate(3000, 60);

    expect(Math.max(...waits)).toBeLessThan(4000);
  });
});
