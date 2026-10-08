// FrameStore（requirements.md 11.4。issue #27）。取得した映像フレームは、各ソース最新の 1 枚だけを保持する。
//
//   - 新しいフレームが届いた時点で、古いフレームを直ちに close() する（保持数は、ソースごとに 1 以下）
//   - ソースが外れた（release）・破棄された（dispose）ときは、保持しているフレームを閉じる
//   - 保持するのは「最新の 1 枚」である理由: 画面共有は、画面に動きが無いと、新しいフレームがしばらく届かない。合成は毎フレーム（30 fps）行うので、
//     最後に届いたフレームを、次が届くまで描き続ける必要がある。閉じるのは、置き換えられたとき・外れたときで、描画に使った直後ではない
//     （使った直後に閉じると、動きの無い画面共有を描けなくなる）。置き換えで閉じるので、古いフレームが溜まることはない
//   - 受け取った数 = 閉じた数 + 保持している数（解放漏れが無い）。この不変条件を、数えて確かめられるようにする
//   - 閉じるのに失敗しても、保持の状態は壊さない（フレームは保持から外す。二度と描かない）。失敗は呼び出し元へ伝える
//
// 時刻・環境を参照しない。フレームの中身（画素）を読まない。

import type { SourceKind } from "@/core/contract";

/** 映像のソースの種類（合成の入力）。マイク・共有音声・代替スレートは、映像のフレームを持たない。 */
export const VIDEO_SOURCE_KINDS = ["screen", "camera"] as const satisfies readonly SourceKind[];
export type VideoSourceKind = (typeof VIDEO_SOURCE_KINDS)[number];

export function isVideoSourceKind(value: unknown): value is VideoSourceKind {
  return typeof value === "string" && (VIDEO_SOURCE_KINDS as readonly string[]).includes(value);
}

function assertVideoSourceKind(value: unknown): asserts value is VideoSourceKind {
  if (!isVideoSourceKind(value)) {
    throw new RangeError(`unknown video source kind: ${String(value)}`);
  }
}

/** 保持するフレーム（VideoFrame）。close できること以外を、仮定しない。 */
export interface ClosableFrame {
  close(): void;
}

export class FrameStore<F extends ClosableFrame = VideoFrame> {
  private readonly frames = new Map<VideoSourceKind, F>();
  private received = 0;
  private closed = 0;
  private disposed = false;

  /** 受け取ったフレームの数（累計）。 */
  get receivedCount(): number {
    return this.received;
  }

  /** 閉じたフレームの数（累計）。閉じるのに失敗したものも含む（保持から外した）。 */
  get closedCount(): number {
    return this.closed;
  }

  /** 保持しているフレームの数（全ソースの合計）。 */
  get retainedCount(): number {
    return this.frames.size;
  }

  /** ソースごとの保持数（0 か 1）。 */
  retained(kind: VideoSourceKind): number {
    assertVideoSourceKind(kind);
    return this.frames.has(kind) ? 1 : 0;
  }

  /** ソースの最新のフレーム。まだ届いていなければ null。閉じてはいけない（保持しているのは、この store）。 */
  latest(kind: VideoSourceKind): F | null {
    assertVideoSourceKind(kind);
    return this.frames.get(kind) ?? null;
  }

  /**
   * 届いたフレームを、そのソースの最新として保持する。古いフレームは、直ちに閉じる。
   * 破棄済みの store へ届いたフレームは、受け取ってすぐ閉じる。同じフレームをもう一度渡しても、何も起きない。
   */
  put(kind: VideoSourceKind, frame: F): void {
    assertVideoSourceKind(kind);
    const previous = this.frames.get(kind);
    if (previous === frame) {
      return;
    }
    this.received += 1;
    if (this.disposed) {
      this.closeFrame(frame);
      return;
    }
    this.frames.set(kind, frame);
    if (previous !== undefined) {
      this.closeFrame(previous);
    }
  }

  /** そのソースのフレームを閉じて、保持から外す（ソースの解除・喪失）。何も保持していなければ、何もしない。 */
  release(kind: VideoSourceKind): void {
    assertVideoSourceKind(kind);
    const frame = this.frames.get(kind);
    if (frame === undefined) {
      return;
    }
    this.frames.delete(kind);
    this.closeFrame(frame);
  }

  /** すべてのソースのフレームを閉じる。ひとつの close が失敗しても、残りを閉じてから、最初の失敗を投げる。 */
  releaseAll(): void {
    let firstFailure: { readonly error: unknown } | null = null;
    for (const kind of VIDEO_SOURCE_KINDS) {
      try {
        this.release(kind);
      } catch (error) {
        firstFailure = firstFailure ?? { error };
      }
    }
    if (firstFailure !== null) {
      throw firstFailure.error;
    }
  }

  /** 保持しているフレームを閉じ、以後に届くフレームも、受け取ってすぐ閉じる。何度呼んでもよい。 */
  dispose(): void {
    this.disposed = true;
    this.releaseAll();
  }

  private closeFrame(frame: F): void {
    this.closed += 1;
    frame.close();
  }
}
