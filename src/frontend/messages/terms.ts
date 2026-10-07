// 利用規約（/terms）の文言。出どころ: app-ui/Terms.dc.html（仮置き。公開用の文章は Gemini が書く）。
// URL は、モックのまま。確認済みではない（GPT のファクトチェック未実施。app-ui/README.md「画面の文言」）。
import { SERVICE_SUMMARY } from "./common";

export const terms = {
  // モックに無い（ページの description。要件 16.1「利用規約」の内容の語句）
  metaDescription: "本サービスの利用条件です。YouTube 利用規約への同意を含みます。",
  heading: "Terms",
  service: {
    eyebrow: "Service",
    body: SERVICE_SUMMARY,
  },
  eligibility: {
    eyebrow: "Eligibility",
    youtube: { label: "YouTube", value: "YouTube チャンネルを持ち、ライブ配信が有効になっていること" },
    age: {
      label: "年齢",
      value: "YouTube の利用条件（配信者の年齢要件を含む）を満たしていること。配信者は 16 歳以上です",
    },
    line: { label: "回線", value: "上り回線の実効スループットが 1,200 kbps 以上であること" },
  },
  limits: {
    eyebrow: "Limits",
    count: {
      label: "配信の回数",
      value: "アカウントごとに 1 日 1 回（JST 03:00 区切り）。YouTube でライブが確定した時点で消費します",
    },
    length: { label: "配信の長さ", value: "1 配信 60 分まで" },
    concurrent: { label: "同時配信", value: "全体で 3 本まで" },
    frequency: { label: "受付の頻度", value: "アカウントごとに 1 時間に 10 回まで" },
    monthly: { label: "月あたりの配信量", value: "送信転送量の予算に達した月は、新規の受付を行いません" },
    daily: { label: "1 日の開始数", value: "YouTube API の割り当てにより、全体で上限があります" },
    note: "制限値は変更することがあります。",
  },
  youtubeTerms: {
    eyebrow: "YouTube Terms",
    body: "本サービスを利用することで、利用者は YouTube 利用規約に同意したものとします。",
    // 仮置き: URL は未確認
    link: { label: "YouTube 利用規約", href: "https://www.youtube.com/t/terms" },
  },
  provision: {
    eyebrow: "Provision",
    fee: { label: "料金", value: "無料です。課金・収益化に関する機能はありません" },
    uptime: { label: "稼働", value: "無料枠の資源が尽きた場合は、サービスを停止します" },
    maintenance: {
      label: "保守・監視",
      value: "リリース後の不具合対応・機能改修の体制を持たず、稼働の監視を行いません",
    },
  },
} as const;
