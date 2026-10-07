import { NextResponse } from "next/server";

// ヘルスチェック（docker compose の healthcheck・デプロイ先の死活確認が使う）。毎回、評価する
export const dynamic = "force-dynamic";

export function GET() {
  return NextResponse.json({ status: "ok" }, { headers: { "Cache-Control": "no-store" } });
}
