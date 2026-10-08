/**
 * @jest-environment node
 */
// ReportBuilder（requirements.md 11.9・18.1、ws-protocol.md の 5.6）：1 秒間隔の状態報告（report）の本文を組み立てる。
//   本文 = 滞留時間・破棄フレーム数・目標ビットレート・状態（live・degraded）・ブラウザ側の出来事
//   出来事は、欠落なく 1 回ずつ送る（キューへ積み、送信済みを除く）。detail は、符号と数値のみ（自由記述・デバイス名・ラベルを載せない）
//   送信は、2 段階：prepare（本文を作る。出来事は、待ちに残す）-> 送信できたら commit（載せた出来事を、待ちから外す）。送信できなければ commit しない
//   （次の prepare が、同じ出来事を、もう一度載せる）。これで、送信の失敗で出来事が欠けず、成功した報告の出来事は、重複しない。
import { BitrateGovernor } from "../governor";
import { Problems, seededRandom } from "../testing/helpers";
import { FrameCodec, decodeRawFrame, parseReportBody } from "../transport";
import type { ReportEvent } from "../transport";
import { DEFAULT_MAX_EVENTS_PER_REPORT, ReportBuilder } from "./ReportBuilder";
import type { BrowserEvent } from "./types";

const LIVE = { backlogMs: 120, droppedVideoFrames: 0, targetKbps: 4500, state: "live" } as const;

/** 本文を、契約のワイヤの形（キーの順まで）の JSON 文字列にする。 */
const wire = (body: unknown): string => JSON.stringify(body);

describe("契約の共有テストベクタ（ws-frame-vectors.json の report_*）と、同じ本文を作る", () => {
  test("report_live：出来事なし", () => {
    const builder = new ReportBuilder();
    expect(wire(builder.prepare(LIVE).body)).toBe('{"backlog_ms":120,"dropped_video_frames":0,"target_kbps":4500,"state":"live","events":[]}');
  });

  test("report_degraded_with_events：引き下げ・映像の破棄（12 フレーム）・劣化の開始", () => {
    const builder = new ReportBuilder();
    builder.record({ kind: "bitrate_down", fromKbps: 3300, toKbps: 3000 });
    builder.record({ kind: "video_dropped", frames: 12 });
    builder.record({ kind: "degraded_started" });
    const body = builder.prepare({ backlogMs: 1800, droppedVideoFrames: 12, targetKbps: 3000, state: "degraded" }).body;
    expect(wire(body)).toBe(
      '{"backlog_ms":1800,"dropped_video_frames":12,"target_kbps":3000,"state":"degraded","events":[{"kind":"bitrate_down","detail":{"from_kbps":3300,"to_kbps":3000}},{"kind":"video_dropped","detail":{"frames":12}},{"kind":"degraded_started"}]}',
    );
  });

  test("report_source_events：ソースの喪失と、代替の切替", () => {
    const builder = new ReportBuilder();
    builder.record({ kind: "source_lost", source: "camera" });
    builder.record({ kind: "fallback_switched", layout: "screen_only" });
    const body = builder.prepare({ backlogMs: 40, droppedVideoFrames: 0, targetKbps: 4500, state: "live" }).body;
    expect(wire(body)).toBe(
      '{"backlog_ms":40,"dropped_video_frames":0,"target_kbps":4500,"state":"live","events":[{"kind":"source_lost","detail":{"source":"camera"}},{"kind":"fallback_switched","detail":{"layout":"screen_only"}}]}',
    );
  });

  test("FrameCodec で符号化でき、復号した本文が、組み立てた本文と同じ（ワイヤとして正しい）", () => {
    const builder = new ReportBuilder();
    builder.record({ kind: "bitrate_up", fromKbps: 3000, toKbps: 3300 });
    const { body } = builder.prepare(LIVE);
    const frame = new FrameCodec().encode({ type: "report", body });
    const raw = decodeRawFrame(frame, "browser_to_relay");
    expect(raw.type).toBe("report");
    expect(new TextDecoder().decode(raw.body)).toBe(wire(body));
  });
});

describe("出来事 8 種の、detail（符号と数値のみ）", () => {
  const table: ReadonlyArray<readonly [BrowserEvent, string]> = [
    [{ kind: "source_added", source: "screen" }, '{"kind":"source_added","detail":{"source":"screen"}}'],
    [{ kind: "source_lost", source: "shared_audio" }, '{"kind":"source_lost","detail":{"source":"shared_audio"}}'],
    [{ kind: "fallback_switched", layout: "slate" }, '{"kind":"fallback_switched","detail":{"layout":"slate"}}'],
    [{ kind: "bitrate_down", fromKbps: 4500, toKbps: 3150 }, '{"kind":"bitrate_down","detail":{"from_kbps":4500,"to_kbps":3150}}'],
    [{ kind: "bitrate_up", fromKbps: 3000, toKbps: 3300 }, '{"kind":"bitrate_up","detail":{"from_kbps":3000,"to_kbps":3300}}'],
    [{ kind: "video_dropped", frames: 12 }, '{"kind":"video_dropped","detail":{"frames":12}}'],
    [{ kind: "video_dropped", frames: 0 }, '{"kind":"video_dropped","detail":{"frames":0}}'],
    [{ kind: "video_dropped" }, '{"kind":"video_dropped"}'],
    [{ kind: "degraded_started" }, '{"kind":"degraded_started"}'],
    [{ kind: "degraded_cleared" }, '{"kind":"degraded_cleared"}'],
  ];

  test.each(table)("%j -> %s", (event, expected) => {
    const builder = new ReportBuilder();
    builder.record(event);
    expect(wire(builder.prepare(LIVE).body.events[0])).toBe(expected);
  });

  test("ソース 5 種・レイアウト 4 種のすべてが、符号として、載る", () => {
    const builder = new ReportBuilder();
    for (const source of ["camera", "screen", "microphone", "shared_audio", "slate"] as const) {
      builder.record({ kind: "source_added", source });
    }
    for (const layout of ["screen_with_wipe", "screen_only", "camera_only", "slate"] as const) {
      builder.record({ kind: "fallback_switched", layout });
    }
    expect(builder.prepare(LIVE).body.events).toHaveLength(9);
  });
});

describe("出来事の検査：自由記述・不正な値は、待ちに積まず、RangeError（デバイス名・ラベルが、報告へ入らない）", () => {
  test.each([
    ["ソースがデバイス名（空白・大文字を含む）", { kind: "source_lost", source: "Front Camera (USB 0123)" }],
    ["ソースが列挙にない符号", { kind: "source_added", source: "webcam" }],
    ["ソースが無い", { kind: "source_lost" }],
    ["ソースが数値", { kind: "source_lost", source: 1 }],
    ["レイアウトが列挙にない符号", { kind: "fallback_switched", layout: "grid" }],
    ["レイアウトが文字列でない", { kind: "fallback_switched", layout: null }],
    ["引き下げ：引き下げ前が 0", { kind: "bitrate_down", fromKbps: 0, toKbps: 1 }],
    ["引き下げ：結果が引き下げ前以上（下がっていない）", { kind: "bitrate_down", fromKbps: 3000, toKbps: 3000 }],
    ["引き下げ：結果が引き下げ前より大きい", { kind: "bitrate_down", fromKbps: 3000, toKbps: 3100 }],
    ["引き上げ：結果が引き上げ前以下", { kind: "bitrate_up", fromKbps: 3000, toKbps: 3000 }],
    ["引き上げ：結果が引き上げ前より小さい", { kind: "bitrate_up", fromKbps: 3000, toKbps: 2900 }],
    ["引き上げ：小数", { kind: "bitrate_up", fromKbps: 3000.5, toKbps: 3300 }],
    ["引き上げ：NaN", { kind: "bitrate_up", fromKbps: 3000, toKbps: Number.NaN }],
    ["引き下げ：文字列", { kind: "bitrate_down", fromKbps: "3000", toKbps: 2000 }],
    ["映像の破棄：負", { kind: "video_dropped", frames: -1 }],
    ["映像の破棄：小数", { kind: "video_dropped", frames: 1.5 }],
    ["映像の破棄：安全整数を超える", { kind: "video_dropped", frames: Number.MAX_SAFE_INTEGER + 1 }],
    ["未知の種別", { kind: "throttle_directed" }],
    ["種別が無い", {}],
    ["オブジェクトでない", "degraded_started"],
    ["null", null],
  ])("%s", (_label, event) => {
    const builder = new ReportBuilder();
    expect(() => builder.record(event as unknown as BrowserEvent)).toThrow(RangeError);
    expect(builder.pendingEvents).toBe(0);
  });

  test("型にない余計なプロパティ（デバイス名・ラベル・自由記述）は、報告に載せない", () => {
    const builder = new ReportBuilder();
    builder.record({ kind: "source_lost", source: "camera", deviceLabel: "Secret Cam", note: "free text", detail: { leak: "x" } } as unknown as BrowserEvent);
    const text = wire(builder.prepare(LIVE).body);
    expect(text).toContain('"source":"camera"');
    expect(text).not.toMatch(/Secret|free text|leak|deviceLabel|note/);
  });
});

describe("出来事は、欠落なく 1 回ずつ送る（prepare -> 送信 -> commit）", () => {
  const e1: BrowserEvent = { kind: "source_added", source: "camera" };
  const e2: BrowserEvent = { kind: "bitrate_down", fromKbps: 4500, toKbps: 3150 };
  const e3: BrowserEvent = { kind: "degraded_started" };

  test("commit した出来事は、次の報告に載らない。新しい出来事だけが載る。順序は、積んだ順", () => {
    const builder = new ReportBuilder();
    builder.record(e1);
    builder.record(e2);
    const first = builder.prepare(LIVE);
    expect(first.body.events.map((event) => event.kind)).toEqual(["source_added", "bitrate_down"]);
    builder.commit(first);
    expect(builder.pendingEvents).toBe(0);
    expect(builder.prepare(LIVE).body.events).toEqual([]);
    builder.record(e3);
    const next = builder.prepare(LIVE);
    expect(next.body.events.map((event) => event.kind)).toEqual(["degraded_started"]);
    builder.commit(next);
    expect(builder.pendingEvents).toBe(0);
  });

  test("送信できなかった（commit しない）報告の出来事は、次の報告に、もう一度載る（欠けない）。載った順のまま、新しい出来事が後ろに続く", () => {
    const builder = new ReportBuilder();
    builder.record(e1);
    builder.record(e2);
    builder.prepare(LIVE); // 送信に失敗した（commit しない）
    builder.record(e3);
    const retry = builder.prepare(LIVE);
    expect(retry.body.events.map((event) => event.kind)).toEqual(["source_added", "bitrate_down", "degraded_started"]);
    builder.commit(retry);
    expect(builder.prepare(LIVE).body.events).toEqual([]);
  });

  test("prepare から commit までのあいだに積んだ出来事は、待ちに残り、次の報告に載る（載せていないものを、外さない）", () => {
    const builder = new ReportBuilder();
    builder.record(e1);
    const report = builder.prepare(LIVE);
    builder.record(e2);
    builder.commit(report);
    expect(builder.pendingEvents).toBe(1);
    expect(builder.prepare(LIVE).body.events.map((event) => event.kind)).toEqual(["bitrate_down"]);
  });

  test("出来事の数が上限（既定 50）を超えるとき、報告を分ける：欠落なく・重複なく・順序どおりに、すべて届く", () => {
    expect(DEFAULT_MAX_EVENTS_PER_REPORT).toBe(50);
    const builder = new ReportBuilder();
    for (let index = 1; index <= 120; index += 1) {
      builder.record({ kind: "video_dropped", frames: index });
    }
    const delivered: number[] = [];
    const sizes: number[] = [];
    for (let guard = 0; guard < 10 && builder.pendingEvents > 0; guard += 1) {
      const report = builder.prepare(LIVE);
      sizes.push(report.body.events.length);
      for (const event of report.body.events) {
        delivered.push((event.detail as { frames: number }).frames);
      }
      builder.commit(report);
    }
    expect(sizes).toEqual([50, 50, 20]);
    expect(delivered).toEqual(Array.from({ length: 120 }, (_, index) => index + 1));
  });

  test("上限を指定できる。不正な上限は RangeError", () => {
    const builder = new ReportBuilder({ maxEventsPerReport: 2 });
    for (let index = 1; index <= 5; index += 1) {
      builder.record({ kind: "video_dropped", frames: index });
    }
    expect(builder.prepare(LIVE).body.events).toHaveLength(2);
    expect(() => new ReportBuilder({ maxEventsPerReport: 0 })).toThrow(RangeError);
    expect(() => new ReportBuilder({ maxEventsPerReport: 1.5 })).toThrow(RangeError);
  });

  test("古い報告・commit 済みの報告・作っていない報告の commit は、RangeError（二重に外さない）", () => {
    const builder = new ReportBuilder();
    builder.record(e1);
    builder.record(e2);
    const stale = builder.prepare(LIVE);
    const latest = builder.prepare(LIVE);
    expect(() => builder.commit(stale)).toThrow(RangeError);
    builder.commit(latest);
    expect(() => builder.commit(latest)).toThrow(RangeError);
    expect(() => builder.commit({ body: stale.body, eventCount: 99, sequence: 12_345 })).toThrow(RangeError);
    expect(() => builder.commit(null as never)).toThrow(RangeError);
    expect(builder.pendingEvents).toBe(0);
  });

  test("commit に渡す報告の eventCount を書き換えても、載せた数は、ビルダーが持つ値で外す", () => {
    const builder = new ReportBuilder();
    builder.record(e1);
    builder.record(e2);
    const report = builder.prepare(LIVE);
    builder.commit({ ...report, eventCount: 1 });
    expect(builder.pendingEvents).toBe(0);
  });

  test("prepare が返す本文は、変更できない（凍結）。毎回、新しいオブジェクト。ビルダーの待ちとは別（commit しても、返した本文は変わらない）", () => {
    const builder = new ReportBuilder();
    builder.record(e1);
    const first = builder.prepare(LIVE);
    expect(Object.isFrozen(first.body)).toBe(true);
    expect(Object.isFrozen(first.body.events)).toBe(true);
    expect(Object.isFrozen(first.body.events[0])).toBe(true);
    expect(Object.isFrozen(first)).toBe(true);
    const second = builder.prepare(LIVE);
    expect(second).not.toBe(first);
    expect(second.body).not.toBe(first.body);
    builder.commit(second);
    expect(first.body.events).toHaveLength(1);
  });
});

describe("prepare が返す本文の凍結は、入れ子（出来事の配列・各出来事・detail）まで届く", () => {
  test("どの階層も、書き換えられない（受け取った側が、本文を書き換えて、待ちの出来事や次の報告を壊せない）", () => {
    const builder = new ReportBuilder();
    builder.record({ kind: "bitrate_down", fromKbps: 3300, toKbps: 3000 });
    builder.record({ kind: "degraded_started" });
    const { body } = builder.prepare(LIVE);
    const [withDetail, withoutDetail] = body.events;
    expect(Object.isFrozen(body)).toBe(true);
    expect(Object.isFrozen(body.events)).toBe(true);
    expect(Object.isFrozen(withDetail)).toBe(true);
    expect(Object.isFrozen(withDetail.detail)).toBe(true);
    expect(Object.isFrozen(withoutDetail)).toBe(true);
    expect(() => {
      (body as { backlog_ms: number }).backlog_ms = 1;
    }).toThrow(TypeError);
    expect(() => {
      (body.events as ReportEvent[]).push({ kind: "degraded_cleared" });
    }).toThrow(TypeError);
    expect(() => {
      (withDetail as { kind: string }).kind = "video_dropped";
    }).toThrow(TypeError);
    expect(() => {
      (withDetail.detail as { from_kbps: number }).from_kbps = 1;
    }).toThrow(TypeError);
    expect(wire(body)).toBe(
      '{"backlog_ms":120,"dropped_video_frames":0,"target_kbps":4500,"state":"live","events":[{"kind":"bitrate_down","detail":{"from_kbps":3300,"to_kbps":3000}},{"kind":"degraded_started"}]}',
    );
  });

  test("本文は、待ちの出来事とも、渡された snapshot とも共有しない（本文を壊しても、次の prepare に影響しない）", () => {
    const builder = new ReportBuilder();
    builder.record({ kind: "bitrate_up", fromKbps: 3000, toKbps: 3300 });
    const first = builder.prepare(LIVE);
    const second = builder.prepare(LIVE);
    expect(second.body.events[0]).not.toBe(first.body.events[0]);
    expect(second.body.events[0].detail).not.toBe(first.body.events[0].detail);
    expect(wire(second.body)).toBe(wire(first.body));
  });
});

describe("滞留時間・破棄フレーム数・目標ビットレート・状態", () => {
  test("滞留時間は、ミリ秒の整数（四捨五入）。評価できない（undefined）ときは、0 を載せる（契約は 0 以上の整数を必須とするため）", () => {
    const builder = new ReportBuilder();
    const backlogOf = (backlogMs: number | undefined): number => builder.prepare({ ...LIVE, backlogMs }).body.backlog_ms;
    expect(backlogOf(1499.4)).toBe(1499);
    expect(backlogOf(1499.5)).toBe(1500);
    expect(backlogOf(1500)).toBe(1500);
    expect(backlogOf(0)).toBe(0);
    expect(backlogOf(0.4)).toBe(0);
    expect(backlogOf(undefined)).toBe(0);
  });

  test("状態は live・degraded（配信中の 2 つ）", () => {
    const builder = new ReportBuilder();
    expect(builder.prepare({ ...LIVE, state: "live" }).body.state).toBe("live");
    expect(builder.prepare({ ...LIVE, state: "degraded" }).body.state).toBe("degraded");
  });

  test.each([
    ["滞留時間が負", { backlogMs: -1 }],
    ["滞留時間が NaN", { backlogMs: Number.NaN }],
    ["滞留時間が無限大", { backlogMs: Number.POSITIVE_INFINITY }],
    ["滞留時間が文字列", { backlogMs: "100" }],
    ["滞留時間が null", { backlogMs: null }],
    ["破棄フレーム数が負", { droppedVideoFrames: -1 }],
    ["破棄フレーム数が小数", { droppedVideoFrames: 1.5 }],
    ["破棄フレーム数が安全整数を超える", { droppedVideoFrames: Number.MAX_SAFE_INTEGER + 1 }],
    ["目標ビットレートが 0", { targetKbps: 0 }],
    ["目標ビットレートが小数", { targetKbps: 4500.5 }],
    ["目標ビットレートが NaN", { targetKbps: Number.NaN }],
    ["状態が配信中でない（reconnecting）", { state: "reconnecting" }],
    ["状態が空", { state: "" }],
  ])("不正な値（%s）は、推測せず RangeError。待ちの出来事は、変わらない", (_label, override) => {
    const builder = new ReportBuilder();
    builder.record({ kind: "degraded_started" });
    expect(() => builder.prepare({ ...LIVE, ...override } as never)).toThrow(RangeError);
    expect(builder.pendingEvents).toBe(1);
    expect(builder.prepare(LIVE).body.events).toHaveLength(1);
  });

  test("スナップショットがオブジェクトでなければ RangeError", () => {
    expect(() => new ReportBuilder().prepare(null as never)).toThrow(RangeError);
  });
});

describe("適応制御（BitrateGovernor）の出来事を、そのまま積める", () => {
  test("評価の結果の events（bitrate_down・video_dropped・degraded_started）を、順に積んで、報告にできる", () => {
    const governor = new BitrateGovernor();
    const builder = new ReportBuilder();
    let target = 4500;
    let degraded = false;
    for (let second = 0; second < 40; second += 1) {
      const decision = governor.evaluate({
        nowSec: second,
        backlogMs: 5000,
        dropTimesSec: [],
        targetKbps: target,
        minKbps: 3000,
        maxKbps: 6000,
        ackedVideoUs: (second + 1) * 1_000_000,
        degraded,
      });
      target = decision.targetKbps;
      degraded = decision.degraded;
      for (const event of decision.events) {
        builder.record(event);
      }
    }
    const report = builder.prepare({ backlogMs: 5000, droppedVideoFrames: 0, targetKbps: target, state: degraded ? "degraded" : "live" });
    const kinds = new Set(report.body.events.map((event) => event.kind));
    expect(kinds.has("bitrate_down")).toBe(true);
    expect(kinds.has("video_dropped")).toBe(true);
    expect(kinds.has("degraded_started")).toBe(true);
    // 破棄したフレーム数が分からない video_dropped は、detail を持たない
    expect(report.body.events.find((event) => event.kind === "video_dropped")).toEqual({ kind: "video_dropped" });
    expect(() => parseReportBody(report.body)).not.toThrow();
  });
});

describe("性質の検査（決定的な乱数）", () => {
  test("どんな順序で、積む・準備する・commit する・失敗するを繰り返しても、積んだ出来事は、欠落なく・重複なく・順序どおりに 1 回ずつ届く。本文は、いつもワイヤとして正しい", () => {
    const problems = new Problems();
    const sources = ["camera", "screen", "microphone", "shared_audio", "slate"] as const;
    for (let seed = 1; seed <= 200; seed += 1) {
      const random = seededRandom(seed);
      const builder = new ReportBuilder({ maxEventsPerReport: 1 + Math.floor(random() * 6) });
      const recorded: string[] = [];
      const delivered: string[] = [];
      let counter = 0;
      for (let step = 0; step < 150; step += 1) {
        const roll = random();
        if (roll < 0.5) {
          counter += 1;
          builder.record({ kind: "video_dropped", frames: counter });
          recorded.push(`video_dropped:${counter}`);
        } else if (roll < 0.6) {
          const source = sources[Math.floor(random() * sources.length)];
          builder.record({ kind: "source_lost", source });
          recorded.push(`source_lost:${source}`);
        } else {
          const report = builder.prepare({ backlogMs: random() * 3000, droppedVideoFrames: counter, targetKbps: 3000 + Math.floor(random() * 3000), state: random() < 0.8 ? "live" : "degraded" });
          try {
            parseReportBody(report.body);
          } catch (error) {
            problems.report(`seed ${seed} step ${step}: the body is not valid: ${String(error)}`);
          }
          if (random() < 0.7) {
            for (const event of report.body.events) {
              delivered.push(`${event.kind}:${String((event.detail as Record<string, unknown>)[event.kind === "video_dropped" ? "frames" : "source"])}`);
            }
            builder.commit(report);
          }
        }
      }
      // 残りを、すべて送る
      for (let guard = 0; guard < 500 && builder.pendingEvents > 0; guard += 1) {
        const report = builder.prepare({ backlogMs: 0, droppedVideoFrames: counter, targetKbps: 3000, state: "live" });
        for (const event of report.body.events) {
          delivered.push(`${event.kind}:${String((event.detail as Record<string, unknown>)[event.kind === "video_dropped" ? "frames" : "source"])}`);
        }
        builder.commit(report);
      }
      if (JSON.stringify(delivered) !== JSON.stringify(recorded)) {
        problems.report(`seed ${seed}: delivered ${delivered.length} events, recorded ${recorded.length}`);
      }
    }
    expect(problems.list()).toEqual([]);
  });
});
