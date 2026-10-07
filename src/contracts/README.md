# 契約（src/contracts）

3 層（フロントエンド・アプリケーション・中継）が互いに参照する取り決めを、先行して 1 か所に固定したものです。後続の実装は、これを**参照のみ**で実装します（型定義・API の契約は、先行する独立の issue とする方針）。

固めているのは、次の 6 つです。

1. 列挙値（requirements.md 20.4 のマスタデータ）
2. ブラウザ ⇄ アプリケーションの HTTP API
3. 中継 → アプリケーションの内部通信
4. ブラウザ ⇄ 中継の WebSocket バイナリフレーム
5. 制限値・間隔・閾値
6. 3 層で共有するテストベクタ

契約は、**文書**（この `src/contracts/`）と、各層が実行時に使う**定数モジュール**の両方で表します。デプロイ単位は層ごと（Vercel は `src/frontend`、Railway は `src/backend`・`src/relay`）なので、実行時のコードは `src/contracts/` を読みません。各層は定数モジュールを持ち、`src/contracts/` の JSON との一致を、**テスト**で保証します。

仕様の正は requirements.md です。契約は、それを実装できる粒度にしたもので、食い違いは requirements.md に従って、契約を直します。要件・設計メモに定めが無く、契約が置いた解釈には、「**仮置き**」の印を付け、各文書の末尾に一覧しています。

## ファイル

| ファイル | 内容 |
|---|---|
| `enums.json` | 24 の列挙の符号（20.4 の 17 区分と、契約独自の 7 区分）。配色の役割（`color_role`）は、17.2 の 16 進値を持ちます |
| `limits.json` | 制限値・間隔・閾値・固定値（プロファイル・回線計測・適応制御・WebSocket フレーム・中継・期限・割り当て台帳・RTMPS の許可・頻度・保持・設定の既定値） |
| `http-rejections.json` | 開始の受付の拒否理由 14 種ごとの、HTTP ステータス・区分（`resolution`）・再試行の目安時刻の規則 |
| `http-api.md` | HTTP API（ブラウザ → フロントエンド → アプリケーション）。共通の規約・全エンドポイントの要求と応答・エラーの種類・冪等性・認可 |
| `internal-api.md` | 内部通信 API（中継 → アプリケーション）。照合・準備・心拍・事象 |
| `ws-protocol.md` | WebSocket 転送プロトコル（ブラウザ ⇄ 中継）。フレーム構造・14 種のメッセージ・検証の順・順序 |
| `ws-frame-vectors.json` | フレームの共有テストベクタ。有効（14 種）・無効（7 種のエラー）を、16 進文字列と期待される復号結果・エラー符号で定義 |
| `test/*.test.mjs` | 契約のテスト（Node 22 の `node --test`。依存パッケージなし）。`scripts/test_contracts.sh` が実行します |

JSON の文書用のキー（`$comment`・`note`・`*_note`）は、説明のためのもので、定数モジュールへは複製しません。

## 規約

- 符号は、英小文字の snake_case です（プロファイルのみ `720p`・`480p`）。画面に出す文言を含みません（文言は、フロントエンドの文言カタログ）。
- 時刻は ISO 8601（JST、`+09:00`、秒まで）です。DB は UTC です。JSON のキーは snake_case で、単位は名前に含めます（`_kbps`・`_ms`・`_us`・`_seconds`・`_bytes`）。
- HTTP のエラーは `{"error":{"code":"<符号>","details":{…}}}`、受付の拒否は `{"rejected":{"reason":"<拒否理由>","resolution":"<区分>","retry_at":<時刻または null>}}` です。
- 他のアカウントのレコードは、存在しないものとして 404 を返します（存在を明かしません）。
- ヘッダ・Cookie（`X-BFF-Secret`・`X-BL-Client`・`X-CSRF-Token`・`X-Relay-Secret`・`bl_session`・`bl_oauth`）は、http-api.md の 1 章と internal-api.md の 1 章です。
- 配信キー・トークン・配信のタイトルは、契約のどの応答・ログ・測定イベントにも載せません。配信キーは、内部通信の準備の応答でだけ返し、中継のメモリにだけ置きます。

## 各層の定数モジュール

3 層とも、`enums.json` の全列挙と、`limits.json`・`http-rejections.json` の全項目を持ちます（文書用のキーを除く）。画面に出す文言を含みません（符号と数値だけ）。モジュールは、JSON と**両方向**で一致します（JSON にあるものがモジュールに無い、モジュールにあるものが JSON に無い、のどちらも失敗します）。

| 層 | 置き場 | 形 |
|---|---|---|
| アプリケーション（Ruby） | `src/backend/app/domain/contract/`（Zeitwerk の規則：パスと定数名が対応。`app/domain` が autoload のルート） | 列挙ごとに `Contract::<名前>`（例 `Contract::EndReason`）。値ごとの定数（`USER_STOP`）、凍結した配列 `ALL`、述語 `valid?(value)`（文字列の符号だけが真）。`Contract::ColorRole::HEX`・`ON_HEX`。`Contract::Limits::<セクション>`（`PROFILES`・`RELAY`・`QUOTA` など。JSON と同じ形の、深く凍結した Hash）。`Contract::HttpRejections` |
| フロントエンド（TypeScript） | `src/frontend/core/contract/`（テストは隣の `contract.test.ts`） | 列挙ごとに `as const` の配列 `<名前>_VALUES`（例 `END_REASON_VALUES`。凍結済み）、ユニオン型（`EndReason`）、型ガード（`isEndReason`）。`COLOR_ROLE_ATTRIBUTES`。制限値 `LIMITS`（JSON と同じ形。深く凍結済み。フレームの種別符号は `LIMITS.ws_frame.types`）。`HTTP_REJECTIONS`・`RETRY_AT_RULES`。`index.ts` がすべてを再エクスポートする |
| 中継（Go） | `src/relay/core/contract/`（package `contract`。テストは隣の `contract_test.go`） | 列挙ごとに型付きの文字列定数（例 `type EndReason string`、`EndReasonUserStop`）、値の一覧 `EndReasonValues()`（呼び出しのたびに新しいスライス）、`Valid()`。制限値の定数（例 `RelayHelloTimeoutSeconds`。配列は新しいスライスを返す関数）。プロファイルは `ProfileLimitsOf(profile)`。フレームの種別符号 `FrameType`（`FrameTypeHello` = `0x01` など。`Direction()`・`MessageType()`）。`HTTPRejectionOf(reason)`・`RetryAtRuleValues()` |

3 層のテストは、契約のディレクトリを、次の順に探します。**見つからなければ、探した場所を並べて失敗します（黙ってスキップしません）。**

1. `/contracts`（docker compose が、`src/contracts` を読み取り専用でマウントする場所）
2. `../contracts`（CI のチェックアウト。作業ディレクトリが `src/<層>` のとき、`src/contracts`）
3. `../../contracts`
4. テストのファイルの位置から、`src/contracts` へ上る相対パス（作業ディレクトリに依らない）

目印は、`enums.json` があることです。

## テストの実行

| 対象 | コマンド |
|---|---|
| 契約（JSON の構文・20.4 の件数・符号の重複・拒否理由 14 種の網羅・ベクタの自己整合・文書との整合） | `scripts/test_contracts.sh`（`frontend` のコンテナの Node 22 で、`/contracts/test/*.test.mjs` を実行） |
| アプリケーション（Ruby の定数モジュール） | `TEST_DB_NAME=bl_test_issue3 scripts/test_backend.sh --no-db spec/domain/contract` |
| フロントエンド（TypeScript の定数モジュール） | `scripts/test_frontend.sh core/contract` |
| 中継（Go の定数パッケージ） | `scripts/test_relay.sh ./core/contract/...` |

- Ruby のスペックは、Rails を起動せず、DB へ接続しません（`spec_helper` だけ）。Zeitwerk の規則（パスと定数名の対応）は、素の Zeitwerk のローダーで読み込んで検査します（`require_relative` で読み込むと、規則に反するファイルを見逃すため）。
- `scripts/test_contracts.sh` は、`node --test` のオプションを、そのまま渡せます（例：`scripts/test_contracts.sh --test-name-pattern 拒否理由`）。

## 契約を変えるとき

契約の変更は、すべての層に影響します。次をすべて、同じ変更でそろえます。

1. `enums.json`・`limits.json`・`http-rejections.json`・`ws-frame-vectors.json` を直す
2. 該当する文書（`http-api.md`・`internal-api.md`・`ws-protocol.md`・この README）を直す
3. 3 層の定数モジュールを直す（Ruby・TypeScript・Go）
4. `scripts/test_contracts.sh` と、3 層のテストを実行する

契約のテスト（`test/*.test.mjs`）には、設計メモ（issue #3）の表の写しがあります。値を意図して変えるときは、その写しも、意図して直します（テストが、不用意な変更を止めます）。

## 列挙の一覧（符号と、要件の用語）

20.4 の 17 区分と、契約独自の 7 区分です。符号の順は、契約の一部です。

### `source_kind`（ソース種別）

| 符号 | 用語 |
|---|---|
| `camera` | カメラ |
| `screen` | 画面共有 |
| `microphone` | マイク |
| `shared_audio` | 共有音声 |
| `slate` | 代替スレート |

### `layout`（レイアウト）

| 符号 | 用語 |
|---|---|
| `screen_with_wipe` | 画面共有＋ワイプ |
| `screen_only` | 画面共有のみ |
| `camera_only` | カメラのみ |
| `slate` | 代替スレート |

### `profile`（エンコードプロファイル）

| 符号 | 用語 |
|---|---|
| `720p` | 標準（720p） |
| `480p` | 軽量（480p） |

### `broadcast_state`（配信レコードの状態）

| 符号 | 用語 |
|---|---|
| `reserved` | 受理済み |
| `awaiting_media` | 送出待ち |
| `confirming` | 確定待ち |
| `live` | ライブ |
| `interrupted` | 中断 |
| `ended` | 終了 |

### `settlement_state`（清算状態）

| 符号 | 用語 |
|---|---|
| `none` | 不要 |
| `pending` | 未清算 |
| `settled` | 清算済み |
| `abandoned` | 清算不能 |

### `end_reason`（終了理由）

| 符号 | 用語 |
|---|---|
| `user_stop` | 利用者の停止 |
| `time_limit` | 時間上限 |
| `connection_lost` | 接続喪失 |
| `youtube_ended` | YouTube 側で終了 |
| `authorization_revoked` | 認可失効 |
| `admin_stop` | 管理者による停止 |
| `start_timeout` | 開始タイムアウト |
| `confirm_timeout` | 確定タイムアウト |
| `prepare_failed` | 準備の失敗 |
| `prior_unsettled` | 先行配信が未清算 |
| `insufficient_bandwidth` | 回線不足 |
| `user_cancel` | 利用者の取り消し |
| `relay_disconnect` | 中継による切断 |

### `rejection_reason`（開始の拒否理由。9.2 の順 0〜13）

| 符号 | 用語 |
|---|---|
| `invalid_input` | 入力不備 |
| `not_logged_in` | 未ログイン |
| `rate_limited` | 頻度超過 |
| `bot_check_failed` | bot 判定 |
| `broadcast_in_progress` | 進行中の配信あり |
| `youtube_not_connected` | YouTube 未接続 |
| `authorization_revoked` | 認可失効 |
| `live_not_enabled` | ライブ未有効 |
| `allowance_consumed` | 利用枠消費済み |
| `attempts_exhausted` | 試行上限 |
| `intake_paused` | 受付停止 |
| `transfer_budget_exceeded` | 転送量の予算超過 |
| `capacity_full` | 満員 |
| `quota_insufficient` | API 割り当て不足 |

### `youtube_connection_state`（YouTube 接続状態）

| 符号 | 用語 |
|---|---|
| `not_connected` | 未接続 |
| `connected` | 接続済み |
| `live_not_enabled` | ライブ未有効 |
| `revoked` | 認可失効 |

### `studio_state`（スタジオの状態）

| 符号 | 用語 |
|---|---|
| `idle` | 待機 |
| `requesting` | 受付中 |
| `connecting` | 接続中 |
| `probing` | 計測中 |
| `starting` | 開始中 |
| `live` | 配信中 |
| `degraded` | 劣化 |
| `reconnecting` | 再接続中 |
| `stopping` | 停止中 |
| `ended` | 終了 |

### `source_state`（ソースの状態）

| 符号 | 用語 |
|---|---|
| `detached` | 未取得 |
| `requesting` | 要求中 |
| `active` | 取得済み |
| `denied` | 拒否 |
| `lost` | 喪失 |

### `ws_message_type`（転送メッセージ種別。前の 7 種がブラウザ → 中継、後の 7 種が中継 → ブラウザ）

| 符号 | 用語 |
|---|---|
| `hello` | 接続通知 |
| `probe` | 計測データ |
| `start` | 開始通知 |
| `video` | 映像 |
| `audio` | 音声 |
| `report` | 状態報告 |
| `end` | 終了通知 |
| `accepted` | 接続受理 |
| `probe_result` | 計測結果 |
| `ack` | 受領応答 |
| `keyframe_request` | キーフレーム要求 |
| `throttle` | 抑制指示 |
| `status` | 状態通知 |
| `fatal` | 致命通知 |

種別符号と方向は、`limits.json` の `ws_frame.types` と、ws-protocol.md の 3 章です。

### `internal_call`（内部通信の呼び出し）

| 符号 | 用語 |
|---|---|
| `verify` | 照合 |
| `provision` | 準備 |
| `heartbeat` | 心拍 |
| `event` | 事象 |

### `broadcast_event_type`（配信の出来事の種別）

| 符号 | 用語 |
|---|---|
| `accepted` | 受理 |
| `verified` | 照合 |
| `probe_done` | 計測完了 |
| `provision_started` | 準備開始 |
| `provision_done` | 準備完了 |
| `publish_started` | 送出開始 |
| `live_confirmed` | ライブ確定 |
| `source_added` | ソース追加 |
| `source_lost` | ソース喪失 |
| `fallback_switched` | 代替切替 |
| `bitrate_down` | 引き下げ |
| `bitrate_up` | 引き上げ |
| `video_dropped` | 映像破棄 |
| `degraded_started` | 劣化開始 |
| `degraded_cleared` | 劣化解消 |
| `interrupted` | 中断 |
| `resumed` | 復帰 |
| `throttle_directed` | 抑制指示 |
| `keyframe_requested` | キーフレーム要求 |
| `youtube_warning` | YouTube 警告 |
| `time_limit_notice` | 時間上限の予告 |
| `ended` | 終了 |
| `settlement_succeeded` | 清算成功 |
| `settlement_failed` | 清算失敗 |

### `usage_event_type`（測定イベントの種別）

| 符号 | 用語 |
|---|---|
| `login_started` | ログイン開始 |
| `login_completed` | ログイン完了 |
| `connect_started` | 接続開始 |
| `connect_completed` | 接続完了 |
| `connect_failed` | 接続不成立 |
| `capability_detected` | 能力検出 |
| `source_granted` | ソース許可 |
| `source_denied` | ソース拒否 |
| `start_requested` | 開始要求 |
| `start_rejected` | 開始拒否 |
| `line_measured` | 回線計測 |
| `prepared` | 準備完了 |
| `live_confirmed` | ライブ確定 |
| `degraded` | 劣化 |
| `reconnect_started` | 再接続開始 |
| `reconnect_succeeded` | 再接続成功 |
| `broadcast_ended` | 配信終了 |
| `watch_url_copied` | 視聴 URL の複製 |
| `disconnected` | 接続解除 |
| `account_deleted` | アカウント削除 |

### `setting_key`（制限値・設定。8 章）

| 符号 | 用語 |
|---|---|
| `daily_allowance` | 日次利用枠 |
| `attempt_limit` | 開始試行上限 |
| `concurrent_limit` | 同時配信数 |
| `time_limit_minutes` | 1 配信の時間上限 |
| `intake_rate_per_hour` | 受付要求の頻度 |
| `monthly_transfer_budget_gb` | 月次の送信転送量の予算 |
| `daily_quota_units` | 1 日の割り当て |
| `bot_score_threshold` | bot 判定の閾値 |
| `intake_paused` | 受付停止 |

既定値は、`limits.json` の `setting_defaults` です。`bot_score_threshold` の既定値 0.5 は、仮置きです（CLAUDE.md の U4。requirements.md への追記は #5）。

### `adaptive_condition`（適応制御の条件。12 章の表の 7 行の順）

| 符号 | 用語 |
|---|---|
| `backlog_high_twice` | 滞留時間が 1.5 秒を超える評価が 2 回連続 → 目標ビットレートを 30% 引き下げる |
| `backlog_low_no_drop` | 滞留時間が 0.3 秒未満、かつ直近 10 秒に破棄がない → 10% 引き上げる |
| `backlog_critical` | 滞留時間が 4 秒を超える → 送信待ちの映像を全破棄し、キーフレームを発行する |
| `video_ack_stalled` | 映像の受領済み時刻が 10 秒間進まない → 再接続へ |
| `backlog_severe_sustained` | 滞留時間が 8 秒を超える状態が 10 秒継続 → 再接続へ |
| `degraded_enter` | 下限に達したうえで、滞留時間 1.5 秒超が 20 秒継続 → 劣化 |
| `degraded_exit` | 劣化の状態で、滞留時間 1.5 秒以下が 10 秒継続 → 劣化を解除 |

しきい値と継続時間は、`limits.json` の `adaptive.conditions` です。

### `color_role`（配色の役割。17.2）

| 符号 | 用語 |
|---|---|
| `base` | 基底（ページ背景） |
| `surface` | 面（パネル） |
| `surface_raised` | 面（浮き）（ダイアログ・入力欄） |
| `divider` | 区切り線 |
| `control_border` | 操作部品の枠 |
| `text_primary` | 文字（主） |
| `text_secondary` | 文字（従） |
| `accent` | アクセント（上に載せる文字の色を持つ） |
| `live` | ライブ（上に載せる文字の色を持つ） |
| `warning` | 警告 |
| `success` | 正常 |
| `focus` | フォーカス |

16 進値は、17.2 の値です。モックの配色（`app-ui/tokens/colors.css`）とは一致しません（差は、`enums.json` の `color_role` の注記）。

### `fatal_code`（致命通知の符号。契約独自）

| 符号 | 用語 |
|---|---|
| `message_too_large` | 1 メッセージが上限を超えた |
| `bitrate_exceeded` | 受信ビットレートが上限を超えた |
| `hello_timeout` | 接続通知の期限 |
| `invalid_ticket` | 接続チケットが無効 |
| `stale_epoch` | 新しい世代の接続に置き換えられた |
| `broadcast_ended` | 配信は終了済み |
| `protocol_violation` | プロトコル違反 |
| `heartbeat_lost` | 心拍の応答が得られず、中継が送出を止めた |
| `publish_failed` | RTMPS の送出を続けられない |
| `internal_error` | 中継の想定外の失敗 |

### `relay_event_kind`（中継の事象の種類。契約独自）

| 符号 | 用語 |
|---|---|
| `publish_started` | 送出開始 |
| `interrupted` | 中断 |
| `resumed` | 復帰 |
| `publish_failed` | 送出失敗 |
| `relay_disconnected` | 中継による切断 |
| `session_ended` | 終了 |

### `interrupt_cause`（中断の原因。契約独自）

| 符号 | 用語 |
|---|---|
| `browser_disconnected` | ブラウザとの WebSocket の切断 |
| `media_stalled` | 映像または音声のフレームが 5 秒届かない |
| `rtmps_disconnected` | RTMPS の切断 |
| `buffer_overflow` | 送出待ちのバッファの上限に到達 |

### `browser_event_kind`（ブラウザ側の出来事。状態報告に載せる。契約独自）

| 符号 | 用語 |
|---|---|
| `source_added` | ソースの追加 |
| `source_lost` | ソースの喪失 |
| `fallback_switched` | 代替への切替 |
| `bitrate_down` | 引き下げ |
| `bitrate_up` | 引き上げ |
| `video_dropped` | 映像の破棄 |
| `degraded_started` | 劣化の開始 |
| `degraded_cleared` | 劣化の解消 |

### `connect_result`（YouTube 接続の結果。契約独自）

| 符号 | 用語 |
|---|---|
| `connected` | 接続済み（チャンネルあり・ライブ有効） |
| `live_not_enabled` | ライブ未有効 |
| `scope_denied` | 権限の部分拒否 |
| `no_refresh_token` | 更新トークンの欠落 |
| `no_channel` | チャンネルなし |
| `unverifiable` | 確認不能 |

### `login_error`（ログインの失敗の種類。契約独自）

| 符号 | 用語 |
|---|---|
| `registration_held` | 再登録の保留中 |
| `oauth_failed` | 認可の不成立 |

### `resolution`（拒否の「再試行で解消するか」の区分。契約独自）

| 符号 | 用語 |
|---|---|
| `fix_input` | 修正後に可 |
| `log_in` | ログイン後に可 |
| `wait` | 時間を置いて可 |
| `stop_first` | 不可（先に停止） |
| `connect` | 接続後に可 |
| `reconnect` | 再接続後に可 |
| `enable_live` | 有効化後に可 |
| `next_usage_day` | 次の利用日に可 |
| `after_release` | 解除後に可 |
| `next_month` | 翌月に可 |
| `next_quota_day` | 次の割り当て日に可 |

## 仮置きと疑義

要件・設計メモに定めが無く、契約が置いた解釈は、各文書の末尾の表に、理由つきで一覧しています（http-api.md の 6 章、internal-api.md の 9 章、ws-protocol.md の 11 章）。主なものは次のとおりです。

- `bot_score_threshold` の既定値 0.5（`limits.json` の注記。CLAUDE.md の U4）
- RTMPS の許可ホスト `a.rtmps.youtube.com`・`b.rtmps.youtube.com`（公式に列挙が無い。最初の実機で確定する。`limits.json` の `rtmps_ingest` の注記）
- 心拍の `seq`（internal-api.md）。再送で、統計・出来事を二重に反映しないため
- 抑制指示（`throttle`）に解除のメッセージが無いこと（ws-protocol.md）
- 受信ビットレートの上限の基準（プロファイルの映像ビットレートの上限 × 1.5）
- 配信の確認のための、YouTube の `lifeCycleStatus` の列挙は、契約に含めません（アプリケーションの YouTube 連携の内部）
