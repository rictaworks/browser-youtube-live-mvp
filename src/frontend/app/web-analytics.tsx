"use client";

import { Analytics, type BeforeSendEvent } from "@vercel/analytics/next";

/**
 * 測定する URL から、クエリとフラグメントを取り除く（認可の結果・失敗の符号などを、測定へ含めない。要件 18.2・28.2）。
 * ページのタイトル・IP アドレスは、この測定の送信内容に含まれない。URL として解釈できない値は、測定しない（null）。
 */
export function sanitizeAnalyticsEvent(event: BeforeSendEvent): BeforeSendEvent | null {
  let url: URL;
  try {
    url = new URL(event.url);
  } catch {
    return null;
  }
  url.search = "";
  url.hash = "";
  return { ...event, url: url.toString() };
}

/**
 * ページの閲覧の測定（Vercel Web Analytics。要件 18.2）。本番だけ、ルートのレイアウトが描画する（開発・テストでは、何もしない）。
 * mode は、production に固定する（自動判定の開発モードは、外部の debug 用スクリプトを読み込むため）。
 */
export function WebAnalytics() {
  return <Analytics mode="production" beforeSend={sanitizeAnalyticsEvent} />;
}
