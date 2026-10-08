// SourcePump（requirements.md 11.4・13.1。issue #27）。メインスレッドから転送された readable（VideoFrame のストリーム）を、ワーカー上で読み、
// FrameStore（各ソース最新の 1 枚）へ渡す。
//
//   - Chrome では、MediaStreamTrackProcessor はワーカー内で使えず、MediaStreamTrack も転送できない。メインスレッドで processor を作り、
//     その readable をワーカーへ転送する。Chromium は readable の転送を最適化しており、フレームはワーカーへ直接届く
//   - 読んだフレームは FrameStore へ渡す（最新の 1 枚だけを保持し、古いフレームを直ちに閉じる）
//   - ストリームが自然に終わった（トラックの終了）ら、onEnded で知らせる。失敗したら（FrameStore が閉じるのに失敗した場合を含む）、onError で知らせ、
//     読み取りをやめる（黙って止まらない）。保持しているフレームの解放は、呼び出し側（ホスト）が行う
//   - stop（ソースの解除）は、読み取りを取り消し、ループの終了を待つ。取り消しの途中で届いたフレームは、保持せず、閉じる
//
// 時刻・環境を参照しない。

import type { FrameStore, VideoSourceKind } from "./FrameStore";

export interface SourcePumpOptions {
  readonly kind: VideoSourceKind;
  /** メインスレッドから転送された、VideoFrame のストリーム */
  readonly readable: ReadableStream<VideoFrame>;
  readonly store: FrameStore<VideoFrame>;
  /** ストリームが自然に終わった（トラックの終了）。stop で止めたときは呼ばない */
  readonly onEnded: (kind: VideoSourceKind) => void;
  /** 読み取りの失敗。以後は読まない */
  readonly onError: (kind: VideoSourceKind, error: unknown) => void;
}

export class SourcePump {
  private readonly options: SourcePumpOptions;
  private reader: ReadableStreamDefaultReader<VideoFrame> | null = null;
  private loop: Promise<void> | null = null;
  private running = false;
  private stopped = false;

  constructor(options: SourcePumpOptions) {
    this.options = options;
  }

  get isRunning(): boolean {
    return this.running;
  }

  /** 読み取りを始める。すでに始めていれば、何もしない（フレームを二重に取り込まない）。 */
  start(): void {
    if (this.loop !== null) {
      return;
    }
    const reader = this.options.readable.getReader();
    this.reader = reader;
    this.running = true;
    this.loop = this.run(reader);
  }

  /** 読み取りを取り消して、ループの終了を待つ。start する前・止めたあとに呼んでも、何も起こさない。 */
  async stop(): Promise<void> {
    this.stopped = true;
    const reader = this.reader;
    const loop = this.loop;
    if (reader === null || loop === null) {
      return;
    }
    try {
      await reader.cancel();
    } catch (error) {
      // 取り消しに失敗しても（ストリームがすでに失敗していた、など）、ループは終わっている。原因は onError で知らせ済みのはず
      if (this.running) {
        this.options.onError(this.options.kind, error);
      }
    }
    await loop;
  }

  private async run(reader: ReadableStreamDefaultReader<VideoFrame>): Promise<void> {
    const { kind, store, onEnded, onError } = this.options;
    try {
      for (;;) {
        const result = await reader.read();
        if (this.stopped) {
          // 取り消しの途中で届いたフレーム: 保持せず、閉じる（解放漏れを作らない）
          if (!result.done) {
            result.value.close();
          }
          return;
        }
        if (result.done) {
          this.running = false;
          onEnded(kind);
          return;
        }
        store.put(kind, result.value);
      }
    } catch (error) {
      if (!this.stopped) {
        this.running = false;
        onError(kind, error);
      }
    } finally {
      this.running = false;
    }
  }
}
