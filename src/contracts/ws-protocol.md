# WebSocket 転送プロトコル（ブラウザ ⇄ 中継）

ブラウザと中継（Gin）の間の、WebSocket のバイナリ転送の契約です。実装は、フロントエンド（`src/frontend/core/transport`・`lib/studio`。#25・#28）と、中継（`src/relay/core/frame`・`internal/wsapi`。#18・#20・#21）が行います。要件の出どころは requirements.md の 11.9・11.10・12・13・28.1 です。

- 数値・符号・種別符号は、[limits.json](limits.json)（`ws_frame`・`relay`・`line_probe`・`profiles`・`video`・`audio`）と [enums.json](enums.json) が正です。この文書は、それらの意味と、組み合わせ方を説明します。数値は `limits.json` のキーを添えて書きます。
- フレームの符号化・復号は、[ws-frame-vectors.json](ws-frame-vectors.json)（共有テストベクタ）を、そのまま通してください（10 章）。
- 印の「**仮置き**」は、要件・設計メモに定めが無く、契約が置いた解釈です。理由を添え、11 章に一覧します。
- 括弧の中の「11.8」「13.3」のような番号は、requirements.md の節です。この文書の節への参照は、「5.3」「8 章」のように書きます（requirements.md の章は、「requirements.md の 12 章」と書きます）。

## 1. 接続

| 項目 | 内容 |
|---|---|
| URL | アプリケーションが、`relay_url` として返します（`POST /api/broadcasts` の 201、`POST /api/broadcasts/:id/ticket` の 200）。完全な `wss://…/ws` の URL です（開発環境は `ws://localhost:3002/ws`）。ブラウザは、これをそのまま `new WebSocket(url)` へ渡します |
| 認可 | Cookie に依存しません。接続の最初のメッセージ `hello` に、接続チケットを載せて認可します。中継は、接続元の Origin を検査しません（Cookie を使わず、チケットで認可するため） |
| メッセージ | バイナリのみです。1 メッセージ = 1 フレームです。テキストのメッセージを受けた中継は、`fatal`（`protocol_violation`）を送って切断します |
| バイト順 | ビッグエンディアンです |
| 大きさ | 1 メッセージ（ヘッダ + 本文）は、2,097,152 バイト（`ws_frame.max_message_bytes`）以下です |
| 接続通知の期限 | 接続から `relay.hello_timeout_seconds` 秒（10 秒）以内に `hello` が無い接続を、中継は `fatal`（`hello_timeout`）のうえ切断します |
| 同時の接続 | 1 つの配信につき、最新の送出世代の接続だけが送出できます。新しい世代の接続を照合すると、古い接続は直ちに閉じられます（`fatal`（`stale_epoch`）。internal-api.md の送出世代） |

## 2. フレーム構造

1 メッセージ = ヘッダ 17 バイト（`ws_frame.header_bytes`）+ 本文です。

| 位置 | 長さ（バイト） | 欄 | 内容 |
|---|---|---|---|
| 0 | 2 | 識別子 | `0x42 0x4C`（ASCII の `BL`。`ws_frame.magic`） |
| 2 | 1 | 版 | `1`（`ws_frame.version`） |
| 3 | 1 | 種別 | 3 章の種別符号 |
| 4 | 1 | 属性 | bit0 = キーフレーム（1 ならキーフレーム。`ws_frame.keyframe_attribute_bit`）。bit1〜bit7 は予約です。送信側は 0 にし、受信側は検査せず無視します（**仮置き**） |
| 5 | 8 | 時刻 | メディアクロックのマイクロ秒。符号なし 64 ビット。映像・音声だけが時刻を持ち、制御メッセージの時刻は 0 です |
| 13 | 4 | 本文長 | 本文のバイト数（文字数ではありません）。符号なし 32 ビット |
| 17 | 可変 | 本文 | 符号化データ、または制御内容 |

- 時刻は 2^53 を超え得る符号なし 64 ビットです。JavaScript では `BigInt`（または 2 つの 32 ビット）で扱い、`Number` へ変換しないでください（共有テストベクタに、2^53・2^53 + 1・2^64 − 1 の例があります）。
- JSON の本文の規則は、5.5 を参照してください。

## 3. メッセージ一覧

方向の B→R は「ブラウザ → 中継」、R→B は「中継 → ブラウザ」です。種別符号は、最上位ビットが方向を表します（0 = B→R、1 = R→B）。

| 種別 | 符号 | 方向 | 本文 | 送る契機 |
|---|---|---|---|---|
| `hello` | `0x01` | B→R | UTF-8 の接続チケット（JSON ではない、文字列そのもの） | 接続の直後。最初のメッセージ |
| `probe` | `0x02` | B→R | 任意のバイト列（回線計測用。1 メッセージ 32 KB 程度。`line_probe.message_bytes_hint`） | `accepted` を受けたあと、3 秒間（`line_probe.duration_seconds`）、最大 6,000 kbps（`line_probe.max_rate_kbps`）相当 |
| `start` | `0x03` | B→R | JSON（5.3） | プロファイルの選定とエンコーダの初期化のあと。復帰では、設定の再送 |
| `video` | `0x04` | B→R | AVCC 形式（4 バイト長さ前置）の NAL 列 | 開始時は `status`（`confirming`）を受けたあと、復帰時は `keyframe_request` を受けたあと |
| `audio` | `0x05` | B→R | AAC の生フレーム（ADTS なし） | `video` と同じ |
| `report` | `0x06` | B→R | JSON（5.6） | 1 秒間隔（`relay.report_interval_ms`） |
| `end` | `0x07` | B→R | JSON（5.7） | 利用者の停止・取り消し・回線不足 |
| `accepted` | `0x81` | R→B | JSON（5.8） | `hello` の照合の成功 |
| `probe_result` | `0x82` | R→B | JSON（5.9） | 最初の `probe` の受信から 3 秒後に、1 回 |
| `ack` | `0x83` | R→B | JSON（5.10） | 500 ms 間隔（`relay.ack_interval_ms`） |
| `keyframe_request` | `0x84` | R→B | 空（本文長 0） | 復帰の際。即時のキーフレームが要るとき |
| `throttle` | `0x85` | R→B | JSON（5.12） | 送出待ちが 1.5 秒分（`relay.egress_throttle_ms`）を超えているとき |
| `status` | `0x86` | R→B | JSON（5.13） | 配信レコードの状態の通知 |
| `fatal` | `0x87` | R→B | JSON（5.14） | 継続できないとき。送ったのち、中継が接続を閉じる |

## 4. 検証の順

受信側は、次の順に検証し、最初に該当した誤りを返します。受信側は、中継（B→R の種別だけを受理）と、ブラウザ（R→B の種別だけを受理）です。ベクタ（`ws-frame-vectors.json`）の `invalid` は、この順の例を含みます。

| 順 | エラー符号 | 条件 |
|---|---|---|
| 1 | `truncated_header` | 受け取ったバイト数が 17 に満たない（切り詰め） |
| 2 | `invalid_magic` | 識別子が `0x42 0x4C` でない |
| 3 | `unsupported_version` | 版が 1 でない |
| 4 | `unknown_type` | 種別符号が、3 章の 14 種のどれでもない |
| 5 | `wrong_direction` | 受信側が受理しない方向の種別（中継が R→B の種別を、ブラウザが B→R の種別を受けた） |
| 6 | `too_large` | 受け取ったバイト数、またはヘッダが宣言する大きさ（17 + 本文長）の、どちらかが 2,097,152 を超える。ヘッダの本文長の欄だけで、2 MB 超を表せます（**仮置き**：宣言の大きさでも判定する） |
| 7 | `length_mismatch` | 受け取った本文のバイト数が、ヘッダの本文長と一致しない（不足も超過も） |

- 判定の入力は、受け取ったバイト列そのものです。符号化データ・JSON の中身は見ません。
- 上限ちょうど（全体が 2,097,152 バイト）は `too_large` ではありません。本文長 2,097,135 のヘッダだけのベクタは、本文が足りないので `length_mismatch` です。

### 4.1 受信側の処置

| 受信側 | 誤り | 処置 |
|---|---|---|
| 中継 | `too_large` | `fatal`（`message_too_large`）を送り、Close コード 1009 で接続を閉じます。1 メッセージの大きさの上限は、読み取りの段階で（本文を読み切る前に）数えます |
| 中継 | `too_large` 以外の 6 種 | そのメッセージを破棄し、カウンタに数えます。接続は維持します（28.1：逸脱するメッセージは破棄する） |
| 中継 | `hello` の 2 回目、テキストのメッセージ | `fatal`（`protocol_violation`）を送って切断します |
| 中継 | `hello` の完了前に届いた、`hello` 以外のメッセージ | 破棄します |
| 中継 | 本文の JSON を解釈できない・必須の項目が無い・値が不正（列挙の値でない等） | 検証エラーのメッセージと同じく破棄します（**仮置き**） |
| 中継 | 同じ種別（映像・音声）で、時刻が逆行するメディア | 破棄します。前方への飛びは、復帰時の空白として許します |
| 中継 | 開始通知（`start`）の前、または送ってよい区間の前（5.4）に届いた `video`・`audio` | 破棄します |
| ブラウザ | 検証の誤り・本文の JSON の不備 | そのメッセージを破棄します（接続は維持します）。理由は記録にだけ残します |
| ブラウザ | WebSocket の Close コード 1009 | `fatal`（`message_too_large`）と同じ意味として扱います（ライブラリが超過時に、自動で Close コード 1009 を送るため） |

## 5. 本文

### 5.1 `hello`（B→R）

接続チケットです（アプリケーションが `POST /api/broadcasts` または `POST /api/broadcasts/:id/ticket` で返す、URL 安全な文字の文字列）。中継は、`POST /internal/v1/verify` で照合します。チケットは 1 回限りで、60 秒（`tickets.ttl_seconds`）で失効します。中継・ブラウザは、チケットをログへ出しません。

- 照合に成功すると、中継は `accepted` を返します。
- チケットが無効（未知・失効・使用済み）なら `fatal`（`invalid_ticket`）。配信が終了済み・状態が不適なら `fatal`（`broadcast_ended`）を送り、切断します。
- 照合のたびに、送出世代が 1 進みます。同じ配信の古い世代の接続は、`fatal`（`stale_epoch`）のうえ閉じられます。同一アカウントの他の配信の取り込みセッションも、すべて閉じられます（10.5）。

### 5.2 `probe`（B→R）と `probe_result`（R→B）

- ブラウザは、`accepted` を受けたあと、3 秒間、最大 6,000 kbps 相当で `probe` を送ります。終端の印はありません（送り終えたあと、`probe_result` を待つだけです）。
- 中継は、**最初の `probe` を受けてから 3 秒後に、その間に受けた `probe` の量から、`probe_result` を 1 回だけ**返します。`probe` を 1 つも受けていなければ、3 秒を数え始めないので、`probe_result` は返りません。
- `throughput_kbps` = その 3 秒間に受けた `probe` メッセージ全体（ヘッダを含む）のバイト数の合計 × 8 ÷ 3,000 を、切り捨てた整数です（1 kbps = 1,000 bit/s）（**仮置き**：要件は「受領量から」としか定めていない）。
- ブラウザは、結果から、プロファイルを選びます（11.8）。`profiles` の `line_threshold_kbps` 以上のうち、最も大きいプロファイル（720p は 4,100 kbps 以上、480p は 1,200 kbps 以上）。どちらも満たさなければ回線不足です（5.7 の `end` と、`POST /api/broadcasts/:id/cancel` の `insufficient_bandwidth`）。映像ビットレートの開始値は、`min(初期値, throughput_kbps × line_probe.start_bitrate_throughput_ratio)` で、下限（`video_bitrate_min_kbps`）を下回りません。
- 結果が来ない場合（3 秒 + 猶予）は、ブラウザがタイムアウトのエラーとして扱います（黙ってプロファイルを決めません）。

### 5.3 `start`（B→R）

JSON です。プロファイルと、映像・音声の設定を伝えます。中継は、映像設定・音声設定と、準備の結果（取り込み先）がそろうまで、RTMPS の publish を開始しません。

| 項目 | 型 | 内容 |
|---|---|---|
| `profile` | 文字列 | 列挙 `profile` の値（`720p`・`480p`）。復帰では、確定済みのプロファイル |
| `video` | オブジェクト | 下の表 |
| `audio` | オブジェクト | 下の表 |

`start` の `video`：

| 項目 | 型 | 内容 |
|---|---|---|
| `codec` | 文字列 | `video.codec_main`（`avc1.4D401F`。H.264 Main・Level 3.1）、または `video.codec_constrained_baseline`（`avc1.42E01F`。Main が使えない環境。11.7） |
| `width`・`height`・`framerate` | 整数 | プロファイルの値（`profiles` の `width`・`height`・`framerate`） |
| `bitrate_kbps` | 整数 | 映像ビットレートの開始値（5.2）。プロファイルの下限〜上限の範囲 |
| `description_b64` | 文字列 | 復号器設定（AVCDecoderConfigurationRecord）の base64（標準の文字集合・パディングあり） |

`start` の `audio`：

| 項目 | 型 | 内容 |
|---|---|---|
| `codec` | 文字列 | `audio.codec`（`mp4a.40.2`。AAC-LC） |
| `sample_rate` | 整数 | `audio.sample_rate_hz`（44100） |
| `channels` | 整数 | `audio.channels`（2） |
| `bitrate_kbps` | 整数 | `audio.bitrate_kbps`（128） |
| `description_b64` | 文字列 | 復号器設定（AudioSpecificConfig。AAC-LC・44.1 kHz・2 ch は `0x12 0x10`）の base64 |

```json
{"profile":"720p","video":{"codec":"avc1.4D401F","width":1280,"height":720,"framerate":30,"bitrate_kbps":4500,"description_b64":"AU1AH//hAA9nTUAfllQFAe2AoEA8IhEBAARo7jyA"},"audio":{"codec":"mp4a.40.2","sample_rate":44100,"channels":2,"bitrate_kbps":128,"description_b64":"EhA="}}
```

- 復号器設定は、最初のメディアフレームより前に届きます（`start` が先です）。再接続（復帰）でも、同じ内容を再送します。
- 中継は、設定を受けたあと、取り込み先を保持していなければ、準備（`POST /internal/v1/broadcasts/:id/provision`）を呼びます。

### 5.4 `video`・`audio`（B→R）

- 本文は、符号化データそのままです。中継は、中身を解釈・加工せず（再エンコードしません）、FLV のタグへ詰め替えるだけです。長さの検査だけを行います。
- `video`：AVCC 形式（各 NAL の前に、4 バイトのビッグエンディアンの長さ）。開始コード（`00 00 00 01`）は使いません。SPS・PPS は、`start` の `description_b64` で伝わるので、フレームには含めません。キーフレームは、属性の bit0 = 1 です。
- `audio`：AAC の生フレーム。ADTS ヘッダを付けません。
- 時刻（6 章）は、`video` が フレーム番号 × 1,000,000 ÷ 30、`audio` が 累積サンプル数 × 1,000,000 ÷ 44,100 です。
- **送ってよい区間**：開始時は、`status`（`state` が `confirming`）を受けたあと。復帰時は、`keyframe_request` を受けたあと（キーフレームから）。それ以前に届いた映像・音声を、中継は破棄します。
- 映像を 1 枚でも破棄したら、次のキーフレームまでの映像をすべて破棄します（ブラウザ側。requirements.md の 12 章）。音声は破棄しません。

### 5.5 JSON の本文の共通の規則

- 本文は UTF-8 の JSON のオブジェクトです（`hello` を除く）。本文長は、エンコードしたバイト数です（日本語は 1 文字が 3 バイト）。
- 受信側は、未知のキーを無視します（前方互換）。`x_` で始まるキーは、検査のための拡張で、同じく無視します。キーの順・空白は問いません。
- 時刻・期間・大きさの項目は、名前に単位を含みます（`_kbps`・`_ms`・`_us`・`_seconds`）。値は整数です（`throughput_kbps` なども切り捨てた整数）。
- 符号（列挙の値）は、enums.json の値と一致する文字列です。画面に出す文言を含めません。

### 5.6 `report`（B→R）

1 秒間隔（`relay.report_interval_ms`）の状態報告です。

| 項目 | 型 | 内容 |
|---|---|---|
| `backlog_ms` | 整数（0 以上） | 滞留時間（ミリ秒） |
| `dropped_video_frames` | 整数（0 以上） | 破棄した映像フレームの累計（配信の開始から。ページの再読み込みのあとの復帰では 0 から数え直します）（**仮置き**） |
| `target_kbps` | 整数 | 現在の目標ビットレート（映像。kbps） |
| `state` | 文字列 | `live` または `degraded`（列挙 `studio_state` の値のうち、配信中の 2 つ） |
| `events` | 配列 | ブラウザ側の出来事。前回の `report` 以降に起きたものを、1 回ずつ（欠落なく、重複なく）載せます |

`events` の各要素は、`kind`（列挙 `browser_event_kind` の値：`source_added`・`source_lost`・`fallback_switched`・`bitrate_down`・`bitrate_up`・`video_dropped`・`degraded_started`・`degraded_cleared`）と、省略できる `detail` を持ちます。

- `detail` は、**符号と数値のみ**です。オブジェクトで、キーは `^[a-z][a-z0-9_]{0,31}$`、値は整数、または `^[a-z0-9_]{1,32}$` の文字列、組は最大 4 つです。自由記述の文字列・ソースのデバイス名・ラベル・入れ子・配列・null を載せません（**仮置き**：要件は「符号と数値のみ」としか定めていない）。
- 推奨するキー（**仮置き**）：`source_added`・`source_lost` は `{"source": <列挙 source_kind の値>}`、`fallback_switched` は `{"layout": <列挙 layout の値>}`、`bitrate_down`・`bitrate_up` は `{"from_kbps": 整数, "to_kbps": 整数}`、`video_dropped` は `{"frames": 整数}`、`degraded_started`・`degraded_cleared` は `detail` なし。受け取る側は、この形に当てはまらない `detail`（形式に合う未知のキー）を拒否しません。

```json
{"backlog_ms":1800,"dropped_video_frames":12,"target_kbps":3000,"state":"degraded","events":[{"kind":"bitrate_down","detail":{"from_kbps":3300,"to_kbps":3000}},{"kind":"video_dropped","detail":{"frames":12}},{"kind":"degraded_started"}]}
```

中継は、直近の値を保持し、アプリケーションへの心拍（internal-api.md）に載せます。`events` は欠落なくキューへ積み、心拍が成功するまで保持して再送します。

### 5.7 `end`（B→R）

| 項目 | 型 | 内容 |
|---|---|---|
| `reason` | 文字列 | `user_stop`（利用者の停止）・`user_cancel`（利用者の取り消し）・`insufficient_bandwidth`（回線不足）。列挙 `end_reason` の値のうち、ブラウザが伝えられる 3 つ |

- 中継は、送出待ちを送り切ってから RTMPS を切断し、事象 `session_ended` を送り、配信キーとバッファを破棄します。応答はありません。
- 利用者の停止では、ブラウザは `end` を送るのと同時に、`POST /api/broadcasts/:id/stop` を呼びます（13.3）。ライブ確定前の取り消しは、`end`（`user_cancel`）と `POST /api/broadcasts/:id/cancel` です。回線不足は、`end`（`insufficient_bandwidth`）と `POST /api/broadcasts/:id/cancel`（`insufficient_bandwidth`）です。

### 5.8 `accepted`（R→B）

| 項目 | 型 | 内容 |
|---|---|---|
| `state` | 文字列 | 照合したときの配信レコードの状態（列挙 `broadcast_state` の値） |
| `resume` | 真偽値 | 再開（復帰）なら true。状態が `reserved` 以外のとき true です |
| `profile` | 文字列または null | 再開のとき、確定済みのプロファイル。初回は null |
| `limits` | オブジェクト | `time_limit_seconds`（整数）。1 配信の時間上限（秒） |

```json
{"state":"reserved","resume":false,"profile":null,"limits":{"time_limit_seconds":3600}}
```

`resume` が true のとき、ブラウザは、回線計測とプロファイルの選定をせず、`profile` で `start` を再送します。

### 5.9 `probe_result`（R→B）

`throughput_kbps`（整数。5.2）です。

```json
{"throughput_kbps":5200}
```

### 5.10 `ack`（R→B）

| 項目 | 型 | 内容 |
|---|---|---|
| `video_us` | 整数 | 中継が受領済みの、映像の最新のメディア時刻（マイクロ秒） |
| `audio_us` | 整数 | 同じく、音声の最新のメディア時刻 |

- 500 ms 間隔（`relay.ack_interval_ms`）で返します。
- 値は、ブラウザが付けたメディア時刻（受信した最大の時刻）です。RTMPS へ送るときに再基準化した時刻ではありません。まだ 1 つも受けていない種別は 0 です。同じ配信の中で、減りません（復帰をまたいでも、直前の値を保ちます）（**仮置き**）。
- ブラウザは、滞留時間を、**送信済みの最新メディア時刻 − 受領済みの最新メディア時刻（映像・音声のうち古い方）** で算出します（requirements.md の 4 章の用語「滞留時間」）。

### 5.11 `keyframe_request`（R→B）

本文は空（本文長 0）です。ブラウザは、直ちにキーフレームを発行し、そこから映像・音声を送ります。復帰では、これを受けるまで、映像・音声を送りません。中継は、キーフレームの到着をもって復帰とします。

### 5.12 `throttle`（R→B）

| 項目 | 型 | 内容 |
|---|---|---|
| `target_kbps` | 整数（正） | 目標ビットレート（映像。kbps） |

```json
{"target_kbps":3150}
```

- 中継は、送出待ちが 1.5 秒分（`relay.egress_throttle_ms`）を超えている間、**1 秒に 1 回まで**送ります。値は、報告された現在の目標から導き（仕様に数値の定めが無いため、中継 #18 が解釈します）、プロファイルの下限を下回りません。
- ブラウザは、中継の指示を、自分の判定より優先します（requirements.md の 12 章）。受けたら、目標ビットレートを `min(現在の目標, target_kbps)` に（プロファイルの下限〜上限の範囲で）直ちに下げます。以後の引き上げは、通常の評価（滞留 0.3 秒未満かつ直近 10 秒に破棄なし）に従います。解除を伝えるメッセージは、ありません（**仮置き**：要件は「抑制指示は優先する」としか定めていない）。

### 5.13 `status`（R→B）

配信レコードの状態の通知です。**毎回、状態の全体（スナップショット）**を載せます。

| 項目 | 型 | 内容 |
|---|---|---|
| `state` | 文字列 | 列挙 `broadcast_state` の値 |
| `watch_url` | 文字列または null | 視聴 URL。準備の完了後は、以降のすべての `status` に載せます。それまでは null です |
| `warning` | 文字列または null | `youtube_stream_unhealthy`（YouTube のストリームの健全性に問題がある）または null（警告なし）。現在の値です |
| `time_limit_notice_seconds` | 整数または null | 時間上限の予告。予告を伝える `status` だけが、残り秒数（300）を持ち、それ以外は null です |
| `end_reason` | 文字列または null | `state` が `ended` のときだけ、列挙 `end_reason` の値。それ以外は null です |

```json
{"state":"live","watch_url":"https://www.youtube.com/watch?v=dummyVideoId","warning":null,"time_limit_notice_seconds":300,"end_reason":null}
```

- 中継が自ら送るもの：準備の完了（`awaiting_media`。`watch_url` を載せる）、RTMPS の送出の開始（`confirming`）、準備の失敗で配信が終了したとき（`ended`・`end_reason`）。
- アプリケーションが、心拍の応答（`notices`）で伝え、中継が転送するもの：ライブへの遷移（`live`）・警告・時間上限の予告・終了とその理由。
- `status` は、`watch_url` が null のときも null として受け取ります。ブラウザは、すでに持っている視聴 URL を、null で上書きしません（**仮置き**：念のための規則。中継は準備の完了後、常に載せます）。
- 状態が `confirming` の `status` を受けたあと、ブラウザは映像・音声を送ります。

### 5.14 `fatal`（R→B）

| 項目 | 型 | 内容 |
|---|---|---|
| `code` | 文字列 | 列挙 `fatal_code` の値（8 章） |

```json
{"code":"message_too_large"}
```

## 6. 時刻とメディアクロック

- メディアクロックは、**音声の累積サンプル数**です。実時計（`Date.now()` など）から採番しません。時刻は累積値から毎回算出し、差分を積み上げません（丸め誤差を積まないため）。
- `video` の時刻 = round(フレーム番号 × 1,000,000 ÷ 30)。映像 1 フレームは、音声 1,470 サンプル（`audio.samples_per_video_frame`）に対応します。例：フレーム 1 = 33,333、フレーム 2 = 66,667、フレーム 30 = 1,000,000。
- `audio` の時刻 = round(累積サンプル数 × 1,000,000 ÷ 44,100)。例：1,024 サンプル = 23,220、441,000 サンプル = 10,000,000。
- 丸めは四捨五入です（これらの式で、ちょうど 0.5 になることはありません）。整数での算出は、`(2 × n × 1,000,000 + d) ÷ (2 × d)` の切り捨て（n は番号またはサンプル数、d は 30 または 44,100）です。
- 映像と音声の時刻は、同じ基準（配信の開始時のクロック）から付けます。復帰（再接続）をまたいでも、クロックは続きます。中継が、RTMPS の接続ごとに時刻を 0 起点へ再基準化し、復帰時は欠落を詰めます（11.10。ブラウザは関与しません）。
- キーフレーム間隔は 2 秒（`video.keyframe_interval_seconds`）です。

## 7. 順序

### 7.1 開始

1. ブラウザが `POST /api/broadcasts` を呼び、201 で接続チケットと `relay_url` を受け取る（http-api.md）。
2. ブラウザ → 中継：`hello`。
3. 中継 → アプリケーション：照合（`POST /internal/v1/verify`）。中継 → ブラウザ：`accepted`（`state` は `reserved`、`resume` は false、`profile` は null）。
4. ブラウザ → 中継：`probe`（3 秒）。中継 → ブラウザ：`probe_result`。
5. ブラウザが、プロファイルを選ぶ。回線不足なら、`POST /api/broadcasts/:id/cancel`（`insufficient_bandwidth`）と `end`（`insufficient_bandwidth`）で終了し、`start` を送らない（YouTube の資源は作られません）。
6. ブラウザがエンコーダを初期化し、ブラウザ → 中継：`start`。
7. 中継 → アプリケーション：準備（`POST /internal/v1/broadcasts/:id/provision`）。成功したら、中継 → ブラウザ：`status`（`awaiting_media`・`watch_url`）。
8. 中継が、取り込み先へ RTMPS で接続し、publish する。事象 `publish_started` をアプリケーションへ送り、中継 → ブラウザ：`status`（`confirming`）。
9. ブラウザ → 中継：`video`・`audio`（`status`（`confirming`）を受けたあとだけ）。
10. アプリケーションが、YouTube でライブになったことを確認し（5 秒間隔・最長 120 秒）、心拍の応答で `status`（`live`）を伝える。中継 → ブラウザ：`status`（`live`）。

準備が失敗して配信が終了したとき、中継は `status`（`ended`・`end_reason`）に続けて `fatal`（`broadcast_ended`）を送り、切断します。

### 7.2 復帰

1. ブラウザが、`POST /api/broadcasts/:id/ticket` で、新しい接続チケットを受け取る（状態が `awaiting_media`・`confirming`・`live`・`interrupted` のいずれかで、期限内のとき）。
2. ブラウザ → 中継：`hello`。照合で送出世代が進み、古い接続は閉じられる。
3. 中継 → ブラウザ：`accepted`（`resume` は true、確定済みの `profile`）。
4. ブラウザ → 中継：`start`（設定の再送。プロファイルは確定済みのもの）。
5. 中継は、取り込みセッションが取り込み先を保持していなければ（中継の再起動後）、準備を呼ぶ。
6. 中継 → ブラウザ：`keyframe_request`。
7. ブラウザ → 中継：キーフレームから `video`、あわせて `audio`。中継は、キーフレームの到着をもって復帰とし、事象 `resumed` を送る。
8. アプリケーションが、復帰時の確認を行い、ライブへ戻したら、心拍の応答で `status`（`live`）を伝える。

再接続の待機は、指数的に増やし、上限 5 秒です（`deadlines.reconnect_backoff_cap_ms`）。復帰は 1 配信あたり 10 回までです（`deadlines.max_resumes`）。再接続の間、ブラウザは、合成とエンコードを続けたまま、符号化結果を捨てます（requirements.md の 12 章）。

### 7.3 停止・取り消し

5.7 を参照してください。

### 7.4 中継が切断するとき

`fatal` を送ったのち、中継が接続を閉じます。Close コードは、`message_too_large` のとき 1009、それ以外は 1000 です（**仮置き**）。ブラウザは、Close コードに関わらず、直前の `fatal` の `code` を採用します。`fatal` が無い切断は、通信の中断として扱い、復帰（7.2）を試みます。

## 8. 致命通知（`fatal`）の符号

| 符号 | 意味 | 送る契機 | ブラウザの扱い |
|---|---|---|---|
| `message_too_large` | 1 メッセージが上限を超えた | 受信したメッセージが 2,097,152 バイトを超えた | 終了として表示します。再接続しても同じなので、送り方を直します |
| `bitrate_exceeded` | 受信ビットレートが上限を超えた | 10 秒平均が、プロファイルの映像ビットレートの上限 × 1.5 を超えた（`relay.ingress_bitrate_limit_factor`。計測中は 720p の上限） | 配信は終了します（終了理由は `relay_disconnect`）。この配信への再接続は受け付けません |
| `hello_timeout` | 接続通知の期限 | 接続から 10 秒以内に `hello` が無い | 接続し直します |
| `invalid_ticket` | 接続チケットが無効 | 照合が `ticket_invalid` | 新しいチケットを取得し直します（取得できなければ終了） |
| `stale_epoch` | 新しい世代の接続に置き換えられた | 同じ配信の新しい世代を照合した、または心拍の応答が `stale_epoch` | 再接続しません（新しい世代の接続があるため） |
| `broadcast_ended` | 配信は終了済み、または接続できない状態 | 照合が `broadcast_not_attachable`、準備の失敗で配信が終了、心拍の応答が停止の指示 | 終了として表示します（直前の `status` の `end_reason`） |
| `protocol_violation` | プロトコル違反 | `hello` の 2 回目、テキストのメッセージ | 終了として表示します |
| `heartbeat_lost` | 心拍の応答が 60 秒得られず、中継が自ら送出を止めた | 心拍の応答が `relay.heartbeat_lost_stop_seconds` 秒（60 秒）得られない | 復帰（7.2）を試みます |
| `publish_failed` | RTMPS の送出を続けられない | 中断の期限内に、RTMPS の接続・publish を確立できず、中継が取り込みセッションを閉じる（**仮置き**） | 復帰（7.2）を試みます |
| `internal_error` | 中継の想定外の失敗 | 中継の内部の例外 | 復帰（7.2）を試みます |

## 9. 中継の受信の制限

| 制限 | 値 | 超えたとき |
|---|---|---|
| 接続通知の期限 | `relay.hello_timeout_seconds`（10 秒） | `fatal`（`hello_timeout`）のうえ切断 |
| 1 メッセージの大きさ | `ws_frame.max_message_bytes`（2,097,152 バイト） | `fatal`（`message_too_large`）のうえ切断（Close コード 1009） |
| 受信ビットレート | プロファイルの映像ビットレートの上限 × `relay.ingress_bitrate_limit_factor`（1.5）の、`relay.ingress_bitrate_window_seconds`（10 秒）平均。計測中は `relay.ingress_bitrate_limit_probe_profile`（720p）の上限（**仮置き**：「プロファイルの上限」を、映像ビットレートの上限と解釈。#18 の本文は音声を加えた値） | `fatal`（`bitrate_exceeded`）のうえ切断。配信を終了し（`relay_disconnect`）、再接続を受け付けない |
| フレームの途絶 | `relay.media_stall_seconds`（5 秒）。映像または音声が届かない | 中断（事象 `interrupted`、原因 `media_stalled`） |
| 送出待ちのバッファ | 上限 `relay.egress_buffer_limit_ms`（3,000 ms）。`relay.egress_throttle_ms`（1,500 ms）を超えたら、抑制指示 | 上限に達したら送出失敗（事象 `publish_failed`、原因 `buffer_overflow`）。バッファを破棄して RTMPS を再接続 |
| 心拍の応答 | 間隔 `relay.heartbeat_interval_seconds`（2 秒）。`relay.heartbeat_lost_stop_seconds`（60 秒）得られなければ | 中継が自ら送出を止めて、取り込みセッションを閉じる（`fatal`（`heartbeat_lost`）） |

## 10. 共有テストベクタ（`ws-frame-vectors.json`）

フロントエンド（#25）と中継（#18）のコーデックは、このベクタをそのまま通します。ファイルは、`/contracts`（docker compose のマウント）、`../contracts`・`../../contracts`（CI のチェックアウト）の順に探し、見つからなければ失敗します（黙ってスキップしません）。

| キー | 内容 |
|---|---|
| `valid` | 有効なフレーム。`name`・`direction`・`hex`（フレーム全体の 16 進文字列）・`decoded`（`type`・`type_code`・`keyframe`・`timestamp_us`・`body_hex`）。任意の `note`・`body_text`（本文を UTF-8 で読んだ内容。読みやすさのための写し）・`decode_only` |
| `invalid` | 無効なフレーム。`name`・`receivers`・`hex`・`error`。任意の `note` |

- `timestamp_us` は、10 進数の**文字列**です（JSON の数値は、2^53 を超えると JavaScript で厳密に表せないため）。
- `valid` の各フレームは、`direction` の受信側が、`decoded` のとおりに復号できます。**反対側の受信側は、`wrong_direction` で拒否します**（ベクタには別に書きません）。
- エンコーダ（ブラウザの B→R の 7 種、中継の R→B の 7 種）は、`decoded` の欄から作ったフレームが、`hex` と一致することを確かめます。`decode_only` が true のもの（属性の予約ビットを立てた例）は、復号だけを検査し、エンコーダは作りません。
- `invalid` の各フレームは、`receivers` に挙げた受信側が、`error` で拒否します。方向に依存する誤り（`too_large`・`length_mismatch`・`wrong_direction`）は、受信側が受理する方向の種別を使った例を、受信側ごとに持ちます。
- 2 MB 超は、本文を付けず、ヘッダの本文長の欄だけで表します（ヘッダ 17 バイト）。
- 名前が `precedence_` で始まる例は、複数の誤りを持つフレームが、4 章の順の先の誤りで拒否されることを示します。
- 日本語を含む JSON の本文の例（`report_with_multibyte_text`）は、本文長が文字数ではなくバイト数であることの検査です。実際の通信は ASCII だけで、`x_` で始まる未知のキーは、受信側が無視します。

## 11. 仮置きと疑義

| 項目 | 置いた内容 | 理由 |
|---|---|---|
| 属性の予約ビット | 送信側は 0、受信側は無視 | 7 種のエラー符号に、予約ビットの違反が無いため |
| `too_large` の判定 | 受け取ったバイト数と、ヘッダの宣言（17 + 本文長）の、どちらかが上限を超えたら | 2 MB 超を、巨大な本文なしのベクタで表すため（受け入れ条件） |
| `too_large` 以外の検証エラー | 破棄して接続を維持 | 28.1「逸脱するメッセージは破棄する」。設計メモは、切断を `too_large` と `hello` の 2 回目に限る |
| 本文の JSON の不備 | 破棄 | 同上 |
| `throughput_kbps` の算出 | 3 秒間に受けた `probe` メッセージ全体のバイト数 × 8 ÷ 3,000（切り捨て） | 要件は「受領量から」としか定めていない |
| `dropped_video_frames` | 配信の開始からの累計 | 18.1「配信あたりの破棄フレーム数」を、最新の値で得られるようにするため |
| `ack` の値 | 受信した最大のメディア時刻。未受信は 0。減らない | 滞留時間の算出（4 章）に、再基準化前の時刻が要るため |
| `throttle` の解除 | 解除のメッセージは無い。通常の評価で戻る | 設計メモに、解除のメッセージが無い（#25 の本文の「解除されるまで」と整合しない点を、疑義として報告） |
| `status` の規則 | 常に全体のスナップショット。`time_limit_notice_seconds` だけが、予告のときのみ | アプリケーション・中継・ブラウザで、null の意味を一致させるため |
| `detail` の形式 | 符号と数値のみ。キーと値の形式を限る | 要件は「符号と数値のみ」としか定めていない（PII・自由記述の混入を防ぐ） |
| 受信ビットレートの基準 | プロファイルの映像ビットレートの上限 × 1.5 | 設計メモの「プロファイル上限 × 1.5」に従う。#18 の本文は「映像上限 + 音声」の 1.5 倍で、差は 2%。どちらも誤検知に十分な余裕がある |
| Close コード | `fatal` のあとは 1000（`message_too_large` は 1009） | #21 が 1009 を要求する。それ以外は定めが無い |
| `publish_failed` の意味 | 中断の期限内に RTMPS を確立できず、中継が閉じる | 設計メモに、符号の契機が無い |
| 開始通知の映像のコーデックに使う Constrained Baseline | `video.codec_constrained_baseline`（`avc1.42E01F`）を追加 | 11.7 の代替。設計メモに文字列が無い |
