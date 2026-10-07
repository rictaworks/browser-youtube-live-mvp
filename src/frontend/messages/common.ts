// 全画面で使う文言: ページの共通の書き出し（meta）・共通レイアウト・利用規約とプライバシーポリシーの共通部分・共通部品。
// 仮置き（ja.ts の冒頭を参照）。「モックに無い」と書いた文言は、requirements.md の語句と 17.1「断定と対処」で補った最小の文。

// 本サービスの概要。出どころ: app-ui/Terms.dc.html の Service（ページの description と、利用規約の本文で使う）
export const SERVICE_SUMMARY =
  "本サービスは、配信ソフトをインストールせず、ブラウザのタブを開くだけで、カメラ・マイク・画面共有を合成した映像を、利用者自身の YouTube チャンネルへライブ配信するサービスです。";

export const common = {
  meta: {
    // ページの題の書式。{title} にはページ題が入る（書式であって、文章ではない）
    pageTitle: "{title} | {brand}",
    siteDescription: SERVICE_SUMMARY,
  },
  layout: {
    // モックに無い（スキップリンク。要件 17.6「すべての操作をキーボードで行えること」）
    skipLink: "本文へ移動",
  },
  legal: {
    // ナビ・フッター・ページの副題の「利用規約」「プライバシーポリシー」（app-ui/ の各画面のナビ）
    terms: "利用規約",
    privacy: "プライバシーポリシー",
    // 利用規約・プライバシーポリシーの末尾の Contact（モックでは、2 つの画面で同じ内容）
    contact: {
      eyebrow: "Contact",
      operator: { label: "運営", value: "Ricta Works" },
      address: { label: "連絡先", value: "info@rictaworks.jp" },
      effectiveDate: { label: "施行日", value: "未定" },
    },
  },
  ui: {
    notice: {
      // モックに無い（要件 17.5 の通知の種類の語句。状態を色と図形だけでなく文言でも伝えるため、画面には出さず支援技術へ読ませる）
      severity: { info: "情報", warning: "警告", error: "エラー" },
    },
    externalLink: {
      // モックに無い（外部リンクが新しいタブで開くことを、支援技術へ伝える）
      opensInNewTab: "（新しいタブで開きます）",
    },
  },
} as const;
