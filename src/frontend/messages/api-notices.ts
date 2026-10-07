// API の呼び出しが失敗したときの通知の文言のうち、ランディング（/）とアカウント（/account）で共通のもの。
// 出どころ: app-ui/Landing.dc.html の MOCK STATE（bot 判定）と、要件 9.2・17.1・28.1（仮置き。公開用の文章は Gemini が書く）。
// 一般的な失敗（通信の失敗・想定外の応答）の文言は、system.ts の error.notice（断定と対処）を使う。

export const apiNotice = {
  // app-ui/Landing.dc.html の MOCK STATE「bot 判定」
  botCheckFailed: {
    title: "確認に失敗しました。",
    body: "時間を置いて、もう一度お試しください。",
  },
  // モックに無い（要件 9.2: 頻度の拒否は、再試行の目安時刻を示す）。{time} は JST の日時
  retryAt: "再試行の目安時刻は {time} です。",
  // モックに無い（契約 1.8・要件 28.1: bot 判定は、サイトキーを要する。キーが無いのは、サーバー側の設定の誤り。事実だけの文）
  recaptchaNotConfigured: {
    title: "設定エラーです。",
    body: "bot 判定のサイトキー（RECAPTCHA_SITE_KEY）が設定されていません。",
  },
} as const;
