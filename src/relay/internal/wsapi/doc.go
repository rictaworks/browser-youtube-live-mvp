// Package wsapi は、ブラウザからの WebSocket の受け口（GET /ws）と、ブラウザへの送信（session.BrowserLink）の実装です
// （requirements.md 6.1・11.9・11.10・13.3・27・28.1。契約 src/contracts/ws-protocol.md）。
// #20 の取り込みセッション（internal/session）を、実際の WebSocket へ結線します。
//
// # 構成
//
//	Handler  http.Handler（Gin の GET /ws に割り当てる）。WebSocket へ切り替え、接続ごとに、セッション台帳（Acceptor）へ
//	         BrowserLink（link）を渡して Connection を得て、受信の繰り返しを行う。接続数の上限・停止の手順（BeginDrain・Wait）を持つ
//	link     session.BrowserLink の実装。書き込みを 1 つのゴルーチンに直列化し、送信待ちに上限を置き、受領応答を優先し、
//	         ping／pong で死活を確かめる。閉じるときは、致命通知を送り切ってから Close フレームを送る
//
// 接続ごとに使うゴルーチンは、受信の繰り返し（Handler）と書き込み役（link）の 2 つだけです。再エンコードをしないので、
// 1 接続あたりの処理量は小さく、接続数に対して線形です（27 章）。
//
// # 組み立て（server.NewApp が行う）
//
//	handler, _ := wsapi.NewHandler(wsapi.RegistryAcceptor(registry), wsapi.Options{Clock: clock, Logger: logger})
//	router.GET("/ws", gin.WrapH(handler))
//	...
//	handler.BeginDrain()     // 停止の手順：新しい接続を受け付けない
//	registry.Shutdown(ctx)   //   セッションを閉じる（link.Close が呼ばれる）
//	handler.Wait(ctx)        //   接続の処理が終わるのを待つ（猶予を過ぎたら、直ちに落とす）
//
// # 受信の制限
//
//   - 接続元の Origin は検査しません（Handler の CheckOrigin のコメントに、理由を書いてあります。Cookie を使わず、接続チケットで認可するため）
//   - バイナリのみ受理します。テキストは、致命通知 protocol_violation のうえ切断します（Connection.HandleText）
//   - 1 メッセージは 2,097,152 バイトまでです。gorilla/websocket の SetReadLimit は使いません。超過した時点で、ライブラリが Close
//     コード 1009 を送って終わり、致命通知 message_too_large を先に送れないためです。上限 + 1 バイトを読んだ時点（本文を読み切る前）
//     で Connection.HandleOversize を呼び、致命通知のうえ、Close コード 1009 で切ります（readMessage）。確保する量は、実際に届いた量に
//     比例します（宣言された長さに比例して確保しません）
//   - 長さ・種別・方向・時刻の整合の検査と、破棄は、セッション側（Connection）の役目です。接続通知（hello）の期限（10 秒）も、
//     セッション側が同じ時計で数えます
//
// # 送信（link）
//
//   - Send と Close は、待ち行列に積むだけで、ブロックしません（セッションのループを止めません）
//   - 受領応答（ack）と抑制指示（throttle）は、最新の 1 つだけを保ちます（古い値を置き換える）。遅いブラウザの前に、古い値が積み重なりません。
//     書き込み役は、これを優先して書きます（待っている重要なメッセージも、交互に進めて、飢えさせません）
//   - それ以外（接続受理・計測結果・キーフレーム要求・状態通知・致命通知）は、状態の変化を伝えるので、落とさず、順序を保ちます。
//     上限（SendQueueLimit）を超えたら、ブラウザが読んでいないものとして接続を切ります（Send は ErrLinkClosed。セッションは、
//     接続を失ったものとして中断に入り、ブラウザの復帰を待ちます）。中継のメモリが、遅いブラウザで増え続けません
//   - Close は、積んだメッセージ（致命通知）をすべて書いてから、Close フレームを送り、書き込み側を閉じ、相手が閉じるのを
//     LingerTimeout まで待ちます（読み残しのある接続をすぐに閉じると、TCP が RST を返し、致命通知が相手に届かないことがあります）
//
// # 死活の確認と時計
//
// ping の送出・相手の無通信の期限・書き込みの期限・切断の待ちは、すべて、注入された時計（session.Clock）のタイマーで数えます
// （接続に、実時間の期限を設定しません）。そのため、試験は、時計を進めて、これらを決定的に調べられます。
//   - PingInterval（5 秒）ごとに ping。相手から何も（データも pong も）届かない時間が IdleTimeout（15 秒）になったら切る
//   - 1 回の書き込みが WriteTimeout（10 秒）を過ぎても終わらない（読まない相手）なら、接続を閉じて、書き込み役を解放する
//
// # 機密
//
// 記録には、異常の種類（決まった語彙）と、panic の型だけを出します。接続チケット（hello の本文）・メッセージの中身・
// エラーの文言・panic の値は出しません（取り込み先・配信キーを含み得るため）。Handler・link の書式化は、件数だけを示します。
package wsapi
