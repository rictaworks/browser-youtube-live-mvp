import { BFF_HEADERS } from "./config";

/** 本文が上限を超えた。上限の値だけを持つ（本文の内容を、メッセージへ含めない） */
export class BodyTooLargeError extends Error {
  readonly limitBytes: number;

  constructor(limitBytes: number) {
    super(`request body exceeds ${limitBytes} bytes`);
    this.name = "BodyTooLargeError";
    this.limitBytes = limitBytes;
  }
}

/** 10 進数の数字だけの Content-Length を数にする。不正な値は null（事前検査に使わず、読み込み中の打ち切りに任せる） */
function parseContentLength(value: string | null): number | null {
  if (value === null || !/^\d+$/.test(value.trim())) {
    return null;
  }
  return Number.parseInt(value.trim(), 10);
}

function concatenate(chunks: readonly Uint8Array[], total: number): Uint8Array<ArrayBuffer> {
  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

/**
 * 要求の本文を、上限つきで読む（64 KB。要件 28.1 の入力の上限）。
 *   1. Content-Length が上限を超えるなら、本文を読まずに拒否する（事前検査）
 *   2. 読み込み中に、合計が上限を超えたら、そこで打ち切って拒否する（Content-Length の無い・偽りの申告に備える）
 * 本文が無い・空なら null（本文を付けずに転送する）。上限を超えたら BodyTooLargeError。
 */
export async function readLimitedBody(request: Request, maxBytes: number): Promise<Uint8Array<ArrayBuffer> | null> {
  const stream = request.body;
  const declared = parseContentLength(request.headers.get(BFF_HEADERS.contentLength));
  if (declared !== null && declared > maxBytes) {
    await stream?.cancel().catch(() => undefined);
    throw new BodyTooLargeError(maxBytes);
  }
  if (stream === null) {
    return null;
  }

  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel().catch(() => undefined);
        throw new BodyTooLargeError(maxBytes);
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  return total === 0 ? null : concatenate(chunks, total);
}
