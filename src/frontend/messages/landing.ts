// ランディング（/）の文言。出どころ: app-ui/Landing.dc.html（仮置き。公開用の文章は Gemini が書く）。
// 「モックに無い」と書いたものは、要件・契約の語句だけで補った最小の文。数値（60 分・3 本・1,200 kbps・1 日 1 回 など）は、
// 契約の定数（core/contract）から差し込む（{minutes} などのプレースホルダー）。ここには、数値を書かない。

export const landing = {
  hero: {
    headline: { lead: "Go Live,", accent: "From a Tab." },
    summary:
      "配信ソフトをインストールせず、ブラウザのタブを開くだけで、カメラ・マイク・画面共有を合成した映像を、あなたの YouTube チャンネルへライブ配信します。",
    login: "LOG IN WITH GOOGLE",
    // モックに無い（要件 17.5: 処理中は、文言を進行形に替える。ボタンの英語表記に合わせた最小の文）
    loginBusy: "LOGGING IN…",
    // モックに無い（ログイン済みの利用者を、スタジオへ誘導する。app-ui/Account.dc.html のナビの語 Studio を使う）
    openStudio: "OPEN STUDIO",
    fine: "ログインで要求するのは識別のみです。メールアドレスとプロフィールは要求しません。YouTube の権限は、「YouTube を接続」を操作したときに、はじめて要求します。",
  },
  value: {
    number: "01",
    label: "VALUE",
    heading: "Why a Tab",
    noInstall: { title: "No Install", body: "対応ブラウザでページを開けば、配信できます。" },
    noStreamKey: {
      title: "No Stream Key",
      body: "配信枠・配信キー・紐づけは、システムが自動で用意します。配信キーを見ることも、貼ることもありません。",
    },
    oneScreen: { title: "One Screen", body: "ソースの準備・プレビュー・開始・健全性の確認・停止を、1 画面で行います。" },
    autoClose: { title: "Auto Close", body: "タブを閉じた場合や回線が切れた場合も、配信が YouTube 上に残り続けません。" },
  },
  limits: {
    number: "02",
    label: "LIMITS",
    heading: "Fair Use",
    lead: "無料枠の資源を、多くの人が使えるようにするための制限です。",
    stats: {
      count: { unit: "回 / 日", caption: "配信できる回数", captionNote: "（JST 03:00 区切り）" },
      length: { unit: "分", caption: "1 配信の長さ" },
      concurrent: { unit: "本", caption: "全体の同時配信数" },
      line: { unit: "kbps", caption: "必要な上り回線", captionNote: "（実効スループット）" },
    },
    other: {
      eyebrow: "Other Limits",
      daily: { label: "1 日の開始数", value: "YouTube API の割り当てにより、全体で上限があります" },
      monthly: { label: "月あたりの配信量", value: "送信転送量の予算に達した月は、新規の受付を行いません" },
      quality: {
        label: "画質",
        value: "配信中は解像度を変えません。回線が下限を下回った場合は、劣化を表示して継続し、映像が届かない状態が続くと終了します",
      },
      resume: {
        label: "中断の許容",
        value: "{seconds} 秒を超える中断から、同じ配信へは復帰できません。復帰は 1 配信につき {resumes} 回までです",
      },
      deletion: { label: "アカウント削除後", value: "同じ Google アカウントでの再登録は、次の利用日から可能です" },
    },
  },
  environment: {
    number: "03",
    label: "ENVIRONMENT",
    heading: "Requirements",
    supported: {
      eyebrow: "Supported",
      guaranteed: { label: "保証する環境", value: "デスクトップの Chrome・Edge（最新版）" },
      others: { label: "その他のブラウザ", value: "能力検出を通れば利用可（保証なし）" },
      mobile: { label: "モバイル", value: "保証しない" },
    },
    before: {
      eyebrow: "Before You Start",
      youtube: "YouTube チャンネルを持ち、ライブ配信が有効になっていること。有効化には時間がかかる場合があります。",
      age: "YouTube の利用条件（配信者の年齢要件を含む）を満たしていること。",
      line: "上り回線の実効スループットが {kbps} kbps 以上あること。",
    },
  },
  final: {
    heading: { lead: "Ready When", accent: "You Are." },
  },
  // ログインの拒否・失敗の通知（断定と対処。要件 17.1）。bot 判定・頻度超過の文言の一部は、api-notices.ts
  notice: {
    // app-ui/Landing.dc.html の MOCK STATE「再登録の保留」
    registrationHeld: {
      title: "このアカウントは、削除から間もないため、まだ登録できません。",
      body: "次の利用日（JST 03:00）から利用できます。",
    },
    // app-ui/Landing.dc.html の MOCK STATE「頻度超過」
    rateLimited: { title: "ログインの試行が多すぎます。", body: "時間を置いて、もう一度お試しください。" },
    // モックに無い（契約 http-api.md: /?login_error=oauth_failed。ログインの失敗。対処は、モックの語句）
    oauthFailed: { title: "ログインできませんでした。", body: "時間を置いて、もう一度お試しください。" },
  },
} as const;
