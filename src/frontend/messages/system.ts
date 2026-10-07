// 404 とエラーの画面の文言。
// モックに無い（app-ui/ に、これらの画面は無い）。要件 17.1「文言は断定と対処で構成する」と、17.5「エラーは対処の操作を伴う」により、
// 最小の文にした仮置き。「再試行」と「時間を置いて、再試行してください。」は、app-ui/Studio.dc.html の語句。

export const system = {
  notFound: {
    heading: "Not Found",
    subheading: "404",
    notice: {
      title: "ページが見つかりません。",
      body: "アドレスを確認して、あらためて開いてください。",
    },
    action: "トップへ戻る",
  },
  error: {
    heading: "Error",
    subheading: "エラーが発生しました",
    notice: {
      title: "処理を完了できませんでした。",
      body: "時間を置いて、再試行してください。",
    },
    action: "再試行",
  },
} as const;
