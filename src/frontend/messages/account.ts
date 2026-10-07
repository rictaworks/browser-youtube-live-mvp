// アカウント（/account）の文言。出どころ: app-ui/Account.dc.html（仮置き。公開用の文章は Gemini が書く）。
// 「モックに無い」と書いたものは、要件・契約の語句だけで補った最小の文。数値（再確認の回数・チャンネル名を保持する分数）は、
// 契約の定数（core/contract）から差し込む。ここには、数値を書かない。
// リンク「Google アカウントの権限の管理」は、privacy.ts の youtubeApi.permissions（ラベルと URL。モックのまま。確認済みではない）を使う。

export const account = {
  heading: "Account",
  // app-ui/Account.dc.html のページの副題。ページの description にも使う
  subheading: "YouTube の接続と、アカウントの管理",
  // モックに無い（読み込み中の表示。要件 17.5: 処理中は、文言を進行形にする）
  loading: "読み込み中…",
  // 進行中の配信があるとき（app-ui/Account.dc.html の「配信中」の 1 文を、断定と対処（要件 17.1）に分けた）
  broadcastInProgress: {
    title: "配信中のため、接続の解除・アカウントの削除・再接続はできません。",
    body: "先に配信を停止してください。",
  },
  youtube: {
    eyebrow: "YouTube",
    statusLabel: "接続の状態",
    channelLabel: "接続先のチャンネル",
    states: {
      connected: {
        chip: "接続済み",
        guide: "チャンネルがあり、ライブ配信が有効です。配信を開始できます。",
        // 進行中の配信があるとき（モックの「配信中」。「配信を開始できます」を除く）
        guideBroadcasting: "チャンネルがあり、ライブ配信が有効です。",
      },
      notConnected: {
        chip: "未接続",
        guide: "YouTube を接続すると、配信できます。チャンネルがない場合は、YouTube でチャンネルを作成してください。",
        // 接続の不成立の通知があるとき（モックの「不成立」。通知がチャンネルの作成を案内するため、短くする）
        guideAfterFailure: "YouTube を接続すると、配信できます。",
      },
      liveNotEnabled: {
        chip: "ライブ未有効",
        guide:
          "YouTube 側でライブ配信を有効にしてください。有効になるまでに時間がかかる場合があります。有効にしたら「再確認」を押してください。",
      },
      revoked: {
        chip: "認可失効",
        guide: "YouTube への許可が取り消されたか、失効しています。もう一度接続してください。",
      },
    },
    channel: {
      // 取得できなかったとき（モックに無い。要件 28.2・契約 2.3: チャンネル名は、取得できなければ null。断定と対処）
      unavailableTitle: "チャンネル名を取得できませんでした。",
      unavailableBody: "時間を置いて、ページを再読み込みしてください。",
      // {minutes} は、契約の channel_title_memory_max_minutes
      note: "チャンネル名は、この画面に表示するためだけに取得します。最長 {minutes} 分間メモリに保持し、保存しません。",
    },
    actions: {
      recheck: "再確認",
      // モックに無い（要件 17.5: 処理中は、文言を進行形にする。Studio のモックの「…中…」の形）
      recheckBusy: "確認中…",
      // {windowMinutes}・{perWindow}・{perDay} は、契約の rate_limits.recheck_per_minute・recheck_per_day
      recheckLimit: "再確認は {windowMinutes} 分に {perWindow} 回、1 日 {perDay} 回までです。",
      // モックに無い（契約 2.3 の can_recheck_at: 次に再確認できる時刻）。{time} は JST の日時
      recheckAvailableAt: "次に再確認できる時刻は {time} です。",
      connect: "YouTube を接続",
      reconnect: "再接続",
      // Studio のモックの語（接続中…）
      connectBusy: "接続中…",
      disconnect: "接続を解除",
      // モックに無い（処理中の進行形）
      disconnectBusy: "解除中…",
    },
    disconnectNote:
      "接続を解除すると、未清算の配信の清算を試みたうえで、Google 側で権限を失効させ、保存した情報を削除します。YouTube 側のストリームは削除しません。",
    permissionsNote: "YouTube の権限は、Google のセキュリティ設定からも取り消せます。",
  },
  danger: {
    eyebrow: "Danger Zone",
    note: "アカウントを削除すると、YouTube の接続を解除し、このアカウントに紐づく全ての記録を削除します。削除は要求の受理と同時に実行します。同じ Google アカウントでの再登録は、次の利用日から可能です。",
    delete: "アカウントを削除",
    // モックに無い（処理中の進行形）
    deleteBusy: "削除中…",
  },
  logout: {
    label: "ログアウト",
    // モックに無い（処理中の進行形）
    busy: "ログアウト中…",
  },
  // 確認用のダイアログ（モックに無い。接続の解除・アカウントの削除は、取り消せないため、確認を挟む。ネイティブの confirm は使わない）。
  // 題・本文は、ボタンの語と、モックの説明（youtube.disconnectNote・danger.note）をそのまま使う。「キャンセル」は Studio のモックの語
  dialog: {
    cancel: "キャンセル",
  },
  // 接続の結果（/account?connect=<結果>。契約 connect_result）の通知。成功（connected・live_not_enabled）は、通知を出さない（状態の表示が変わる）
  connectResult: {
    scopeDenied: {
      title: "接続できませんでした。",
      body: "YouTube の権限が付与されませんでした。配信の作成・確認・終了のために、YouTube の権限が必要です。権限を外さずに、もう一度接続してください。",
    },
    noRefreshToken: {
      title: "接続できませんでした。",
      body: "YouTube の許可を確認できませんでした。もう一度接続してください。",
    },
    noChannel: {
      title: "接続できませんでした。",
      body: "YouTube のチャンネルが見つかりませんでした。YouTube でチャンネルを作成してから、もう一度接続してください。",
    },
    unverifiable: {
      title: "確認できませんでした。",
      body: "時間を置いて、もう一度お試しください。接続の状態は変わっていません。",
    },
  },
  // 操作の失敗の通知。bot 判定・一般的な失敗の文言は、api-notices.ts と system.ts
  notice: {
    // モックのランディング「ログインの試行が多すぎます。」の形（接続の開始の頻度超過。契約 1.7）
    connectRateLimited: { title: "接続の試行が多すぎます。", body: "時間を置いて、もう一度お試しください。" },
    // モックの fine「再確認は 1 分に 1 回、1 日 20 回までです。」の形（再確認の頻度超過。契約 1.7）
    recheckRateLimited: { title: "再確認の回数が上限に達しました。", body: "時間を置いて、もう一度お試しください。" },
  },
} as const;
