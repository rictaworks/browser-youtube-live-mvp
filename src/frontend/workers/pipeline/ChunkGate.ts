// ChunkGate（requirements.md 11.9・12。issue #27）。符号化結果を、メインスレッド（送信待ち）へ渡してよいかの門。
//
//   - 閉じている間（配信の開始前・再接続中）は、映像も音声も渡さず、捨てる。エンコーダは動かし続ける（12 章：再接続中は、合成とエンコードを継続したまま、
//     符号化結果を捨てる。送信待ちに積まない）
//   - 開く（開始時は状態通知で送出開始が伝えられたあと、復帰時はキーフレーム要求を受けたあと）と、映像は最初のキーフレームから渡す。
//     それ以前の差分フレームは、直前までの全フレームに依存するため、受け口で復号できないので、捨てる
//   - 音声は、開いたらすぐ渡す（音声フレームは破棄対象としない。AAC の全フレームが独立）
//   - 開いたまま、もう一度開いても、状態は変わらない（重複した通知で、映像の流れを途切れさせない）
//
// 時刻・環境を参照しない。符号化データの中身を見ない。

import type { EncodedChunk } from "@/lib/pipeline/chunks";

export interface ChunkGateCounters {
  /** 閉じている間に捨てた、映像のチャンクの数（累計） */
  readonly closedDiscardedVideo: number;
  /** 閉じている間に捨てた、音声のチャンクの数（累計） */
  readonly closedDiscardedAudio: number;
  /** 開いたあと、最初のキーフレームを待つ間に捨てた、差分フレームの数（累計） */
  readonly skippedBeforeKeyframe: number;
}

export class ChunkGate {
  private open_ = false;
  private awaitingKeyframe = false;
  private closedDiscardedVideo = 0;
  private closedDiscardedAudio = 0;
  private skippedBeforeKeyframe = 0;

  get isOpen(): boolean {
    return this.open_;
  }

  /** 開いているが、映像の最初のキーフレームを、まだ受けていない。 */
  get waitingForKeyframe(): boolean {
    return this.open_ && this.awaitingKeyframe;
  }

  get counters(): ChunkGateCounters {
    return {
      closedDiscardedVideo: this.closedDiscardedVideo,
      closedDiscardedAudio: this.closedDiscardedAudio,
      skippedBeforeKeyframe: this.skippedBeforeKeyframe,
    };
  }

  /** 開く。映像は、次のキーフレームから渡す。すでに開いていれば、何も変えない。 */
  open(): void {
    if (this.open_) {
      return;
    }
    this.open_ = true;
    this.awaitingKeyframe = true;
  }

  /** 閉じる（再接続中・配信の終了）。以後のチャンクは捨てる。何度呼んでもよい。 */
  close(): void {
    this.open_ = false;
    this.awaitingKeyframe = false;
  }

  /** チャンクを渡してよいか。渡さないものは、数えて捨てる。 */
  admit(chunk: EncodedChunk): boolean {
    if (!this.open_) {
      if (chunk.kind === "video") {
        this.closedDiscardedVideo += 1;
      } else {
        this.closedDiscardedAudio += 1;
      }
      return false;
    }
    if (chunk.kind === "audio") {
      return true;
    }
    if (this.awaitingKeyframe) {
      if (!chunk.keyframe) {
        this.skippedBeforeKeyframe += 1;
        return false;
      }
      this.awaitingKeyframe = false;
    }
    return true;
  }
}
