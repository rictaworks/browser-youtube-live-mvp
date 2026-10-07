// プライバシーポリシー（/privacy）の文言。出どころ: app-ui/Privacy.dc.html（仮置き。公開用の文章は Gemini が書く）。
// URL は、モックのまま。確認済みではない（GPT のファクトチェック未実施。app-ui/README.md「画面の文言」）。

export const privacy = {
  // モックに無い（ページの description。要件 16.1「プライバシーポリシー」の内容の語句）
  metaDescription: "取得する情報、用途、保持期間、削除方法を示します。",
  heading: "Privacy",
  collected: {
    eyebrow: "Collected",
    googleId: { label: "Google の利用者識別子", value: "不透明な識別子として保持します" },
    refreshToken: {
      label: "更新トークン",
      value: "暗号化して保存します。画面・中継・記録・管理画面へは出力しません",
    },
    channelName: {
      label: "チャンネル名",
      value: "アカウント画面に表示するために取得し、最長 10 分間メモリに保持します。保存しません",
    },
    title: {
      label: "タイトル",
      value: "YouTube の配信識別子を保存するとき、または配信が終了するときまで保持します",
    },
    broadcastId: {
      label: "YouTube の配信識別子",
      value: "清算と利用者への案内のために保持し、終了から 30 日で消去します",
    },
    ipAddress: {
      label: "IP アドレス",
      value: "頻度制限の計数にだけ使います。測定の記録・配信の記録へは残しません",
    },
    media: { label: "映像・音声", value: "保存しません。中継のメモリ上を通過するだけです" },
  },
  notCollected: {
    eyebrow: "Not Collected",
    email: { label: "メールアドレス", value: "取得しません" },
    name: { label: "氏名・表示名・プロフィール画像", value: "取得しません" },
    personal: { label: "生年月日・住所・電話番号", value: "使用しません" },
  },
  purpose: {
    eyebrow: "Purpose",
    login: { label: "ログイン", value: "利用者の識別。要求する権限は識別のみです" },
    youtube: {
      label: "YouTube の権限",
      value: "利用者が同意した目的（自分のチャンネルでのライブ配信の作成・確認・終了・清算）に限って使います",
    },
    measurement: {
      label: "利用状況の測定",
      value: "内部のアカウント識別子にだけ紐づけます。氏名・メールアドレス・チャンネル名・タイトル・IP アドレスは含めません",
    },
  },
  retention: {
    eyebrow: "Retention",
    samples: { label: "健全性の標本・配信の出来事", value: "30 日で削除します" },
    ticket: { label: "接続チケット", value: "失効から 1 日で削除します" },
    session: { label: "セッション", value: "最終利用から 30 日で失効させます" },
    refreshToken: {
      label: "更新トークン",
      value: "接続の解除・アカウントの削除・再接続による置き換えまで",
    },
    streamId: {
      label: "ストリームの識別子",
      value: "最後の確認から 30 日を過ぎたものを消去します",
    },
  },
  youtubeApi: {
    eyebrow: "YouTube API Services",
    body: "本サービスは、YouTube API サービスを利用しています。",
    // 仮置き: URL は未確認
    googlePrivacy: { label: "Google プライバシーポリシー", href: "https://policies.google.com/privacy" },
    revoke: "YouTube の権限は、Google のセキュリティ設定から、いつでも取り消せます。",
    // 仮置き: URL は未確認
    permissions: { label: "Google アカウントの権限の管理", href: "https://myaccount.google.com/permissions" },
  },
  deletion: {
    eyebrow: "Deletion",
    disconnect: { label: "接続の解除", value: "アカウント画面から、利用者ご自身で行えます" },
    deleteAccount: {
      label: "アカウントの削除",
      value: "アカウント画面から、利用者ご自身で行えます。要求の受理と同時に、紐づく全ての記録を削除します",
    },
    request: { label: "削除の要求", value: "7 日以内に応じます" },
  },
} as const;
