# 内部通信 API（中継 → アプリケーション）

中継（Gin）からアプリケーション（Rails）への、一方向の内部通信の契約です。実装は、アプリケーション側（`src/backend/app/controllers/internal`。#14）と、中継側のクライアント（`src/relay/internal/backend`。#20）が行います。要件の出どころは requirements.md の 6.1・10.1・10.5・11.9・13.2・13.3・14 です。

- 符号は [enums.json](enums.json)、数値は [limits.json](limits.json) が正です。数値は `limits.json` のキーを添えて書きます。
- 印の「**仮置き**」は、要件・設計メモに定めが無く、契約が置いた解釈です。9 章に一覧します。

## 1. 経路と認証

| 項目 | 内容 |
|---|---|
| 向き | 呼び出しは、中継からアプリケーションへの一方向です。アプリケーションから中継への指示は、心拍の応答（`command`・`notices`）に載せて返します。アプリケーションから中継を呼びません |
| 口 | アプリケーションの**内部側の口（3101）だけ**で受けます（`BACKEND_INTERNAL_URL`。開発環境は `http://backend:3101`）。公開側の口（`PORT`。既定 3001）では、`/internal/` 配下は 404 です。反対に、`/api/`・`/admin/` は、内部側の口では 404 です。内部側の口は、外部から到達できない経路（docker compose の内部ネットワーク、Railway のプライベートネットワーク）でのみ受けます |
| 認証 | ヘッダ `X-Relay-Secret`（値は `RELAY_SHARED_SECRET`）。アプリケーションは、**定数時間で**比較します。欠落・不一致は 401（`unauthorized`）です。認証の前に、配信の識別子の存在を明かしません（認証に失敗した要求へは、配信の有無によらず同じ応答） |
| 形式 | `Content-Type: application/json; charset=utf-8`。UTF-8。キーは snake_case。時刻は ISO 8601（JST、`+09:00`、秒まで）。識別子（`broadcast_id`）は UUID の文字列。リダイレクトは使いません（中継は追いません） |
| 機密 | 秘密値・接続チケット・配信キー・取り込み先（URL）を、ログ・例外のメッセージ・DB・応答の余分な項目へ出しません。内部通信のログには、配信レコードの識別子・呼び出しの種別・結果（HTTP ステータス）だけを出します |

## 2. エラー

エラーの形は、`{"error":{"code":"<符号>","details":{…}}}` です（`details` は省略できます。省略は空のオブジェクトと同じ）。HTTP のステータスと符号は、次のとおりです。

| 符号 | HTTP | 意味 | 返す呼び出し |
|---|---|---|---|
| `unauthorized` | 401 | `X-Relay-Secret` が欠落している、または一致しない | すべて |
| `not_found` | 404 | 配信が存在しない（認証に成功したあと） | provision・heartbeat・events |
| `invalid_input` | 422 | JSON を解釈できない、必須の項目が無い、値が不正（`details` の `fields` に、不備のある項目名の配列） | すべて |
| `ticket_invalid` | 404 | 接続チケットが、未知・失効・使用済みのいずれか（区別しません） | verify |
| `broadcast_not_attachable` | 409 | 配信が終了済み、または状態が不適（`reserved`・`awaiting_media`・`confirming`・`live`・`interrupted` 以外） | verify |
| `stale_epoch` | 409 | 送出世代が、最新と一致しない | provision |
| `broadcast_ended` | 409 | 配信が終了済み（`details` の `end_reason` に、終了理由） | provision |
| `prior_unsettled` | 422 | 先行配信が未清算で、準備を中止し、配信を終了した | provision |
| `prepare_failed` | 502 | 準備に失敗し、配信を終了した | provision |
| `authorization_revoked` | 409 | 認可が失効していて、配信を終了した | provision |
| `live_not_enabled` | 409 | ライブ配信が有効でない（制限中を含む）ため、配信を終了した | provision |

provision の失敗のうち、`stale_epoch` 以外は、配信の終了を伴います。`details` の `end_reason`（列挙 `end_reason` の値）に、記録した終了理由を載せます。

| 符号 | `details` の `end_reason` |
|---|---|
| `broadcast_ended` | 実際の終了理由 |
| `prior_unsettled` | `prior_unsettled` |
| `prepare_failed` | `prepare_failed` |
| `authorization_revoked` | `authorization_revoked` |
| `live_not_enabled` | `prepare_failed`（10.6：ライブ未有効は、接続状態を `live_not_enabled` にし、配信は準備の失敗として終了する）（**仮置き**） |

## 3. 送出世代（`epoch`）

- 配信レコードごとの連番です（14 章）。接続チケットの照合（verify）の成功のたびに、1 進みます。
- 以後の provision・heartbeat・events は、`epoch` が最新と一致するものだけが有効です。古い世代の呼び出しは、provision が 409（`stale_epoch`）、heartbeat が停止の指示（`{"command":"stop","reason":"stale_epoch"}`）、events が 204（無視）です。これにより、古い取り込みセッションの送出が止まります。
- 中継は、verify の応答の `epoch` を保持し、以後のすべての呼び出しに付けます。

## 4. 呼び出し

### `POST /internal/v1/verify`

照合です。接続通知（`hello`）の受信を契機に、中継が呼びます。

要求：

```json
{"ticket":"dummy-ticket-0123456789abcdefghijklmnopqrstuvwxyz"}
```

応答 200：

```json
{"broadcast_id":"2f6c1d0e-7b5a-4f0e-9a43-5c8f1e2d3a4b","state":"reserved","epoch":1,"account_key":"3f1b2c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f809","profile":null,"limits":{"time_limit_seconds":3600}}
```

| 項目 | 型 | 内容 |
|---|---|---|
| `broadcast_id` | 文字列 | 配信レコードの識別子（UUID） |
| `state` | 文字列 | 配信レコードの状態（列挙 `broadcast_state` の値）。受け付けるのは `reserved`・`awaiting_media`・`confirming`・`live`・`interrupted` |
| `epoch` | 整数 | 新しい送出世代（照合のたびに 1 進めた値） |
| `account_key` | 文字列 | アカウントを区別する不透明な値。内部のアカウント識別子の HMAC-SHA256（鍵は `RELAY_SHARED_SECRET` から導出）を、64 文字の小文字の 16 進数で表したもの。同一アカウントで安定し、異なるアカウントで衝突せず、内部の識別子を復元できません。中継は、内容を解釈せず、等値の比較（同一アカウントの他の取り込みセッションを閉じる。10.5）にだけ使います |
| `profile` | 文字列または null | 確定済みのプロファイル（列挙 `profile` の値）。準備の前（`reserved`）は null |
| `limits` | オブジェクト | `time_limit_seconds`（整数）。1 配信の時間上限（秒）。現在の設定（`time_limit_minutes` × 60）で、管理画面での変更は、進行中の配信にも反映されます（19 章） |

- 接続チケットを**1 回限りで消費**し、送出世代を 1 進めます。2 つの操作は、不可分です（同じチケットを同時に 2 回照合しても、片方だけが成功します）。
- 照合のたびに、配信レコードの期限を評価します（13.2）。期限切れなら、配信を終了して 409 を返します。
- 認可：`X-Relay-Secret`。冪等性：**冪等ではありません**（チケットを消費します）。同じチケットの 2 回目は、404（`ticket_invalid`）です。
- エラー：404 `ticket_invalid`、409 `broadcast_not_attachable`、422 `invalid_input`、401 `unauthorized`。
- 中継は、結果を、ブラウザへ次のように伝えます（ws-protocol.md）。成功は `accepted`。404 `ticket_invalid` は `fatal`（`invalid_ticket`）のうえ切断。409 `broadcast_not_attachable` は `fatal`（`broadcast_ended`）のうえ切断。到達できない・5xx は `fatal`（`internal_error`）のうえ切断します（ブラウザは、新しいチケットで再接続します）。

### `POST /internal/v1/broadcasts/:id/provision`

準備です。開始通知（`start`）の受信を契機に、取り込みセッションが取り込み先を保持していなければ、中継が呼びます（10.1。中継の再起動後の復帰でも呼びます）。

要求：

```json
{"epoch":1,"profile":"720p"}
```

応答 200：

```json
{"ingest":{"url":"rtmps://a.rtmps.youtube.com:443/live2","stream_key":"dummy-stream-key"},"watch_url":"https://www.youtube.com/watch?v=dummyVideoId","state":"awaiting_media"}
```

| 項目 | 型 | 内容 |
|---|---|---|
| `ingest` の `url` | 文字列 | 取り込み先。RTMPS（`rtmps://`）で、ホストが `rtmps_ingest.hosts`、ポートが 443（`rtmps_ingest.port`）。開発・テストの環境では、疑似の取り込み口（`dev_ingest`：ホスト `fake-ingest`・ポート 1935・`rtmps`）。アプリケーションは、返す前に検証します（10.1）。中継も、送出の前に検証します |
| `ingest` の `stream_key` | 文字列 | 配信キー。**この応答でのみ返します**。アプリケーションは保存せず（再接続で必要なときは YouTube から再取得します）、中継はメモリにのみ保持します。ログ・例外・DB へ出しません |
| `watch_url` | 文字列 | 視聴 URL |
| `state` | 文字列 | 準備のあとの配信レコードの状態。初回は `awaiting_media`。復帰での再要求では、現在の状態 |

- 要求の `epoch` は、最新の送出世代です。`profile` は、開始通知（`start`）の `profile`（列挙 `profile` の値）です。
- 許可される状態は、`reserved`（初回）と、`awaiting_media`・`confirming`・`live`・`interrupted`（再取得。中継の再起動後）です。終了済みは、409（`broadcast_ended`）です。
- 準備は、数十秒かかり得ます。配信レコードの「受理済み」の期限（受理から `deadlines.reserved_seconds` 秒）の内に完了しなければ、配信は終了します（開始タイムアウト）。中継は、準備を待つ間も、ブラウザとの接続（心拍・`ack`・`report`）を止めません。
- 認可：`X-Relay-Secret`。冪等性：**冪等です**。同じ配信の準備が再度要求されたら、保存済みの段を飛ばして続きから再開し、YouTube の資源を重複して作りません。
- エラー：409 `stale_epoch`、409 `broadcast_ended`、422 `prior_unsettled`、502 `prepare_failed`、409 `authorization_revoked`、409 `live_not_enabled`（2 章）。404 `not_found`、422 `invalid_input`、401 `unauthorized`。
- 中継は、失敗を次のようにブラウザへ伝えます。`stale_epoch` は `fatal`（`stale_epoch`）。それ以外の失敗は、`status`（`ended`・`end_reason`）に続けて `fatal`（`broadcast_ended`）を送り、切断します。

### `POST /internal/v1/broadcasts/:id/heartbeat`

心拍です。2 秒間隔（`relay.heartbeat_interval_seconds`）で、取り込みセッションがある間、中継が呼びます。

要求：

```json
{"epoch":3,"seq":42,"publishing":true,"out_kbps":4620,"sent_bytes_delta":1155000,"browser":{"backlog_ms":120,"dropped_video_frames":0,"target_kbps":4500,"state":"live","events":[]}}
```

| 項目 | 型 | 内容 |
|---|---|---|
| `epoch` | 整数 | 送出世代 |
| `seq` | 整数（1 以上） | 心拍の連番（取り込みセッションごと。最初の心拍が 1）。冪等性のために置きます（**仮置き**）。応答を得られなかった心拍は、同じ `seq`・同じ内容で再送します。次の心拍は、1 増やした `seq` と、新しい内容です |
| `publishing` | 真偽値 | RTMPS で送出中なら true |
| `out_kbps` | 整数（0 以上） | 中継の送出ビットレート（kbps） |
| `sent_bytes_delta` | 整数（0 以上） | 前回の心拍から、RTMPS へ送った量（バイト）。月次の送信転送量の積算に使います（8.3） |
| `browser` | オブジェクトまたは null | ブラウザの直近の状態報告（`report`）の内容。まだ 1 つも受けていなければ null |

`browser` の項目は、ws-protocol.md の `report` と同じです：`backlog_ms`・`dropped_video_frames`・`target_kbps`・`state`（`live`・`degraded`）・`events`（`kind` と、省略できる `detail` の配列。`kind` は列挙 `browser_event_kind` の値。`detail` は符号と数値のみ）。`events` は、前回の成功した心拍以降に、ブラウザから届いた出来事すべてです（欠落なく）。

応答 200：

```json
{"command":"continue","notices":[{"kind":"status","state":"live","watch_url":"https://www.youtube.com/watch?v=dummyVideoId","warning":null,"time_limit_notice_seconds":null,"end_reason":null}]}
```

| 項目 | 型 | 内容 |
|---|---|---|
| `command` | 文字列 | `continue`（継続）または `stop`（送出を止める） |
| `reason` | 文字列 | 送出世代が古いときだけ。`stale_epoch`（このときの応答は `{"command":"stop","reason":"stale_epoch"}` で、`notices` を持ちません） |
| `end_reason` | 文字列 | `stop` で、配信が終了しているとき。列挙 `end_reason` の値 |
| `notices` | 配列 | ブラウザへ伝える状態の通知。省略は空の配列と同じ |

`notices` の各要素は、`kind`（現在は `status` だけ）と、状態の全体（スナップショット）です：`state`（列挙 `broadcast_state` の値）・`watch_url`（文字列または null）・`warning`（`youtube_stream_unhealthy` または null）・`time_limit_notice_seconds`（整数または null）・`end_reason`（`state` が `ended` のときだけ、列挙 `end_reason` の値）。項目は、ws-protocol.md の `status` と同じです。中継は、各要素を、順に `status` としてブラウザへ転送します。

- 通知するもの：ライブへの遷移（`state` が `live`）、YouTube のストリームの健全性の警告（`warning`）、時間上限の予告（ライブ確定から 60 分の 5 分前に 1 回。`time_limit_notice_seconds` が 300）、配信の終了とその理由（`state` が `ended`）。
- `command` が `stop` で `end_reason` を持つとき（時間上限・管理者による停止・別の端末からの停止・YouTube 側の終了・接続喪失など）、中継は、送出を止め（送出待ちを送り切ってから RTMPS を切断し）、取り込みセッションを閉じます。ブラウザへは、`notices` の `status`（`ended`）と、`fatal`（`broadcast_ended`）を送ります。`notices` に終了の `status` が無ければ、中継が `end_reason` から作ります。
- 送出世代が古いとき、中継は、その接続への送出を止め、`fatal`（`stale_epoch`）のうえ閉じます。
- **中断（`interrupted`）の配信で、最新の送出世代から送出中（`publishing` が true）の心拍が届いたら、復帰（ライブ）として扱います**（13.2。アプリケーションの再起動や内部通信の不達で心拍が途絶えたあと、正常に送出を続けている配信を、制御面の都合で終了させない）。
- 心拍の応答が `relay.heartbeat_lost_stop_seconds` 秒（60 秒）得られない場合、中継は自ら送出を止めて取り込みセッションを閉じます（アプリケーションが不達の間も、60 秒以内は、メディアの転送を止めません）。
- 認可：`X-Relay-Secret`。冪等性：**`seq` で冪等です**。アプリケーションは、配信・世代ごとに、反映した最後の `seq` を持ちます。`seq` が、それ以下の心拍（再送）は、統計（`sent_bytes_delta`）・健全性の標本・出来事を再び反映せず、前回返した `notices` を、もう一度返します（`command` は、現在の状態で評価し直します）。応答を得られなかった `notices` を、再送で確実に渡すためです。
- アプリケーションは、心拍の受理のたびに、配信レコードの期限を評価します（13.2）。
- エラー：404 `not_found`、422 `invalid_input`、401 `unauthorized`。

### `POST /internal/v1/broadcasts/:id/events`

事象です。中継が観測した出来事を、発生時に通知します。

要求：

```json
{"epoch":3,"kind":"interrupted","at":"2026-10-07T13:30:12+09:00","detail":{"cause":"browser_disconnected"}}
```

| 項目 | 型 | 内容 |
|---|---|---|
| `epoch` | 整数 | 送出世代 |
| `kind` | 文字列 | 列挙 `relay_event_kind` の値（下の表） |
| `at` | 文字列 | 中継が出来事を観測した時刻（ISO 8601、JST）。**古い時刻のことがあります**（中継は、アプリケーションが停止している間、事象を保持して再送するため） |
| `detail` | オブジェクト | 省略できます。`cause`（列挙 `interrupt_cause` の値）だけを持ちます。`interrupted` では必須、`publish_failed` では、原因が `rtmps_disconnected` または `buffer_overflow` のときに付けます |

| `kind` | 意味 | アプリケーションの処理（25.1 の状態遷移による。当てはまらない状態では、何もしません） |
|---|---|---|
| `publish_started` | RTMPS の送出を開始した | 送出待ち → 確定待ち（ライブ確定の確認を始める） |
| `interrupted` | 中断した。原因は `browser_disconnected`（ブラウザとの切断）・`media_stalled`（映像または音声が 5 秒届かない）・`rtmps_disconnected`（RTMPS の切断）・`buffer_overflow`（送出待ちの上限に到達） | ライブ → 中断（期限は、中継の通知による 30 秒。`deadlines.interrupted_relay_notified_seconds`） |
| `resumed` | 復帰した（キーフレームの到着） | 中断 → ライブ（復帰の回数を数え、復帰時の確認を行う。心拍による復帰と、二重に数えません） |
| `publish_failed` | RTMPS の送出に失敗した（publish の直後の切断を含む） | 送出失敗として中断へ |
| `relay_disconnected` | 中継が、致命通知のうえ、ブラウザを切断した（受信ビットレートの超過） | 配信を終了する（終了理由 `relay_disconnect`） |
| `session_ended` | 取り込みセッションを終了した | 記録のみ |

応答 204（本文なし）。

- 認可：`X-Relay-Secret`。冪等性：**冪等です**。同じ出来事の重複で、結果が変わりません。古い送出世代の事象は、無視します（204 を返し、状態を変えません）。終了済みの配信への事象も、状態を変えず、204 です。
- アプリケーションは、`at` を信用して状態を巻き戻しません。現在の状態と送出世代に照らして、処理します。
- 中継は、事象を、発生順に 1 つずつ送り、204 を得てから次を送ります。アプリケーションへ到達できない間は、メモリのキュー（上限あり）に保持して、指数的な待機で再送します。404（`not_found`）を得た事象は、その配信のものを破棄します。
- エラー：404 `not_found`、422 `invalid_input`、401 `unauthorized`。

## 5. 呼び出しの一覧

| 呼び出し | 列挙 `internal_call` | 契機 | 冪等性 |
|---|---|---|---|
| `POST /internal/v1/verify` | `verify` | 接続通知（`hello`）の受信 | 冪等ではない（チケットを消費する） |
| `POST /internal/v1/broadcasts/:id/provision` | `provision` | 開始通知（`start`）の受信（取り込み先を保持していないとき） | 冪等 |
| `POST /internal/v1/broadcasts/:id/heartbeat` | `heartbeat` | 2 秒間隔 | `seq` で冪等 |
| `POST /internal/v1/broadcasts/:id/events` | `event` | 出来事の発生時 | 冪等 |

## 6. 配信の状態と内部通信

配信レコードの状態（25.1）と、内部通信の関係です。状態の遷移の規則そのものは、アプリケーションの Domain Core（#6）が持ちます。

| 状態 | 内部通信 |
|---|---|
| `reserved`（受理済み） | verify（受理から 90 秒以内）。provision |
| `awaiting_media`（送出待ち） | `publish_started` の事象（準備の完了から 30 秒以内） |
| `confirming`（確定待ち） | 心拍。ライブ確定の確認はアプリケーションが YouTube へ行い（5 秒間隔・120 秒以内）、確定したら、心拍の応答で `status`（`live`）を伝える |
| `live`（ライブ） | 心拍・`interrupted` の事象。時間上限（ライブ確定から 60 分）で、心拍の応答が `stop`（`time_limit`） |
| `interrupted`（中断） | `resumed` の事象、または送出中の心拍で、ライブへ戻る。期限内（30 秒または 75 秒）に戻らなければ終了（`connection_lost`） |
| `ended`（終了） | 心拍の応答が `stop`（`end_reason`）。事象は 204 |

## 7. 認可と所有権

- 内部通信は、アカウントのセッションを持ちません。認可は、`X-Relay-Secret` と、送出世代（`epoch`）と、配信の識別子の組で行います。
- アプリケーションは、`epoch` と `broadcast_id` の組を必ず検証し、他の配信の識別子で、別のアカウントの記録を更新できないようにします。
- 中継は、`account_key` で、同一アカウントを区別します。内部のアカウント識別子・Google の識別子は、中継へ渡しません。

## 8. 中継が保持するもの（参考）

中継は、状態を永続化しません（2.3）。取り込みセッションは、メモリに、配信の識別子・送出世代・`account_key`・プロファイル・配信キー・RTMPS の接続・送出待ちのバッファを持ちます。取り込みセッションの終了時に、配信キーとバッファを破棄し、メディアをファイルへ保存しません。

## 9. 仮置きと疑義

| 項目 | 置いた内容 | 理由 |
|---|---|---|
| 心拍の `seq` | 追加（必須・1 以上の連番）。同じ `seq` の再送には、前回の `notices` を返す | 設計メモに識別子が無く、「同じ心拍の再送で重複して記録しない」（#14）を実現できないため |
| `account_key` の形式 | 64 文字の小文字の 16 進数 | 設計メモは「不透明な値。HMAC」としか定めていない |
| provision の失敗の `details` | `end_reason` を載せる。`live_not_enabled` は `prepare_failed` | 10.6・#13。`live_not_enabled` は列挙 `end_reason` に無い |
| events の `publish_failed` の `detail` | 省略できる（`cause`） | 設計メモは `detail` の形だけ。`publish_failed` の原因は、送出待ちの上限と RTMPS の切断 |
| 未知の配信への events | 404（中継は、その配信の事象を破棄） | 永久に再送し続けて、キューを詰まらせないため |
| 到達できない照合 | `fatal`（`internal_error`）のうえ切断 | 設計メモに、照合不能のときの扱いが無い |
