/**
 * @jest-environment node
 */
import { BodyTooLargeError, readLimitedBody } from "./limited-body";

const LIMIT = 64;

// highWaterMark: 0 は、読み取りの要求があるまで、pull を呼ばない（読んでいないことを、検査できる）
function streamOf(chunks: Uint8Array[], onPull?: (index: number) => void, onCancel?: () => void): ReadableStream<Uint8Array> {
  let index = 0;
  return new ReadableStream<Uint8Array>(
    {
      pull(controller) {
        onPull?.(index);
        if (index < chunks.length) {
          controller.enqueue(chunks[index]);
          index += 1;
        } else {
          controller.close();
        }
      },
      cancel() {
        onCancel?.();
      },
    },
    { highWaterMark: 0 },
  );
}

function postWithStream(stream: ReadableStream<Uint8Array>, headers: Record<string, string> = {}): Request {
  return new Request("http://localhost:3000/api/broadcasts", {
    method: "POST",
    body: stream,
    headers,
    // Node の fetch は、ストリームの本文に duplex の指定を要する
    duplex: "half",
  } as RequestInit);
}

const bytes = (length: number, value = 0x61): Uint8Array<ArrayBuffer> => new Uint8Array(length).fill(value);

describe("readLimitedBody: 本文の上限（Content-Length の事前検査と、読み込み中の打ち切り）", () => {
  it("本文が無い要求は、null を返す", async () => {
    const request = new Request("http://localhost:3000/api/state", { method: "GET" });

    await expect(readLimitedBody(request, LIMIT)).resolves.toBeNull();
  });

  it("上限ちょうどの本文は、そのまま返す", async () => {
    const request = new Request("http://localhost:3000/api/broadcasts", { method: "POST", body: bytes(LIMIT) });

    const body = await readLimitedBody(request, LIMIT);

    expect(body).toEqual(bytes(LIMIT));
  });

  it("上限を 1 バイト超える本文（Content-Length あり）は、本文を読まずに拒否する", async () => {
    let pulled = false;
    const stream = streamOf([bytes(LIMIT + 1)], () => {
      pulled = true;
    });
    const request = postWithStream(stream, { "content-length": String(LIMIT + 1) });

    await expect(readLimitedBody(request, LIMIT)).rejects.toBeInstanceOf(BodyTooLargeError);
    expect(pulled).toBe(false);
  });

  it("Content-Length が上限以内でも、実際に読んだ量が上限を超えたら、打ち切って拒否する（申告を信用しない）", async () => {
    let cancelled = false;
    const stream = streamOf([bytes(40), bytes(40), bytes(40)], undefined, () => {
      cancelled = true;
    });
    const request = postWithStream(stream, { "content-length": "10" });

    await expect(readLimitedBody(request, LIMIT)).rejects.toBeInstanceOf(BodyTooLargeError);
    expect(cancelled).toBe(true);
  });

  it("Content-Length が無い（チャンク転送の）本文も、読み込み中に上限を超えたら、打ち切って拒否する", async () => {
    let pulls = 0;
    let cancelled = false;
    const stream = streamOf(
      Array.from({ length: 100 }, () => bytes(16)),
      () => {
        pulls += 1;
      },
      () => {
        cancelled = true;
      },
    );
    const request = postWithStream(stream);

    await expect(readLimitedBody(request, LIMIT)).rejects.toBeInstanceOf(BodyTooLargeError);
    expect(cancelled).toBe(true);
    // 上限（64 バイト = 16 バイト × 4）を超えた 5 つ目で止め、残りを読まない
    expect(pulls).toBeLessThan(10);
  });

  it("複数のチャンクを、順序どおりに結合して返す", async () => {
    const request = postWithStream(streamOf([new TextEncoder().encode("{\"a\":"), new TextEncoder().encode("1}")]));

    const body = await readLimitedBody(request, LIMIT);

    expect(new TextDecoder().decode(body ?? new Uint8Array())).toBe('{"a":1}');
  });

  it("空の本文は、本文が無いものとして null を返す（空のバイト列を転送しない）", async () => {
    const request = new Request("http://localhost:3000/api/auth/logout", { method: "POST", body: new Uint8Array(0) });

    await expect(readLimitedBody(request, LIMIT)).resolves.toBeNull();
  });

  it.each([["abc"], ["-1"], ["1e3"], ["1.5"]])(
    "Content-Length が不正（%j）でも、読み込み中の打ち切りで守る（事前検査だけに頼らない）",
    async (contentLength) => {
      const request = postWithStream(streamOf([bytes(40), bytes(40)]), { "content-length": contentLength });

      await expect(readLimitedBody(request, LIMIT)).rejects.toBeInstanceOf(BodyTooLargeError);
    },
  );
});

describe("BodyTooLargeError", () => {
  it("上限の値を持ち、メッセージに本文の内容を含めない", () => {
    const error = new BodyTooLargeError(65536);

    expect(error.limitBytes).toBe(65536);
    expect(error.message).toBe("request body exceeds 65536 bytes");
    expect(error.name).toBe("BodyTooLargeError");
  });
});
