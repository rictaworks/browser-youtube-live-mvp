// SendQueue：エンコード済みのチャンク（映像・音声）の送信待ち（requirements.md 4・11.5・11.7・12・24.1）。
//
//   取り出し    dequeue は到着順（映像と音声が、到着の順に交互になる）。取り出した（トランスポートへ渡した）チャンクが「送信済み」
//   映像の破棄  映像を 1 枚でも破棄したら、次のキーフレームまでの映像をすべて破棄する（差分フレームは、直前までの全フレームに依存するため）。
//               内部状態（破棄中）を持ち、キーフレームの到着で解除する。音声は、どんな破棄の操作でも、破棄しない（11.5）
//   滞留時間    backlogMs = 送信済みの最新メディア時刻 - 中継が受領済みと応答した最新メディア時刻（映像・音声のうち古い方）。4 章の「滞留時間」
//   再接続中    suspend() から resume() まで、符号化結果を捨てる（送信待ちに積まない。12 章）。resume のあとは、映像は次のキーフレームから
//   安全弁      件数・バイトの上限。超えたら、映像から破棄する（音声は破棄しない。映像が無く、音声で上限を超えるなら、SendQueueOverflowError）
//
// チャンクの中身（符号化データ）は見ない。型引数 C は、ChunkMeta を満たす任意のチャンク（呼び出し側が、符号化データなどを載せてよい）で、
// キューは、渡されたオブジェクトをそのまま返す（コピーしない）。時刻（メディアクロック）は、チャンクの timestampUs だけを使う
// （実時計・タイマを参照しない。Domain Core）。

import { LIMITS, PROFILE_VALUES } from "../contract";

export type ChunkKind = "video" | "audio";

/** キューが見る、チャンクの項目。 */
export interface ChunkMeta {
  readonly kind: ChunkKind;
  /** メディア時刻（マイクロ秒）。0 以上の安全整数。同じ種別の中で、逆行しない */
  readonly timestampUs: number;
  /** キーフレームか。音声は、常に false */
  readonly keyframe: boolean;
  /** 符号化データのバイト数。0 以上の整数 */
  readonly byteLength: number;
}

export interface SendQueueOptions {
  /** 件数の上限（既定は DEFAULT_MAX_CHUNKS） */
  readonly maxChunks?: number;
  /** バイトの上限（既定は DEFAULT_MAX_BYTES） */
  readonly maxBytes?: number;
  /** 破棄の履歴に残す、最新の件数（既定は DEFAULT_MAX_DROP_HISTORY） */
  readonly maxDropHistory?: number;
}

/** 積まれなかった理由。 */
export type EnqueueRefusal =
  /** 再接続中（suspend のあと）。符号化結果を捨てる */
  | "suspended"
  /** 映像の破棄中。次のキーフレームが来るまで、差分の映像を積まない */
  | "waiting_for_keyframe"
  /** 件数・バイトの上限を超える映像（待ちの映像を破棄しても、積めない） */
  | "over_capacity";

/** enqueue の結果。droppedVideoFrames は、この呼び出しで破棄した映像のチャンクの数（積まれなかった、受け取った映像を含む）。 */
export type EnqueueResult =
  | { readonly accepted: true; readonly droppedVideoFrames: number }
  | { readonly accepted: false; readonly reason: EnqueueRefusal; readonly droppedVideoFrames: number };

/** suspend が空にした、チャンクの数。 */
export interface SuspendedCounts {
  readonly video: number;
  readonly audio: number;
}

/**
 * 音声のチャンクを積めない（映像が待ちに無く、件数・バイトの上限に達している）。音声は破棄しない（11.5）ので、黙って捨てずに、エラーにする。
 * 呼び出し側は、接続の不調として扱う（再接続など）。符号と、件数・バイトの数値だけを持つ（チャンクの中身を含めない）。
 */
export class SendQueueOverflowError extends Error {
  readonly code = "send_queue_overflow";

  constructor(
    readonly chunks: number,
    readonly bytes: number,
    readonly maxChunks: number,
    readonly maxBytes: number,
  ) {
    super(`send queue is full: ${chunks} chunks, ${bytes} bytes (limits ${maxChunks} chunks, ${maxBytes} bytes); an audio chunk is never dropped`);
    this.name = "SendQueueOverflowError";
  }
}

// ---------------------------------------------------------------------------
// 安全弁の既定値（契約の値から導く）
//   滞留が 4 秒を超えると、映像を全破棄する（評価は 1 秒ごと）ので、正常なときの待ちは、5 秒分まで。その 2 倍の 10 秒分を、安全弁にする。
//   件数 = 10 秒 ×（映像の最大のフレームレート + 音声のチャンク数。AAC-LC は 1 チャンク 1,024 サンプル）
//   バイト = 10 秒 ×（映像ビットレートの最大 + 音声ビットレート）
// ---------------------------------------------------------------------------

const AAC_SAMPLES_PER_CHUNK = 1024;
const SAFETY_FACTOR = 2;
const MILLISECONDS_PER_SECOND = 1000;
const MICROSECONDS_PER_MILLISECOND = 1000;
const MICROSECONDS_PER_SECOND = 1_000_000;
const BITS_PER_BYTE = 8;
const BITS_PER_KILOBIT = 1000;

const NORMAL_BACKLOG_SECONDS = (LIMITS.adaptive.conditions.backlog_critical.backlog_over_ms + LIMITS.adaptive.evaluation_interval_ms) / MILLISECONDS_PER_SECOND;
const SAFETY_SECONDS = NORMAL_BACKLOG_SECONDS * SAFETY_FACTOR;
const MAX_FRAMERATE = Math.max(...PROFILE_VALUES.map((profile) => LIMITS.profiles[profile].framerate));
const MAX_VIDEO_KBPS = Math.max(...PROFILE_VALUES.map((profile) => LIMITS.profiles[profile].video_bitrate_max_kbps));
const AUDIO_CHUNKS_PER_SECOND = Math.ceil(LIMITS.audio.sample_rate_hz / AAC_SAMPLES_PER_CHUNK);

/** 件数の上限の既定。 */
export const DEFAULT_MAX_CHUNKS = Math.ceil(SAFETY_SECONDS * (MAX_FRAMERATE + AUDIO_CHUNKS_PER_SECOND));
/** バイトの上限の既定。 */
export const DEFAULT_MAX_BYTES = Math.ceil((SAFETY_SECONDS * (MAX_VIDEO_KBPS + LIMITS.audio.bitrate_kbps) * BITS_PER_KILOBIT) / BITS_PER_BYTE);
/** 破棄の履歴の件数の既定。適応制御が見るのは、直近 10 秒に破棄があるかだけ。 */
export const DEFAULT_MAX_DROP_HISTORY = 128;

interface QueueNode<C> {
  readonly chunk: C;
  next: QueueNode<C> | undefined;
}

function assertPositiveSafeInteger(value: number, name: string): void {
  if (!Number.isSafeInteger(value) || value < 1) {
    throw new RangeError(`${name} must be a positive safe integer: ${String(value)}`);
  }
}

function assertNonNegativeSafeInteger(value: unknown, name: string): asserts value is number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new RangeError(`${name} must be a non-negative safe integer: ${String(value)}`);
  }
}

/** 受領済みの時刻（マイクロ秒）。未受信（その接続の最初の ack の前）は undefined。それ以外は、0 以上の安全整数。 */
function readAck(value: number | undefined, name: string): number | undefined {
  if (value === undefined) {
    return undefined;
  }
  assertNonNegativeSafeInteger(value, name);
  return value;
}

export class SendQueue<C extends ChunkMeta = ChunkMeta> {
  readonly maxChunks: number;
  readonly maxBytes: number;
  private readonly maxDropHistory: number;

  /** 待ちの先頭（次に取り出すチャンク）と末尾。連結リスト（取り出し・積むのが、待ちの長さによらず一定の手間） */
  private first: QueueNode<C> | undefined;
  private last: QueueNode<C> | undefined;
  private count = 0;
  private bytes = 0;
  private videoCount = 0;

  private dropping = false;
  private isSuspended = false;
  private droppedTotal = 0;
  private suspendedVideo = 0;
  private suspendedAudio = 0;
  private sentLatest: number | undefined;
  /** 積もうとしたチャンク（破棄したものを含む）の、最新のメディア時刻。待ちの操作の時刻として使う */
  private seenLatest: number | undefined;
  private lastVideoTime: number | undefined;
  private lastAudioTime: number | undefined;
  private dropTimesUs: number[] = [];

  constructor(options: SendQueueOptions = {}) {
    this.maxChunks = options.maxChunks ?? DEFAULT_MAX_CHUNKS;
    this.maxBytes = options.maxBytes ?? DEFAULT_MAX_BYTES;
    this.maxDropHistory = options.maxDropHistory ?? DEFAULT_MAX_DROP_HISTORY;
    assertPositiveSafeInteger(this.maxChunks, "maxChunks");
    assertPositiveSafeInteger(this.maxBytes, "maxBytes");
    assertPositiveSafeInteger(this.maxDropHistory, "maxDropHistory");
  }

  // -------------------------------------------------------------------------
  // 状態
  // -------------------------------------------------------------------------

  /** 待ちのチャンクの数。 */
  get length(): number {
    return this.count;
  }

  /** 待ちのチャンクのバイト数の合計。 */
  get byteLength(): number {
    return this.bytes;
  }

  /** 待ちの映像のチャンクの数。 */
  get videoLength(): number {
    return this.videoCount;
  }

  /** 待ちの音声のチャンクの数。 */
  get audioLength(): number {
    return this.count - this.videoCount;
  }

  /** 映像を破棄中か（次のキーフレームが来るまで、差分の映像を積まない）。 */
  get droppingVideo(): boolean {
    return this.dropping;
  }

  /** 再接続中（符号化結果を捨てている）か。 */
  get suspended(): boolean {
    return this.isSuspended;
  }

  /** 破棄した映像のチャンクの累計（健全性の「破棄フレーム数」）。再接続中に捨てた分は含めない（suspendedDiscards）。 */
  get droppedVideoFrames(): number {
    return this.droppedTotal;
  }

  /** 再接続中に捨てた、映像・音声のチャンクの累計。 */
  get suspendedDiscards(): SuspendedCounts {
    return { video: this.suspendedVideo, audio: this.suspendedAudio };
  }

  /** 送信済み（dequeue した）チャンクの、最新のメディア時刻（マイクロ秒）。まだ 1 つも送信していなければ undefined。 */
  get latestSentUs(): number | undefined {
    return this.sentLatest;
  }

  /** 待ちの中身の複製（到着順）。読むだけ。診断用。 */
  snapshot(): C[] {
    const chunks: C[] = [];
    for (let node = this.first; node !== undefined; node = node.next) {
      chunks.push(node.chunk);
    }
    return chunks;
  }

  /** 破棄の履歴：映像を破棄した時刻（メディアクロック由来の秒）。古い順。最新の maxDropHistory 件。適応制御の「直近 10 秒の破棄」の入力。 */
  dropHistorySec(): number[] {
    return this.dropTimesUs.map((microseconds) => microseconds / MICROSECONDS_PER_SECOND);
  }

  // -------------------------------------------------------------------------
  // 積む・取り出す
  // -------------------------------------------------------------------------

  /**
   * チャンクを積む。結果は、積まれたか（accepted）と、この呼び出しで破棄した映像の数。
   *   1. 再接続中（suspend のあと）は、積まない（捨てる）
   *   2. 件数・バイトの上限を超えるなら、待ちの映像から破棄する（最も古い映像と、続く、次のキーフレームの手前まで。音声は破棄しない）
   *   3. 映像の破棄中に、差分の映像が来たら、積まない（破棄する）。キーフレームが来たら積み、破棄中を解除する
   *   4. それでも上限を超えるなら、映像は積まず（破棄して、破棄中になる）、音声は SendQueueOverflowError
   * 不正なチャンク（種別・時刻・バイト数・キーフレームの指定が不正、同じ種別の時刻が逆行）は RangeError。状態は変わらない。
   */
  enqueue(chunk: C): EnqueueResult {
    this.assertChunk(chunk);
    this.noteSeen(chunk);

    if (this.isSuspended) {
      if (chunk.kind === "video") {
        this.suspendedVideo += 1;
      } else {
        this.suspendedAudio += 1;
      }
      return { accepted: false, reason: "suspended", droppedVideoFrames: 0 };
    }

    let droppedNow = 0;
    while (this.wouldExceed(chunk) && this.videoCount > 0) {
      droppedNow += this.dropOldestVideoCluster();
    }

    if (chunk.kind === "video" && this.dropping && !chunk.keyframe) {
      droppedNow += this.dropIncomingVideo(chunk);
      return { accepted: false, reason: "waiting_for_keyframe", droppedVideoFrames: droppedNow };
    }

    if (this.wouldExceed(chunk)) {
      if (chunk.kind === "video") {
        droppedNow += this.dropIncomingVideo(chunk);
        this.dropping = true;
        return { accepted: false, reason: "over_capacity", droppedVideoFrames: droppedNow };
      }
      throw new SendQueueOverflowError(this.count, this.bytes, this.maxChunks, this.maxBytes);
    }

    this.append(chunk);
    if (chunk.kind === "video" && chunk.keyframe) {
      this.dropping = false;
    }
    return { accepted: true, droppedVideoFrames: droppedNow };
  }

  /** 先頭のチャンクを取り出す（到着順）。空なら undefined。取り出したチャンクは「送信済み」になり、滞留時間の計算に使う。 */
  dequeue(): C | undefined {
    const node = this.first;
    if (node === undefined) {
      return undefined;
    }
    this.first = node.next;
    if (this.first === undefined) {
      this.last = undefined;
    }
    this.account(node.chunk, -1);
    this.sentLatest = this.sentLatest === undefined ? node.chunk.timestampUs : Math.max(this.sentLatest, node.chunk.timestampUs);
    return node.chunk;
  }

  // -------------------------------------------------------------------------
  // 滞留時間
  // -------------------------------------------------------------------------

  /**
   * 滞留時間（ミリ秒）= 送信済みの最新メディア時刻 - 受領済みと応答された最新メディア時刻（映像・音声のうち古い方）。小数を持ち得る（マイクロ秒の差 / 1,000）。
   * 負にしない（受領済みが、送信済みに追いついたら 0）。
   *
   * 受領応答が来る前の初期値：評価しない（undefined を返す）。
   *   - ackedVideoUs・ackedAudioUs の、どちらかが undefined：その接続の最初の受領応答を、まだ受けていない（接続・再接続の直後。0 を返さない）
   *   - どちらかが 0：中継が、その種別を、まだ 1 つも受けていない（契約の ws-protocol.md 5.10）。古い方が 0 では、滞留が、メディア時刻の全体になってしまうため
   * 何も送信していない（dequeue していない）ときは、受領応答があれば、0（未処理のものが無い）。
   * 受領応答が、0 以上の安全整数でも undefined でもなければ RangeError。状態は変えない。
   */
  backlogMs(ackedVideoUs: number | undefined, ackedAudioUs: number | undefined): number | undefined {
    const video = readAck(ackedVideoUs, "ackedVideoUs");
    const audio = readAck(ackedAudioUs, "ackedAudioUs");
    if (video === undefined || audio === undefined || video === 0 || audio === 0) {
      return undefined;
    }
    if (this.sentLatest === undefined) {
      return 0;
    }
    return Math.max(0, this.sentLatest - Math.min(video, audio)) / MICROSECONDS_PER_MILLISECOND;
  }

  // -------------------------------------------------------------------------
  // 破棄
  // -------------------------------------------------------------------------

  /**
   * 映像の破棄を始める：待ちの、最も古い映像と、続く、次のキーフレームの手前までの映像を破棄する（音声は、元の順で残す）。
   * 次のキーフレームが待ちに無ければ、映像の破棄中になる（キーフレームが来るまで、差分の映像を積まない）。待ちに映像が無くても、破棄中になる。
   * 次のキーフレームが待ちにあれば、そこから先は、つながっているので、破棄中にならない。破棄した映像の数を返す。
   */
  dropVideoUntilNextKey(): number {
    if (this.videoCount === 0) {
      this.dropping = true;
      return 0;
    }
    return this.dropOldestVideoCluster();
  }

  /**
   * 待ちの映像を、すべて破棄する（滞留が 4 秒を超えたとき）。映像の破棄中になる（次のキーフレームから積む）。
   * 直ちにキーフレームを発行するのは、呼び出し側（適応制御の指示）。破棄した映像の数を返す。音声は破棄しない。
   * 全破棄の指示は、待ちに映像が無くても（送信待ちが空で、滞留が、送信済みの側にあるとき）、破棄の履歴に残す
   * （滞留が 4 秒を超えた直後に、目標を引き上げない。適応制御の「直近 10 秒に破棄がない」）。破棄フレーム数（droppedVideoFrames）は、増えない。
   */
  discardAllVideo(): number {
    const removed = this.unlinkWhere((chunk) => chunk.kind === "video");
    this.dropping = true;
    this.droppedTotal += removed;
    this.pushDropTime(this.seenLatest ?? 0);
    return removed;
  }

  // -------------------------------------------------------------------------
  // 再接続中
  // -------------------------------------------------------------------------

  /**
   * 再接続中（送出を許可されるまで）の、符号化結果を捨てるモードにする。待ちを空にし（古いチャンクを、復帰のあとに送らない）、
   * 以後の enqueue は、積まずに捨てる（映像・音声とも。数は suspendedDiscards）。空にした数を返す。冪等。
   * 破棄フレーム数（droppedVideoFrames）・破棄の履歴には数えない（輻輳による破棄ではない）。
   */
  suspend(): SuspendedCounts {
    const video = this.videoCount;
    const audio = this.count - this.videoCount;
    this.first = undefined;
    this.last = undefined;
    this.count = 0;
    this.bytes = 0;
    this.videoCount = 0;
    this.suspendedVideo += video;
    this.suspendedAudio += audio;
    this.isSuspended = true;
    return { video, audio };
  }

  /**
   * 積むのを再開する（復帰時は、キーフレーム要求を受けたとき）。映像は、次のキーフレームから積む（再開の直後は、映像の破棄中）。
   * 音声は、すぐ積む。suspend していなければ、何もしない。
   */
  resume(): void {
    if (!this.isSuspended) {
      return;
    }
    this.isSuspended = false;
    this.dropping = true;
  }

  // -------------------------------------------------------------------------
  // 内部
  // -------------------------------------------------------------------------

  private assertChunk(chunk: unknown): void {
    if (typeof chunk !== "object" || chunk === null) {
      throw new RangeError(`chunk must be an object: ${chunk === null ? "null" : typeof chunk}`);
    }
    const candidate = chunk as Partial<ChunkMeta>;
    if (candidate.kind !== "video" && candidate.kind !== "audio") {
      throw new RangeError(`chunk.kind must be video or audio: ${String(candidate.kind)}`);
    }
    assertNonNegativeSafeInteger(candidate.timestampUs, "chunk.timestampUs");
    assertNonNegativeSafeInteger(candidate.byteLength, "chunk.byteLength");
    if (typeof candidate.keyframe !== "boolean") {
      throw new RangeError(`chunk.keyframe must be a boolean: ${typeof candidate.keyframe}`);
    }
    if (candidate.kind === "audio" && candidate.keyframe) {
      throw new RangeError("an audio chunk cannot be a keyframe");
    }
    const previous = candidate.kind === "video" ? this.lastVideoTime : this.lastAudioTime;
    if (previous !== undefined && candidate.timestampUs < previous) {
      throw new RangeError(`${candidate.kind} timestamp went back: ${candidate.timestampUs} us after ${previous} us`);
    }
  }

  /** 積もうとしたチャンクの時刻を、記録する（破棄・再接続中に捨てたものを含む。時刻の列は、破棄しても続く）。 */
  private noteSeen(chunk: C): void {
    if (chunk.kind === "video") {
      this.lastVideoTime = chunk.timestampUs;
    } else {
      this.lastAudioTime = chunk.timestampUs;
    }
    this.seenLatest = this.seenLatest === undefined ? chunk.timestampUs : Math.max(this.seenLatest, chunk.timestampUs);
  }

  private wouldExceed(chunk: C): boolean {
    return this.count + 1 > this.maxChunks || this.bytes + chunk.byteLength > this.maxBytes;
  }

  private append(chunk: C): void {
    const node: QueueNode<C> = { chunk, next: undefined };
    if (this.last === undefined) {
      this.first = node;
    } else {
      this.last.next = node;
    }
    this.last = node;
    this.account(chunk, 1);
  }

  /** 件数・バイト・映像の数を、チャンク 1 つ分（direction は +1 か -1）、増減する。 */
  private account(chunk: C, direction: 1 | -1): void {
    this.count += direction;
    this.bytes += direction * chunk.byteLength;
    if (chunk.kind === "video") {
      this.videoCount += direction;
    }
  }

  /** shouldRemove が真のチャンクを、待ちから外す（先頭から順に判定する。判定の関数は、状態を持ってよい）。外した数を返す。 */
  private unlinkWhere(shouldRemove: (chunk: C) => boolean): number {
    let removed = 0;
    let previous: QueueNode<C> | undefined;
    let node = this.first;
    while (node !== undefined) {
      const next = node.next;
      if (shouldRemove(node.chunk)) {
        if (previous === undefined) {
          this.first = next;
        } else {
          previous.next = next;
        }
        if (node === this.last) {
          this.last = previous;
        }
        this.account(node.chunk, -1);
        removed += 1;
      } else {
        previous = node;
      }
      node = next;
    }
    return removed;
  }

  /**
   * 待ちの、最も古い映像（キーフレームでも）と、続く、次のキーフレームの手前までの映像を破棄する。音声は、そのまま残す。
   * 次のキーフレームが待ちに無ければ（外した映像が末尾まで続いた）、映像の破棄中にする。外した数を返す。
   */
  private dropOldestVideoCluster(): number {
    let seenOldest = false;
    let reachedNextKeyframe = false;
    const removed = this.unlinkWhere((chunk) => {
      if (chunk.kind !== "video") {
        return false;
      }
      if (!seenOldest) {
        seenOldest = true;
        return true;
      }
      if (!reachedNextKeyframe && !chunk.keyframe) {
        return true;
      }
      reachedNextKeyframe = true;
      return false;
    });
    if (!reachedNextKeyframe) {
      this.dropping = true;
    }
    this.recordDrops(removed);
    return removed;
  }

  /** 積まれなかった映像（受け取ったもの）を、破棄として数える。 */
  private dropIncomingVideo(chunk: C): number {
    this.droppedTotal += 1;
    this.pushDropTime(chunk.timestampUs);
    return 1;
  }

  /** 待ちから外した映像の数を、破棄として数え、履歴に残す（外した数が 0 なら、何もしない）。 */
  private recordDrops(removed: number): void {
    if (removed === 0) {
      return;
    }
    this.droppedTotal += removed;
    this.pushDropTime(this.seenLatest ?? 0);
  }

  private pushDropTime(atUs: number): void {
    this.dropTimesUs.push(atUs);
    if (this.dropTimesUs.length > this.maxDropHistory) {
      this.dropTimesUs.splice(0, this.dropTimesUs.length - this.maxDropHistory);
    }
  }
}
