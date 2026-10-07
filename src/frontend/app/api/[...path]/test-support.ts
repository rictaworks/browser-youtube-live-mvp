// BFF（同一オリジン中継）のテストの共通部品。テストからだけ使う（実行時のコードから import しない）。
import { inspect } from "node:util";
import type { BffDependencies } from "./forward";

/** テスト用のダミーの共有秘密値（実際の値ではない） */
export const DUMMY_SECRET = "dummy-bff-secret-0123456789abcdef";
export const DUMMY_BACKEND_ORIGIN = "https://backend.internal.example";

export const PRODUCTION_ENV: Readonly<Record<string, string>> = Object.freeze({
  NODE_ENV: "production",
  BACKEND_ORIGIN: DUMMY_BACKEND_ORIGIN,
  BFF_SHARED_SECRET: DUMMY_SECRET,
});

export const TEST_ENV: Readonly<Record<string, string>> = Object.freeze({
  NODE_ENV: "test",
  BACKEND_ORIGIN: "http://backend:3001",
  BFF_SHARED_SECRET: DUMMY_SECRET,
});

export interface RecordedCall {
  readonly url: string;
  readonly init: RequestInit;
}

export type RespondFn = (url: string, init: RequestInit) => Response | Promise<Response>;

/** 呼び出しを記録する、fetch の疑似実装 */
export function createRecordingFetch(respond: RespondFn): { fetch: BffDependencies["fetch"]; calls: RecordedCall[] } {
  const calls: RecordedCall[] = [];
  const fetchImpl: BffDependencies["fetch"] = async (url, init) => {
    calls.push({ url, init });
    return respond(url, init);
  };
  return { fetch: fetchImpl, calls };
}

export function createLogger(): { warn: jest.Mock; error: jest.Mock } {
  return { warn: jest.fn(), error: jest.fn() };
}

export function makeDeps(overrides: Partial<BffDependencies> = {}): BffDependencies {
  return {
    env: () => TEST_ENV,
    fetch: async () => new Response(null, { status: 204 }),
    logger: createLogger(),
    timeoutMs: 30_000,
    maxBodyBytes: 64 * 1024,
    ...overrides,
  };
}

export function contextFor(...segments: string[]): { params: Promise<{ path: string[] }> } {
  return { params: Promise.resolve({ path: segments }) };
}

/** ログへ渡されたものすべてを、1 つの文字列にする（秘密値がログに出ていないことの検査に使う） */
export function loggedText(logger: { warn: jest.Mock; error: jest.Mock }): string {
  return inspect([...logger.warn.mock.calls, ...logger.error.mock.calls], { depth: 8, maxStringLength: 10_000 });
}

export function headerOf(call: RecordedCall | undefined, name: string): string | null {
  if (call === undefined) {
    throw new Error("fetch was not called");
  }
  return new Headers(call.init.headers).get(name);
}
