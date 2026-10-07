// アカウント画面（/account）の設定値。クエリ名・要素の識別子・待ち時間は、ここへ集める。

/** YouTube 接続の結果を知らせるクエリの名前（契約 http-api.md: /account?connect=<connect_result>） */
export const CONNECT_QUERY = "connect";

/** 接続・再接続のボタンの id。接続を解除して、押したボタンが無くなったとき、フォーカスを移す先 */
export const ACCOUNT_CONNECT_BUTTON_ID = "account-connect-button";

/** 進行中の配信の案内の id。無効にした操作の説明（aria-describedby）が指す */
export const ACCOUNT_BROADCAST_NOTICE_ID = "account-broadcast-notice";

/** 再確認の制限の説明の id。再確認を無効にしている間の説明（aria-describedby）が指す */
export const ACCOUNT_RECHECK_HINT_ID = "account-recheck-hint";

/** 再確認できる時刻の、再評価の余裕（ミリ秒）。タイマーが、時刻の直前に動いても、取りこぼさない */
export const COOLDOWN_MARGIN_MS = 50;
