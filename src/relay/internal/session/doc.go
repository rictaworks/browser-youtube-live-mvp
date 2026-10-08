// Package session は、中継の取り込みセッション（requirements.md 6.1・10.5・11.9・11.10・13.1〜13.3・14・23.2〜23.6・24.3）です。
// 配信レコードごとに 1 つの IngestSession が、ブラウザからのメッセージの処理・RTMPS の接続と配信キー（メモリのみ）の保持・
// アプリケーションとの内部通信（照合・準備・心拍・事象）・送出世代による古い接続の排除・中断と復帰・心拍の応答が得られないときの
// 自律的な停止を担います。映像・音声の中身には触れません（再エンコードしません。容器の詰め替えと時刻の再基準化だけ）。
//
// # 構成
//
//	Registry       セッション台帳。Accept で WebSocket の接続（Connection）を受け、照合に成功した接続を、配信の識別子で引いた
//	               IngestSession の送信元にする（無ければ、新たに作る）。同一アカウントの新しい取り込みセッションを照合した時点で、
//	               当該アカウントの他の取り込みセッションをすべて閉じる（CloseOthers。完了を待つ）。受信量の超過で切った配信は、
//	               一定の期間、再接続を受け付けない
//	Connection     WebSocket 1 本の受け口。接続通知（hello）の期限（10 秒）・チケットの照合・照合前のメッセージの破棄・
//	               hello の 2 回目やテキストのメッセージ（protocol_violation）・長さ・種別・方向に逸脱するメッセージの破棄を担う
//	IngestSession  配信レコードごとの取り込みセッション。ブラウザの接続が切れても、RTMPS の接続を中断の期限まで保持する
//
// 外との境界は、インターフェースです。WebSocket（BrowserLink）・アプリケーションの HTTP（Backend・EventSink）・RTMPS
// （PublisherFactory・Publisher）・時計（Clock）。試験は、疑似の実装を注入して、実時間を待たずに、実際の YouTube・
// アプリケーションを呼ばずに行います。
//
// # 組み立て（#21）
//
//	client, _ := backend.NewClient(backend.Config{BaseURL: backendInternalURL, Secret: backend.Secret(sharedSecret)})
//	events, _ := backend.NewEventQueue(client, backend.SystemWaiter{}, backend.QueueOptions{}, logger)
//	policy, _ := rtmps.PolicyForGinMode(ginMode) // 環境の許可リスト。本番の経路は、これだけ（rtmps.NewPolicy は、試験だけ）
//	registry, _ := session.NewRegistry(session.Deps{
//		Backend: client, Events: events,
//		Publishers: session.NewRTMPSFactory(policy, rtmps.Config{}),
//		Clock:      session.SystemClock{}, Logger: logger, // Logger は必須（nil は ErrInvalidDeps。捨ててよいときも、捨てる出力先を明示して渡す）
//	})
//	conn, _ := registry.Accept(link) // WebSocket の接続ごとに。link は BrowserLink を満たす
//	conn.Handle(message)             // バイナリのメッセージごとに（所有は接続に移る）
//	conn.HandleText()                // テキストのメッセージ
//	conn.HandleOversize()            // 1 メッセージが 2 MiB を超えた
//	conn.Disconnected()              // WebSocket が閉じた
//	registry.Shutdown(ctx)           // 停止の手順。そのあとに events.Shutdown(ctx)
//
// # 並行性
//
// 状態を持つ Domain Core の型（TimeGuard・TimestampRebaser・IngressPolicer・ProbeMeter・MediaWatchdog・buffer.Policy・
// HeartbeatLiveness）は、並行に呼べません。取り込みセッションごとに 1 つのゴルーチン（イベントループ）が、すべての状態を
// 扱い、ほかのゴルーチン（受信・アプリケーションの呼び出し・RTMPS の接続・後始末）は、結果を待ち行列に積むだけです。
// 準備は数十秒かかり得ますが、その間も、受信・心拍・受領応答は止まりません。
//
// # 契約との差（疑義として報告）
//
//   - ack は、接続ごとに数える（契約 ws-protocol.md の 5.10 は、復帰をまたいで減らない）。TimeGuard も接続ごとに新しくする。
//     ページの再読み込みで、ブラウザのメディアクロックが 0 から数え直しになるため（#18 のレビューの方針）。ack は、
//     その接続で映像・音声の最初のメディアを、両方受けるまで送らない（0 を送らない）
//   - 受領応答は、受け入れたフレーム（ゲート・TimeGuard を通ったもの）の時刻
//   - publish_started と status(confirming) は、RTMPS の接続・publish のあと、接続が約 5 秒（PublishConfirmWindow）保たれて
//     から伝える（go-rtmp は publish の成否 onStatus を知らないため。#19 のレビューの申し送り）
//   - 受信量の計測データの異常（probe.ErrAbnormal）は、bitrate_exceeded と同じに扱う（契約に無い）
package session
