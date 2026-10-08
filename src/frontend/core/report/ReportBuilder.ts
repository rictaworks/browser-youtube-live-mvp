// ReportBuilder：1 秒間隔の状態報告（report。ws-protocol.md の 5.6、requirements.md 11.9）の本文を組み立てる。
//
//   本文  滞留時間・破棄フレーム数・目標ビットレート・状態（live・degraded）・ブラウザ側の出来事
//   出来事  欠落なく 1 回ずつ送る（キューへ積み、送信済みを除く）。detail は、符号と数値のみ（自由記述・ソースのデバイス名・ラベルを載せない）。
//           積む出来事は、型付き（BrowserEvent）で、列挙の符号と整数だけ。受け取ったオブジェクトの、余計なプロパティは、報告に載せない
//   送信  2 段階：prepare（本文を作る。出来事は、待ちに残す）-> 送信できたら commit（載せた出来事を、待ちから外す）。
//         送信できなければ commit しない（次の prepare が、同じ出来事を、もう一度載せる）。これで、送信の失敗で出来事が欠けず、
//         commit した報告の出来事は、重複しない。commit できるのは、最後に prepare した報告だけ（古い報告・commit 済みの報告は RangeError）
//         接続の断で、実際には届かなかった報告の出来事は、この層には分からない（送信の成否は、呼び出し側が決める）
//   分割  1 つの報告に載せる出来事は、上限（既定 50）まで。超えた分は、次の報告へ回る（順序は保つ）
//
// 時刻・乱数・タイマを使わない。本文は、ワイヤの検証（parseReportBody）を通した、変更できない（凍結した）値。

import { isLayout, isSourceKind } from "../contract";
import { REPORT_STATE_VALUES, parseReportBody } from "../transport";
import type { ReportBody, ReportEvent, ReportState } from "../transport";
import type { BrowserEvent } from "./types";

/**
 * 報告の本文を、その場で凍結する（本文・出来事の配列・各出来事・各出来事の detail）。
 * parseReportBody が返すのは、入力と共有しない新しい値なので、凍結しても、ビルダーの待ちや呼び出し側の値は変わらない。
 * 契約の内部の道具（contract/deep-freeze。contract の入口は公開していない）には依存しない。
 */
function freezeReportBody(body: ReportBody): ReportBody {
  for (const event of body.events) {
    if (event.detail !== undefined) {
      Object.freeze(event.detail);
    }
    Object.freeze(event);
  }
  Object.freeze(body.events);
  return Object.freeze(body);
}

/** 1 つの報告に載せる出来事の数の、既定の上限。契約に定めは無い（仮置き）。大量の出来事で、報告が 2 MB を超えないための上限。 */
export const DEFAULT_MAX_EVENTS_PER_REPORT = 50;

/** 報告の、出来事以外の項目。 */
export interface ReportSnapshot {
  /** 滞留時間（ミリ秒）。評価できない（接続直後で、最初の受領応答の前）ときは undefined。契約は 0 以上の整数を必須とするので、0 を載せる */
  readonly backlogMs: number | undefined;
  /** 破棄した映像フレームの累計（SendQueue.droppedVideoFrames） */
  readonly droppedVideoFrames: number;
  /** 現在の目標ビットレート（映像。kbps） */
  readonly targetKbps: number;
  /** 状態（配信中の 2 つ） */
  readonly state: ReportState;
}

export interface ReportBuilderOptions {
  /** 1 つの報告に載せる出来事の数の上限（既定 DEFAULT_MAX_EVENTS_PER_REPORT）。正の整数 */
  readonly maxEventsPerReport?: number;
}

/** prepare の結果。body を送り、送れたら commit に渡す。 */
export interface PreparedReport {
  readonly body: ReportBody;
  /** この本文に載せた出来事の数 */
  readonly eventCount: number;
  /** prepare の通し番号（commit が、最後の報告か確かめるのに使う） */
  readonly sequence: number;
}

function assertSafeInteger(value: unknown, name: string, minimum: number): asserts value is number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum) {
    throw new RangeError(`${name} must be a safe integer of at least ${minimum}: ${String(value)}`);
  }
}

/** 積む出来事（ドメインの形）を、ワイヤの形（kind と、符号・数値だけの detail）にする。不正は RangeError。余計なプロパティは、持ち込まない。 */
function toWireEvent(event: unknown): ReportEvent {
  if (typeof event !== "object" || event === null) {
    throw new RangeError(`an event must be an object: ${event === null ? "null" : typeof event}`);
  }
  const candidate = event as Readonly<Record<string, unknown>>;
  switch (candidate.kind) {
    case "source_added":
    case "source_lost": {
      if (!isSourceKind(candidate.source)) {
        throw new RangeError(`${candidate.kind}: source must be a source kind code`);
      }
      return { kind: candidate.kind, detail: { source: candidate.source } };
    }
    case "fallback_switched": {
      if (!isLayout(candidate.layout)) {
        throw new RangeError("fallback_switched: layout must be a layout code");
      }
      return { kind: "fallback_switched", detail: { layout: candidate.layout } };
    }
    case "bitrate_down":
    case "bitrate_up": {
      assertSafeInteger(candidate.fromKbps, `${candidate.kind}.fromKbps`, 1);
      assertSafeInteger(candidate.toKbps, `${candidate.kind}.toKbps`, 1);
      const lowered = candidate.kind === "bitrate_down";
      if (lowered ? candidate.toKbps >= candidate.fromKbps : candidate.toKbps <= candidate.fromKbps) {
        throw new RangeError(`${candidate.kind}: the bitrate must ${lowered ? "go down" : "go up"} (${candidate.fromKbps} -> ${candidate.toKbps})`);
      }
      return { kind: candidate.kind, detail: { from_kbps: candidate.fromKbps, to_kbps: candidate.toKbps } };
    }
    case "video_dropped": {
      if (candidate.frames === undefined) {
        return { kind: "video_dropped" };
      }
      assertSafeInteger(candidate.frames, "video_dropped.frames", 0);
      return { kind: "video_dropped", detail: { frames: candidate.frames } };
    }
    case "degraded_started":
    case "degraded_cleared":
      return { kind: candidate.kind };
    default:
      throw new RangeError(`unknown event kind: ${String(candidate.kind).slice(0, 32)}`);
  }
}

function checkSnapshot(snapshot: unknown): ReportSnapshot {
  if (typeof snapshot !== "object" || snapshot === null) {
    throw new RangeError(`the report snapshot must be an object: ${snapshot === null ? "null" : typeof snapshot}`);
  }
  const candidate = snapshot as Partial<Record<keyof ReportSnapshot, unknown>>;
  if (candidate.backlogMs !== undefined && (typeof candidate.backlogMs !== "number" || !Number.isFinite(candidate.backlogMs) || candidate.backlogMs < 0)) {
    throw new RangeError(`backlogMs must be a finite number of at least 0, or undefined: ${String(candidate.backlogMs)}`);
  }
  assertSafeInteger(candidate.droppedVideoFrames, "droppedVideoFrames", 0);
  assertSafeInteger(candidate.targetKbps, "targetKbps", 1);
  if (typeof candidate.state !== "string" || !(REPORT_STATE_VALUES as readonly string[]).includes(candidate.state)) {
    throw new RangeError(`state must be one of ${REPORT_STATE_VALUES.join(", ")}: ${String(candidate.state)}`);
  }
  return candidate as unknown as ReportSnapshot;
}

export class ReportBuilder {
  private readonly maxEventsPerReport: number;
  /** 待ちの出来事（ワイヤの形。古い順） */
  private readonly pending: ReportEvent[] = [];
  private sequence = 0;
  /** 最後に prepare した報告のうち、まだ commit していないもの（commit できるのは、これだけ） */
  private lastPrepared: { readonly sequence: number; readonly eventCount: number } | undefined;

  constructor(options: ReportBuilderOptions = {}) {
    this.maxEventsPerReport = options.maxEventsPerReport ?? DEFAULT_MAX_EVENTS_PER_REPORT;
    assertSafeInteger(this.maxEventsPerReport, "maxEventsPerReport", 1);
  }

  /** 送り終えていない（待ちの）出来事の数。 */
  get pendingEvents(): number {
    return this.pending.length;
  }

  /** 出来事を、待ちへ積む（古い順に送る）。不正な出来事（列挙にない符号・自由記述・不正な数値）は RangeError で、待ちへ積まない。 */
  record(event: BrowserEvent): void {
    this.pending.push(toWireEvent(event));
  }

  /**
   * 報告の本文を作る。待ちの先頭から、上限まで、出来事を載せる（待ちからは外さない）。
   * 本文は、ワイヤの検証を通した、凍結した値（毎回、新しいオブジェクト）。不正なスナップショットは RangeError（待ちは変わらない）。
   */
  prepare(snapshot: ReportSnapshot): PreparedReport {
    const checked = checkSnapshot(snapshot);
    const events = this.pending.slice(0, this.maxEventsPerReport);
    const body = freezeReportBody(
      parseReportBody({
        backlog_ms: Math.round(checked.backlogMs ?? 0),
        dropped_video_frames: checked.droppedVideoFrames,
        target_kbps: checked.targetKbps,
        state: checked.state,
        events,
      }),
    );
    this.sequence += 1;
    this.lastPrepared = { sequence: this.sequence, eventCount: events.length };
    return Object.freeze({ body, eventCount: events.length, sequence: this.sequence });
  }

  /**
   * 送信できた報告の出来事を、待ちから外す。commit できるのは、最後に prepare した報告で、まだ commit していないものだけ（それ以外は RangeError。
   * 二重に外して、載せていない出来事を失わないため）。外す数は、ビルダーが持つ値（渡された報告の eventCount ではない）。
   */
  commit(report: PreparedReport): void {
    const prepared = this.lastPrepared;
    if (typeof report !== "object" || report === null || prepared === undefined || report.sequence !== prepared.sequence) {
      throw new RangeError("commit needs the most recently prepared report, which has not been committed yet");
    }
    this.pending.splice(0, prepared.eventCount);
    this.lastPrepared = undefined;
  }
}
