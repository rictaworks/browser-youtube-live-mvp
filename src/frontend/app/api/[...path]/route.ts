import { BFF_MAX_BODY_BYTES, BFF_UPSTREAM_TIMEOUT_MS } from "./config";
import { createBffHandler, type BffRouteContext } from "./forward";

// 同一オリジン中継（BFF）。ブラウザから見た HTTP の相手を、フロントエンドのオリジンだけにする（requirements.md 6.1）。
// /api/* のすべてのメソッドを、BACKEND_ORIGIN の /api/* へ中継する。仕組みは forward.ts、設定値は config.ts。
// GET /healthz（app/healthz/route.ts）は、/api/ 配下ではないため、この中継の対象外。

// 毎回、評価する（環境変数・Cookie・応答を、ビルド時に固定しない）
export const dynamic = "force-dynamic";
export const runtime = "nodejs";
// 関数の実行時間の上限（秒）。バックエンドを待つ上限（BFF_UPSTREAM_TIMEOUT_MS = 30 秒）より長くする。
// 短いと、関数が先に打ち切られ、JSON の 502 ではなく、プラットフォームのエラーが返る。Next.js が静的に読むため、リテラルで書く
// （config.ts の値との関係は、route.test.ts が検査する）
export const maxDuration = 40;

function handle(request: Request, context: BffRouteContext): Promise<Response> {
  const handler = createBffHandler({
    env: () => process.env,
    // Next.js が差し込む fetch を、呼び出しのたびに参照する
    fetch: (input, init) => fetch(input, init),
    logger: console,
    timeoutMs: BFF_UPSTREAM_TIMEOUT_MS,
    maxBodyBytes: BFF_MAX_BODY_BYTES,
  });
  return handler(request, context);
}

export function GET(request: Request, context: BffRouteContext): Promise<Response> {
  return handle(request, context);
}

export function HEAD(request: Request, context: BffRouteContext): Promise<Response> {
  return handle(request, context);
}

export function POST(request: Request, context: BffRouteContext): Promise<Response> {
  return handle(request, context);
}

export function PUT(request: Request, context: BffRouteContext): Promise<Response> {
  return handle(request, context);
}

export function PATCH(request: Request, context: BffRouteContext): Promise<Response> {
  return handle(request, context);
}

export function DELETE(request: Request, context: BffRouteContext): Promise<Response> {
  return handle(request, context);
}

export function OPTIONS(request: Request, context: BffRouteContext): Promise<Response> {
  return handle(request, context);
}
