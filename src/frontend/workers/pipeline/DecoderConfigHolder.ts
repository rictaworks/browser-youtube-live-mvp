// DecoderConfigHolder（requirements.md 11.7・11.10。issue #27）。エンコーダが返す復号器設定（decoderConfig.description）の保持。
// 映像（AVCDecoderConfigurationRecord）と音声（AudioSpecificConfig）で、同じ規則を使う（VideoEncoderPipeline・AudioEncoderPipeline が持つ）。
//
//   - エンコーダの最初の出力で得る。形が正しくなければ decoder_config_missing（黙って空の設定を送らない。中継は、設定がそろうまで publish を開始しない）
//   - 得たあとに、内容（またはコーデック）が変わったら、変化として通知する（中継へ設定を再送するため）。同じ内容なら通知しない
//   - 得たあとの出力が description を省いたときは、前の設定のまま（再設定の出力が、設定を省くことがある）
//   - 返すのはコピー（返した値を書き換えても、保持している設定は変わらない）
//   - 待っている呼び出しは、得たら解決し、故障・終了（rejectAll）で拒否される。拒否のあとの wait も拒否される（待ち続けない）。ただし、すでに得た設定は読める

import { createDecoderConfigChunk } from "@/lib/pipeline/chunks";
import type { DecoderConfigChunk, MediaKind } from "@/lib/pipeline/chunks";
import { PipelineError } from "@/lib/pipeline/errors";

/** エンコーダの decoderConfig のうち、使う項目。 */
export interface DecoderConfigInput {
  readonly codec: string;
  /** ArrayBuffer か、そのビュー。無いことがある */
  readonly description?: unknown;
}

interface Waiter {
  readonly resolve: (config: DecoderConfigChunk) => void;
  readonly reject: (error: PipelineError) => void;
}

function isArrayBuffer(value: unknown): value is ArrayBuffer {
  return Object.prototype.toString.call(value) === "[object ArrayBuffer]";
}

/** description（ArrayBuffer か、そのビュー）を、Uint8Array のビューにする。それ以外は decoder_config_missing。 */
function viewOf(description: unknown): Uint8Array {
  if (isArrayBuffer(description)) {
    return new Uint8Array(description);
  }
  if (ArrayBuffer.isView(description)) {
    return new Uint8Array(description.buffer, description.byteOffset, description.byteLength);
  }
  throw new PipelineError("decoder_config_missing");
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((value, index) => value === b[index]);
}

export class DecoderConfigHolder {
  private readonly kind: MediaKind;
  private readonly onChanged: ((config: DecoderConfigChunk) => void) | undefined;
  private config: DecoderConfigChunk | null = null;
  private waiters: Waiter[] = [];
  private rejection: PipelineError | null = null;

  constructor(kind: MediaKind, onChanged?: (config: DecoderConfigChunk) => void) {
    this.kind = kind;
    this.onChanged = onChanged;
  }

  /** 復号器設定を、すでに得た。 */
  get has(): boolean {
    return this.config !== null;
  }

  /** 保持している復号器設定のコピー。まだ得ていなければ decoder_config_unavailable。 */
  current(): DecoderConfigChunk {
    if (this.config === null) {
      throw new PipelineError("decoder_config_unavailable");
    }
    return createDecoderConfigChunk(this.config);
  }

  /**
   * エンコーダの出力に付いた decoderConfig を受け取る。最初に得たときは、待っている呼び出しを解決する。内容が変わったときは、onChanged を呼ぶ。
   * 最初の設定に description が無い・形が正しくない場合は decoder_config_missing（保持している設定は変えない）。
   */
  accept(input: DecoderConfigInput): void {
    if (input.description === undefined) {
      if (this.config === null) {
        throw new PipelineError("decoder_config_missing");
      }
      return;
    }
    const next = createDecoderConfigChunk({ kind: this.kind, codec: input.codec, description: viewOf(input.description) });
    const previous = this.config;
    this.config = next;
    if (previous === null) {
      this.resolveWaiters();
      return;
    }
    if (previous.codec !== next.codec || !sameBytes(previous.description, next.description)) {
      this.onChanged?.(createDecoderConfigChunk(next));
    }
  }

  /** 復号器設定を得るまで待つ。得たあとなら、すぐ解決する。rejectAll のあとで、まだ得ていなければ、拒否される。 */
  wait(): Promise<DecoderConfigChunk> {
    if (this.config !== null) {
      return Promise.resolve(this.current());
    }
    if (this.rejection !== null) {
      return Promise.reject(this.rejection);
    }
    return new Promise<DecoderConfigChunk>((resolve, reject) => {
      this.waiters.push({ resolve, reject });
    });
  }

  /** 待っている呼び出しを、すべて拒否する。以後の wait（まだ得ていなければ）も、同じ理由で拒否される。 */
  rejectAll(error: PipelineError): void {
    this.rejection = error;
    const waiters = this.waiters;
    this.waiters = [];
    for (const waiter of waiters) {
      waiter.reject(error);
    }
  }

  private resolveWaiters(): void {
    const waiters = this.waiters;
    this.waiters = [];
    for (const waiter of waiters) {
      waiter.resolve(this.current());
    }
  }
}
