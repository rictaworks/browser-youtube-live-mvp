// Package rtmps は、符号化済みの映像・音声（FLV のタグの本体）を、RTMPS の publish として、YouTube の取り込み口へ送出します
// （requirements.md 6.1・10.1・11.10・28.1）。再エンコードはせず、符号化データには触れません（容器の詰め替えは、internal/flv）。
//
// # 構成
//
//	Policy・Validate・ValidatedDestination  送出先の検証（destination.go）。送出先は、YouTube の取り込み口であることを確認した
//	                                        RTMPS の宛先に限る。平文の rtmp・443 以外のポート・ユーザー情報・クエリ・過大なパスを拒否する
//	StreamKey                               配信キー（streamkey.go）。ログ・エラー・%v・JSON のどこにも、中身を出さない
//	Dial                                    接続（dial.go）。TLS 1.2 以上・証明書の検証あり・SNI はホスト名。connect -> createStream -> publish
//	Publisher                               非同期の送出キュー・送出待ちの管理・切断の検知・Close と Abort（publisher.go）
//	killSwitch                              go-rtmp の接続を、外から直ちに壊す仕掛け（killswitch_unix.go）
//
// 呼び出し側（取り込みセッション）は、次の順で使います。
//
//	policy, _ := rtmps.PolicyForGinMode(os.Getenv("GIN_MODE"))   // 環境の許可リスト（production には、開発用の許可が存在しない）
//	dest, err := rtmps.Validate(ingestURL, policy)               // 準備の応答の取り込み先（配信キーを含まない URL）
//	pub, err := rtmps.Dial(ctx, dest, rtmps.StreamKey(key), rtmps.Config{})
//	pub.WriteMeta(meta); pub.WriteVideo(0, videoConfig); pub.WriteAudio(0, audioConfig)   // 復号器設定は、最初のメディアフレームより前に
//	pub.WriteVideo(ts, frame) ...                                // 非同期。送出待ちが 3 秒分に達したら ErrBufferOverflow（呼び出し側が再接続）
//	<-pub.Closed(); pub.Err()                                    // 切断の検知。ErrPublishRejected・ErrDisconnected・ErrBufferOverflow
//	pub.Close()                                                  // 停止：送り切ってから切断し、受け口が閉じるのを待つ（CloseLinger まで）。強制は Abort
//
// # go-rtmp（v0.0.7）の制約と、この実装の補い
//
// go-rtmp は、2024-07 から更新が止まっています（README は Work in progress）。固定したバージョンで使い、足りない点は、
// このパッケージで補います（go-rtmp v0.0.7 のソースを読んで確かめた挙動です）。
//
//   - Dial 系は context を取らず、RTMP のハンドシェイクにタイムアウトが無く、connect・createStream は応答が来ないと待ち続けます
//     -> 接続の試行を別のゴルーチンで行い、期限・取り消し・切断で見放します。ソケットは、net.Dialer の Control で dup して持ち、
//     shutdown で壊します（killSwitch）。応答が来ない受け口との試行は、ゴルーチンを 1 つ残します（解く手段が無い。既知の制約）
//   - Stream.Write は並行に呼べず（共有のメッセージ構造体を書き換える）、1 回 5 秒の固定のタイムアウトがあります
//     -> 単一の書き込みのゴルーチン（キュー）だけが呼びます
//   - Publish は、サーバーの応答（onStatus）を待たず、応答を処理もしません（未知のコマンドとして読み捨てます）
//     -> 配信キーの不正・使用中は、publish の直後の切断で検知します（ErrPublishRejected）
//   - 接続の切断を通知する手段が無く、LastError の参照だけです -> 一定の間隔で見張ります
//   - 未対応のメッセージ（未知のユーザー制御イベント・AMF3 のコマンドなど）を受けると、読み取りが止まります（LastError が非 nil に
//     なります）-> Publisher は、これを切断として扱います（接続を閉じ、呼び出し側が再接続します）。YouTube が、そのような
//     メッセージを送るかは、実機で確かめます。原因は、ログに、種類（protocol）と原因の文言で残ります（failure.go）
//   - Close は、書き込み中のものを最大 3 秒待ち、TLS の close_notify の書き込みに最大 5 秒かかり得ます
//     -> 失敗・Abort・期限切れでは、先に接続を壊してから閉じます
//   - Close は、送ったものを受け口が受け取ったかを待たず、ソケットを閉じます。読んでいない受信（受け口の close_notify の返事・
//     確認応答）が残ったままソケットを閉じると、OS は FIN ではなく RST を送り、送信キューに残った未送信の分を捨てます
//     （試験で、配信の最後の部分が受け口へ届かない事故が、実際に起きました）
//     -> 送り切った Close は、go-rtmp が接続を閉じたあと、送信側だけを閉じ（FIN）、受信を捨てながら、受け口が閉じるのを
//     CloseLinger（既定 2 秒）まで待ってから、記述子を解放します（killSwitch.finish）。待ちは有限で、失敗にはしません
//   - CreateStream は、チャンクの大きさを変えると、標準のロガー（logrus）へ 1 行を出します（配信キーは含みません）
//
// # 配信キー
//
// 配信キーは、メモリにのみ置きます。Dial が、publish の呼び出しに 1 回使うだけで、Publisher は保持しません。ファイルへ保存せず、
// ログへ出さず、エラーの文言にも含めません（rules_test.go が、reveal の呼び出しが 1 か所だけであることを走査で確かめます）。
//
// このパッケージは、unix 系の OS だけを対象にします（killSwitch が、記述子を dup して shutdown します）。
package rtmps
