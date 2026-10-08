// Package backend は、中継（Go）からアプリケーション（Rails）への内部通信のクライアントです
// （requirements.md 6.1・10.1・11.9。契約 src/contracts/internal-api.md）。
//
// 呼び出しは 4 つで、すべて中継からアプリケーションへの一方向です（アプリケーションから中継への指示は、心拍の応答に載ります）。
//
//	Verify     照合。接続チケットを 1 回限りで消費し、配信の識別子・状態・送出世代・上限・アカウントの不透明な値を得る
//	Provision  準備。YouTube の資源の準備を要求し、取り込み先と配信キーを得る（冪等。数十秒かかり得る）
//	Heartbeat  心拍。送出の統計とブラウザ側の出来事を送り、応答で指示（継続・停止）と状態の通知を受ける（seq で冪等）
//	Event      事象。中継が観測した出来事を通知する（冪等。EventQueue が、保持と再送を行う）
//
// # 認証と経路
//
// 要求は、BACKEND_INTERNAL_URL（内部側の口。外部から到達できない経路）へ、ヘッダ X-Relay-Secret（RELAY_SHARED_SECRET）つきで送ります。
// リダイレクトは追いません（秘密値つきの要求を、別の場所へ転送しない）。環境のプロキシは使いません。期限は呼び出しごとに持ちます
// （既定は、照合 10 秒・準備 90 秒・心拍と事象 5 秒）。
//
// # 失敗の型
//
// 失敗は、errors.Is で判定できる定数のエラー（ErrTicketInvalid・ErrBroadcastNotAttachable・ErrStaleEpoch など）です。
// アプリケーションが返したエラーは *APIError で、呼び出しの種類・HTTP ステータス・符号（契約の語彙だけ）・終了理由を持ちます。
// ErrUnavailable は、到達できない・期限切れ・5xx で、再送の対象です（EventQueue が再送する）。呼び出し側の取り消しは、
// context.Canceled のままで、ErrUnavailable ではありません。
//
// # 機密
//
// 共有の秘密値（Secret）・接続チケット（Ticket）・取り込み先（IngestURL）・配信キー（rtmps.StreamKey）は、
// ログ・エラー・%v・JSON のどこにも、中身を出しません。エラーの文言は、応答の本文を写しません（契約の符号の語彙だけを出します）。
package backend
