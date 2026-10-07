# HTTP API（ブラウザ → フロントエンド → アプリケーション）

ブラウザが呼ぶ HTTP API の契約です。実装は、アプリケーション側（`src/backend`。#7・#8・#11・#12・#16）と、フロントエンド側（同一オリジン中継と API クライアント `src/frontend/lib/api`。#23）が行います。要件の出どころは requirements.md の 6.1・7・8・9・10・13・14・28 です。

- 符号は [enums.json](enums.json)、数値は [limits.json](limits.json)、受付の拒否理由は [http-rejections.json](http-rejections.json) が正です。数値は `limits.json` のキーを添えて書きます。
- 画面に出す文言を含みません。応答は、符号と数値だけです（文言はフロントエンドの文言カタログ）。
- 印の「**仮置き**」は、要件・設計メモに定めが無く、契約が置いた解釈です。6 章に一覧します。
- 内部通信（中継 → アプリケーション）は internal-api.md、WebSocket は ws-protocol.md です。

## 1. 共通の規約

### 1.1 経路

- ブラウザから見た HTTP の相手は、フロントエンドのオリジンだけです（同一オリジン）。すべての API は `/api/` 配下です。
- フロントエンド（Next.js の `app/api/[...path]/route.ts`。BFF）が、`BACKEND_ORIGIN` の同じパス（`/api/state` なら、アプリケーションの `/api/state`）へ中継します。バックエンドのドメインは、ブラウザへ出しません。セッションの Cookie は、第一者の Cookie として成立します。
- BFF は、`X-BFF-Secret` を付けます。ブラウザから来た `X-BFF-Secret`・`X-Relay-Secret`・`X-Forwarded-*`・`Host` は信用せず、捨てて、フロントエンドが値を作り直します。`Cookie`・`X-CSRF-Token`・`X-BL-Client`・`Content-Type`・`Accept` は通します。リダイレクトを追わず（302 をそのまま返し）、複数の `Set-Cookie` を欠落なく返します。
- `/internal/`・`/admin/` は、BFF を通りません。
- 開発・テストの環境にだけある疑似の経路（`/api/dev/` 配下。疑似の Google など）は、契約の外です。本番には存在せず（404）、BFF も、本番では転送しません。

### 1.2 ヘッダ

| ヘッダ | 向き | 内容 |
|---|---|---|
| `X-BFF-Secret` | フロントエンド → アプリケーション | すべての `/api/` の要求に付けます。値は `BFF_SHARED_SECRET`。アプリケーションは、**定数時間で**比較し、欠落・不一致は 403（`forbidden`。本文に手がかりを書きません）。ヘルスチェック（`/up`）は対象外です |
| `X-Forwarded-For` | フロントエンドが付与 | 利用者の IP（先頭の値）。頻度制限の計数にだけ使い、DB・ログ・測定イベント・配信レコードへ記録しません。`X-BFF-Secret` を通った要求からだけ読みます |
| `X-Forwarded-Host`・`X-Forwarded-Proto` | フロントエンドが付与 | リダイレクト先（公開オリジン）の組み立てにだけ使います。`X-BFF-Secret` を通った要求からだけ読みます |
| `X-BL-Client` | ブラウザ → | 値は `web`。状態を変える要求（POST・PUT・PATCH・DELETE）に必須です。クロスサイトのフォームの送信を成立させないためです |
| `X-CSRF-Token` | ブラウザ → | ログイン済みで、状態を変える要求に必須です。値は `GET /api/state` の `csrf_token` です。ブラウザは、メモリにだけ保持します（`localStorage` に置きません） |
| `Content-Type` | 両方向 | 本文のある要求は `application/json; charset=utf-8`。本文のある応答も同じです（204・302 を除く） |
| `Cache-Control` | アプリケーション → | すべての応答に `no-store` を付けます（**仮置き**） |

中継 → アプリケーションの `X-Relay-Secret` は、internal-api.md です。

### 1.3 Cookie

| 名前 | 内容 | 属性 |
|---|---|---|
| `bl_session` | セッション識別子のみ（乱数 32 バイトの URL 安全な文字列）。状態はサーバー側に持ちます | HttpOnly・SameSite=Lax・Path=/・本番は Secure（開発・テストの http では付けません）。有効期限の属性は付けません（ブラウザのセッション Cookie）（**仮置き**）。サーバー側は、最終利用から 30 日で失効させます（`retention.session_days_after_last_use`） |
| `bl_oauth` | 認可の途中の状態（state・nonce・PKCE の検証子・用途 `login` または `connect`・用途が `connect` のとき内部のアカウント識別子）。**暗号化**します（鍵は `SESSION_SECRET` から導出） | HttpOnly・SameSite=Lax・Path=/・Max-Age=600・本番は Secure。認可の完了後は、成功・失敗のどちらでも失効させます（state の再利用を防ぐ）（**仮置き**） |

### 1.4 認可と CSRF（評価の順）

アプリケーションは、すべての `/api/` の要求を、次の順に評価します。

| 順 | 検査 | 失敗したとき |
|---|---|---|
| 1 | `X-BFF-Secret` | 403 `forbidden` |
| 2 | 状態を変える要求は、`X-BL-Client: web` | 403 `csrf_invalid` |
| 3 | 状態を変える要求で、ログイン済みなら、`X-CSRF-Token` が、セッションに紐づく値と一致する。`Origin` ヘッダがあれば、公開オリジンと一致する | 403 `csrf_invalid` |
| 4 | ログインが要る API は、セッションが有効（破棄済み・期限切れは無効） | 401 `not_logged_in` |
| 5 | エンドポイントごとの検査（3 章） | 3 章のとおり |

- GET は、CSRF の対象外です（副作用を持ちません）。認可コードのコールバックの GET は、`state` で守ります。
- 例外：`POST /api/broadcasts` は、セッションが無いとき、401 を `rejected`（`not_logged_in`）で返します（9.2 の順 1。4 章）。

### 1.5 JSON の規約

- UTF-8。キーは snake_case。単位は名前に含めます（`_kbps`・`_ms`・`_us`・`_seconds`・`_bytes`）。
- 時刻は ISO 8601（JST、`+09:00`、秒まで。例 `2026-10-07T13:30:00+09:00`）。日付は `YYYY-MM-DD`（JST）。DB は UTC ですが、API は JST で返します。
- 識別子は UUID の文字列です。符号は enums.json の値です。
- 応答のキーは、値が無いとき null で、必ず持ちます（省略しません）。要求の未知のキーは、無視します。
- 要求の本文のある API は、`Content-Type: application/json` で送ります。

### 1.6 エラーの形と種類

エラーは `{"error":{"code":"<符号>","details":{…}}}` です（`details` は省略できます。省略は空のオブジェクトと同じ）。受付の拒否（`POST /api/broadcasts`）だけは、4 章の `rejected` の形です。

| 符号 | HTTP | 意味 | 返すエンドポイント |
|---|---|---|---|
| `forbidden` | 403 | `X-BFF-Secret` が欠落・不一致。本文に手がかりを書きません | すべて（通常、ブラウザには見えません） |
| `csrf_invalid` | 403 | `X-BL-Client` の欠落、`X-CSRF-Token` の欠落・不一致、`Origin` の不一致 | 状態を変えるすべて |
| `not_logged_in` | 401 | セッションが無い・無効 | ログインが要るすべて |
| `not_found` | 404 | 存在しない。**他のアカウントのレコードも、存在しないものとして 404**（存在を明かしません） | `/api/broadcasts/:id` 配下 |
| `invalid_input` | 422 | 要求を解釈できない、必須の項目が無い、値が不正。`details` の `fields` に、不備のある項目名の配列（**仮置き**）。`POST /api/broadcasts` は、`rejected` の形 | 本文・クエリを持つ API |
| `unsupported_event` | 422 | ブラウザから送れない種別の測定イベント | `POST /api/usage-events` |
| `bot_check_failed` | 403 | bot 判定が不合格、または判定不能（検証サービスに到達できない場合を含む。受理側へ倒しません） | `login/start`・`connect/start` |
| `rate_limited` | 429 | 頻度の上限。`details` の `retry_at`（頻度の枠が空く時刻） | `login/start`・`connect/start`・`recheck` |
| `broadcast_in_progress` | 409 | 終了していない配信がある（先に停止する） | `connect/start`・`disconnect`・`DELETE /api/account` |
| `broadcast_ended` | 409 | 配信は終了済み。`details` の `end_reason` | `POST /api/broadcasts/:id/ticket` |
| `not_resumable` | 409 | 復帰できない状態（`reserved`、または期限切れ） | `POST /api/broadcasts/:id/ticket` |
| `already_live` | 409 | ライブの確定後は、取り消せない | `POST /api/broadcasts/:id/cancel` |
| `not_connected` | 409 | YouTube が未接続 | `POST /api/youtube/recheck` |
| `unverifiable` | 503 | 確認できない（共通枠の枯渇・一時的な失敗）。接続状態は変更しません | `POST /api/youtube/recheck` |
| `internal_error` | 500 | 想定外の例外。詳細を応答に出しません（ログには識別子と原因を出します） | すべて |
| `bad_gateway` | 502 | フロントエンドが、アプリケーションへ到達できない（BFF が返す。`details` なし。詳細・URL を出しません） | すべて |

### 1.7 頻度制限

計数は、アプリケーションのプロセス内に保持します（永続化しません）。超過は 429 です。

| 対象 | 単位 | 上限 | 出どころ |
|---|---|---|---|
| ログインの開始 | IP | 30 回 / 時 | `rate_limits.login_start`（固定値） |
| YouTube 接続の開始 | IP | 30 回 / 時（ログインの開始とは別の計数） | `rate_limits.connect_start`（固定値）（**仮置き**） |
| 再確認 | アカウント | 1 回 / 分、20 回 / 日（直近 24 時間）（**仮置き**） | `rate_limits.recheck_per_minute`・`rate_limits.recheck_per_day` |
| 開始の受付要求 | アカウント | 10 回 / 時（設定 `intake_rate_per_hour`） | `rate_limits.intake`・`setting_defaults.intake_rate_per_hour`。到着のたびに数えます（拒否された要求も数える） |

`retry_at` は、頻度の枠が空く時刻です（ISO 8601）。

### 1.8 bot 判定（reCAPTCHA v3）

ログインの開始・YouTube 接続の開始・配信の開始要求に、`recaptcha_token` を付けます。アプリケーションは、行為名・発行元・有効期限・スコアをサーバー側で検証します（スコアは設定 `bot_score_threshold` 以上。`setting_defaults.bot_score_threshold`）。

| エンドポイント | 行為名 |
|---|---|
| `POST /api/auth/login/start` | `login` |
| `POST /api/youtube/connect/start` | `youtube_connect` |
| `POST /api/broadcasts` | `broadcast_start` |

開発・テストの疑似の bot 判定（疑似のトークン）は、契約の外です（本番の経路に出しません）。

## 2. 共通の型

### 2.1 `BroadcastView`（配信の表示用の情報）

**タイトルを含めません**（タイトルは、YouTube の配信識別子の保存時、または配信レコードの終了時に消去します）。

| 項目 | 型 | 内容 |
|---|---|---|
| `id` | 文字列 | 配信レコードの識別子（UUID） |
| `state` | 文字列 | 列挙 `broadcast_state` の値：`reserved`・`awaiting_media`・`confirming`・`live`・`interrupted`・`ended` |
| `end_reason` | 文字列または null | `state` が `ended` のときだけ、列挙 `end_reason` の値：`user_stop`・`time_limit`・`connection_lost`・`youtube_ended`・`authorization_revoked`・`admin_stop`・`start_timeout`・`confirm_timeout`・`prepare_failed`・`prior_unsettled`・`insufficient_bandwidth`・`user_cancel`・`relay_disconnect` |
| `profile` | 文字列または null | 列挙 `profile` の値（`720p`・`480p`）。準備の完了後に確定します。それまでは null |
| `accepted_at` | 文字列 | 受理の時刻 |
| `live_at` | 文字列または null | ライブが確定した時刻。確定前は null |
| `ended_at` | 文字列または null | 終了した時刻。終了前は null |
| `time_limit_ends_at` | 文字列または null | 時間上限に達する時刻（`live_at` + 時間上限）。ライブの確定前は null |
| `watch_url` | 文字列または null | 視聴 URL。準備の完了後に値を持ちます。YouTube の配信識別子を消去したあと（終了から 30 日。`retention.youtube_broadcast_id_days_after_end`）は null |
| `resumable` | 真偽値 | 復帰できるか。状態が `awaiting_media`・`confirming`・`live`・`interrupted` のいずれかで、期限内なら true（`POST /api/broadcasts/:id/ticket` が成功する条件） |
| `duration_seconds` | 整数または null | 配信時間（ライブの確定から終了まで。秒）。ライブが確定して終了したときだけ。それ以外は null |
| `next_available_at` | 文字列または null | 次に開始できる時刻（次の JST 03:00）。当該利用日の利用枠を消費済みのときだけ。それ以外は null |

```json
{"id":"2f6c1d0e-7b5a-4f0e-9a43-5c8f1e2d3a4b","state":"live","end_reason":null,"profile":"720p","accepted_at":"2026-10-07T13:30:00+09:00","live_at":"2026-10-07T13:31:10+09:00","ended_at":null,"time_limit_ends_at":"2026-10-07T14:31:10+09:00","watch_url":"https://www.youtube.com/watch?v=dummyVideoId","resumable":true,"duration_seconds":null,"next_available_at":null}
```

### 2.2 `usage`（利用状況）

| 項目 | 型 | 内容 |
|---|---|---|
| `usage_date` | 文字列 | 現在の利用日（JST 03:00 区切り。`YYYY-MM-DD`） |
| `allowance_total` | 整数 | 当該利用日の利用枠の合計（設定 `daily_allowance` + 開発者の手動リセットによる追加） |
| `allowance_remaining` | 整数 | 利用枠の残り（0 以上） |
| `attempts_remaining` | 整数 | 開始試行の残り（設定 `attempt_limit` − 計上済み。0 以上） |
| `next_available_at` | 文字列または null | 次に開始できる時刻（次の JST 03:00）。**利用枠を消費済み（`allowance_remaining` が 0）、または開始試行が上限（`attempts_remaining` が 0）のとき**。それ以外は null。どちらも次の利用日に解消するため、画面（スタジオ）が、再読み込みの後でも「次に開始できる時刻」を示せるようにする（**仮置き**：設計メモは「消費済みのときだけ」としていたが、試行上限のときに画面が時刻を知る手段が拒否の `retry_at` に限られるため、広げた） |
| `monthly_intake_closed` | 真偽値 | 当月の送信転送量が予算に達し、当月の受付が終了している |
| `intake_paused` | 真偽値 | 受付停止の設定が有効 |

### 2.3 `youtube`（YouTube の接続）

| 項目 | 型 | 内容 |
|---|---|---|
| `state` | 文字列 | 列挙 `youtube_connection_state` の値：`not_connected`・`connected`・`live_not_enabled`・`revoked` |
| `channel_title` | 文字列または null | チャンネル名。`GET /api/state` が `with_channel=1` のときだけ取得し（アプリケーションのメモリのキャッシュ。最長 10 分。永続化しない）、取得できなければ null。それ以外の応答では、常に null（YouTube を呼びません） |
| `can_recheck_at` | 文字列または null | 次に再確認できる時刻。今すぐ再確認できるなら null |

## 3. エンドポイント

### `GET /api/state`

画面の初期化と、状態の取得に使います。ログインは不要です（未ログインは `authenticated` が false）。

| 項目 | 内容 |
|---|---|
| 要求 | クエリ `with_channel=1`（任意。値が `1` のときだけ、チャンネル名を取得します） |
| 応答 | 200 |
| 副作用 | なし。進行中の配信があれば、当該配信の期限を評価します（期限切れなら、この応答の前に終了します）。YouTube は、`with_channel=1` のとき（キャッシュに無ければ）のチャンネル名の取得でだけ呼びます |
| 冪等性 | 冪等（GET） |

未ログイン：

```json
{"authenticated":false,"csrf_token":null}
```

ログイン済み：

```json
{"authenticated":true,"csrf_token":"dummy-csrf-token-0123456789abcdef","usage":{"usage_date":"2026-10-07","allowance_total":1,"allowance_remaining":1,"attempts_remaining":3,"next_available_at":null,"monthly_intake_closed":false,"intake_paused":false},"youtube":{"state":"connected","channel_title":null,"can_recheck_at":null},"broadcast":null}
```

- `csrf_token`：セッションごとの値（セッションの識別子と `SESSION_SECRET` から導出し、保存しません）。状態を変える要求の `X-CSRF-Token` に使います。
- `usage`・`youtube`：2 章。
- `broadcast`：**終了していない配信だけ**（`BroadcastView`）。無ければ null です。終了した配信は、`GET /api/broadcasts/:id` で取得します。

### `POST /api/auth/login/start`

ログインの開始です。Google の認可 URL を返します。

| 項目 | 内容 |
|---|---|
| 認可 | ログイン不要。`X-BL-Client: web` が必要です |
| 要求 | `{"recaptcha_token":"<reCAPTCHA の応答>"}` |
| 応答 | 200 `{"authorization_url":"https://accounts.google.com/o/oauth2/v2/auth?…"}`。`bl_oauth` の Cookie を設定します |
| エラー | 422 `invalid_input`（`recaptcha_token` が無い）、429 `rate_limited`（`details` の `retry_at`）、403 `bot_check_failed` |
| 冪等性 | 冪等ではありません（呼ぶたびに、新しい state・nonce・検証子の認可 URL を作り、`bl_oauth` を置き換えます） |

- 評価の順：入力の検証 → 頻度制限（IP。`rate_limits.login_start`）→ bot 判定（行為名 `login`）→ 認可 URL。
- 認可 URL：スコープは `openid` のみ（メールアドレス・プロフィールを要求しません）、`response_type=code`、PKCE（`code_challenge_method=S256`）、`state`、`nonce`、`redirect_uri` は公開オリジンの `/api/auth/callback`。
- 測定イベント `login_started` を記録します。

### `GET /api/auth/callback`

Google からの戻り先です（認可コードのコールバック）。

| 項目 | 内容 |
|---|---|
| 認可 | ログイン不要。CSRF の対象外（`state` で守ります） |
| 要求 | クエリ `code`・`state`（失敗のとき `error`） |
| 応答 | 302。`Location` は、公開オリジンの絶対 URL（`https://<フロントエンドのオリジン>/…`）。BFF は、そのまま返します |
| 冪等性 | 冪等ではありません（認可コードは 1 回限り） |

| 結果 | `Location` |
|---|---|
| 成功 | `/studio`。新しいセッションを発行します（既存のセッションは破棄。セッション固定化の防止）。`Set-Cookie: bl_session`。`bl_oauth` を失効させます。測定イベント `login_completed` |
| 再登録の保留中（削除から間もない Google アカウント） | `/?login_error=registration_held`（アカウントを作りません） |
| `state` の不一致・欠落・期限切れ、`error` パラメータ、ID トークンの検証の失敗、通信の失敗 | `/?login_error=oauth_failed` |

`login_error` は、列挙 `login_error` の値（`registration_held`・`oauth_failed`）です。

### `POST /api/auth/logout`

| 項目 | 内容 |
|---|---|
| 認可 | ログイン必須。CSRF（`X-BL-Client`・`X-CSRF-Token`） |
| 要求 | 本文なし |
| 応答 | 204。セッションを破棄し、`bl_session` を失効させます |
| エラー | 401 `not_logged_in` |
| 冪等性 | 2 回目は、セッションが無いので 401 です |

### `POST /api/youtube/connect/start`

YouTube の接続の開始です（段階的な認可）。YouTube の権限の認可 URL を返します。

| 項目 | 内容 |
|---|---|
| 認可 | ログイン必須。CSRF |
| 要求 | `{"recaptcha_token":"<reCAPTCHA の応答>"}` |
| 応答 | 200 `{"authorization_url":"https://accounts.google.com/o/oauth2/v2/auth?…"}`。`bl_oauth`（用途 `connect`）を設定します |
| エラー | 422 `invalid_input`、409 `broadcast_in_progress`、429 `rate_limited`（`details` の `retry_at`）、403 `bot_check_failed` |
| 冪等性 | 冪等ではありません |

- 評価の順：入力の検証 → 進行中の配信（接続・再接続を受け付けない）→ 頻度制限（IP。`rate_limits.connect_start`）→ bot 判定（行為名 `youtube_connect`）→ 認可 URL。
- 認可 URL：スコープは `https://www.googleapis.com/auth/youtube` の 1 種のみ、`access_type=offline`、`prompt=consent`（接続のたびに同意画面を表示し、更新トークンの発行を確実にする）、`login_hint`（ログイン中の Google の識別子 `sub`。接続先のチャンネルは、同意画面で利用者が選びます）、PKCE、`state`。`include_granted_scopes` は付けません。
- 測定イベント `connect_started` を記録します。

### `GET /api/youtube/connect/callback`

YouTube の接続の、Google からの戻り先です。

| 項目 | 内容 |
|---|---|
| 認可 | ログイン中のセッションが要ります（`bl_oauth` のアカウントと、セッションのアカウントが一致すること）。CSRF の対象外（`state` で守ります） |
| 要求 | クエリ `code`・`state`（失敗のとき `error`） |
| 応答 | 302。`Location` は `/account?connect=<connect_result>`（公開オリジンの絶対 URL） |
| 冪等性 | 冪等ではありません |

`connect_result`（列挙 `connect_result` の値）：

| 値 | 意味 | 接続 |
|---|---|---|
| `connected` | チャンネルがあり、ライブ配信が有効 | 成立（接続状態 `connected`） |
| `live_not_enabled` | チャンネルはあるが、ライブ配信が有効でない | 成立（接続状態 `live_not_enabled`） |
| `scope_denied` | YouTube の権限が付与されなかった（同意画面での拒否・取り消し `error=access_denied` を含む） | 不成立 |
| `no_refresh_token` | 応答に更新トークンが無い | 不成立 |
| `no_channel` | チャンネルが無い | 不成立 |
| `unverifiable` | 確認できない（共通枠の枯渇・一時的な失敗）。`state` の不一致・欠落・期限切れ、セッションのアカウントとの不一致も、ここへ含めます（**仮置き**） | 不成立 |

- 成立したとき：更新トークンを暗号化して保存し、保存済みの配信用ストリームの識別子を破棄します（10.5。再接続を含め、成立のたびに）。測定イベント `connect_completed`。
- 不成立のとき：受け取ったトークンを保存せず破棄します（既存の接続が無いときに限り、Google 側でも失効させます）。既存の接続の状態・トークン・ストリームの識別子は、変更しません。測定イベント `connect_failed`（理由の符号のみ）。
- 成功・失敗のどちらでも、`bl_oauth` を失効させます。

### `POST /api/youtube/recheck`

ライブ配信が有効かの、再確認です（7.2）。

| 項目 | 内容 |
|---|---|
| 認可 | ログイン必須。CSRF |
| 要求 | 本文なし |
| 応答 | 200 `{"youtube":{"state":"connected","channel_title":null,"can_recheck_at":"2026-10-07T13:31:00+09:00"}}`（`youtube` は 2 章。`channel_title` は常に null、`can_recheck_at` は、次に再確認できる時刻） |
| エラー | 429 `rate_limited`（`details` の `retry_at`）、409 `not_connected`、503 `unverifiable`（接続状態は変更しません） |
| 冪等性 | 冪等（結果が同じ状態へ収束します）。頻度制限があります |

- 頻度制限：アカウント単位で、1 分に 1 回・1 日 20 回（`rate_limits.recheck_per_minute`・`rate_limits.recheck_per_day`）。
- 接続状態が `revoked` のときは、再確認せず、200 で `state` が `revoked` を返します（再接続を促します）。トークンの更新が恒久的に失敗したときも、`revoked` にして 200 です。
- 接続済み・ライブ未有効のとき、チャンネルとライブの有効を再確認し、`connected` ⇄ `live_not_enabled` を更新します（各 1 ユニットの一覧取得。共通枠から支出）。共通枠の枯渇・一時的な失敗・チャンネルが見つからないときは、状態を変えず、503 です。

### `POST /api/youtube/disconnect`

YouTube の接続の解除です（7.4）。

| 項目 | 内容 |
|---|---|
| 認可 | ログイン必須。CSRF |
| 要求 | 本文なし |
| 応答 | 200 `{"youtube":{"state":"not_connected","channel_title":null,"can_recheck_at":null}}` |
| エラー | 409 `broadcast_in_progress`（進行中の配信がある間は受け付けません。先に停止します） |
| 冪等性 | 冪等です。すでに未接続でも、同じ 200 を返します（**仮置き**） |

- 手順：未清算の配信の清算を試み（清算の再試行の 1 回として数えます。失敗しても続行）、Google 側でトークンを失効させ、保存したトークンとストリーム識別子を削除します。YouTube 側のストリームは削除しません。測定イベント `disconnected`。

### `DELETE /api/account`

アカウントの削除です（7.4）。

| 項目 | 内容 |
|---|---|
| 認可 | ログイン必須。CSRF |
| 要求 | 本文なし |
| 応答 | 204。セッションの Cookie を失効させます |
| エラー | 409 `broadcast_in_progress` |
| 冪等性 | 2 回目は、セッションが無いので 401 です |

- 要求の受理と同時に削除します（非同期にしません）。未清算の配信を清算できなくても、削除は実行します。当該アカウントに紐づく全レコードを削除し、測定イベントと割り当ての記帳の明細は、紐づけを外します。
- 削除した Google アカウントの識別子の要約値を、削除時点の利用日の終わりまで保持し、その間は、同じ Google アカウントでの再登録を受け付けません（ログインのコールバックが `registration_held`）。

### `POST /api/broadcasts`

配信の開始の受付です。受理すると、配信レコードを作成し、割り当てを予約し、接続チケットを発行します（同一のトランザクション）。**この時点では、YouTube の資源を作りません。**

| 項目 | 内容 |
|---|---|
| 認可 | CSRF。セッションが無いときは、`rejected`（`not_logged_in`）で 401 |
| 要求 | 下の表 |
| 応答 | 201（受理）、または 4 章の拒否 |
| 冪等性 | 冪等ではありません。同一アカウントからの同時の受付要求は、1 件だけが受理され、残りは `broadcast_in_progress` で拒否されます |

要求：

| 項目 | 型 | 内容 |
|---|---|---|
| `title` | 文字列 | 配信のタイトル。1〜100 文字（Unicode のコードポイントの数）で、山括弧（`<`・`>`）を含まない（9.1）（**仮置き**：文字数の数え方） |
| `privacy_status` | 文字列 | `public`（公開）・`unlisted`（限定公開）・`private`（非公開） |
| `made_for_kids` | 真偽値 | 子ども向けの申告。必須です（既定値を持たず、利用者の明示的な選択を必須とします） |
| `recaptcha_token` | 文字列 | reCAPTCHA の応答（行為名 `broadcast_start`） |

```json
{"title":"ライブ配信 2026-10-07 13:30","privacy_status":"unlisted","made_for_kids":false,"recaptcha_token":"<reCAPTCHA の応答>"}
```

受理 201：

```json
{"broadcast":{"id":"2f6c1d0e-7b5a-4f0e-9a43-5c8f1e2d3a4b","state":"reserved","end_reason":null,"profile":null,"accepted_at":"2026-10-07T13:30:00+09:00","live_at":null,"ended_at":null,"time_limit_ends_at":null,"watch_url":null,"resumable":false,"duration_seconds":null,"next_available_at":null},"ticket":"dummy-ticket-0123456789abcdefghijklmnopqrstuvwxyz","relay_url":"ws://localhost:3002/ws","limits":{"time_limit_seconds":3600,"profiles":{"720p":{"width":1280,"height":720,"framerate":30,"video_bitrate_min_kbps":3000,"video_bitrate_initial_kbps":4500,"video_bitrate_max_kbps":6000,"line_threshold_kbps":4100},"480p":{"width":854,"height":480,"framerate":30,"video_bitrate_min_kbps":800,"video_bitrate_initial_kbps":1500,"video_bitrate_max_kbps":2500,"line_threshold_kbps":1200}},"audio_kbps":128}}
```

| 項目 | 型 | 内容 |
|---|---|---|
| `broadcast` | オブジェクト | `BroadcastView`（`state` は `reserved`） |
| `ticket` | 文字列 | 接続チケット。推測不可能な長さ（32 バイト以上の乱数）の URL 安全な文字列。アカウント・配信の識別子から導出しません。1 回の照合で消費され、60 秒（`tickets.ttl_seconds`）で失効します。DB には要約値だけを保存します |
| `relay_url` | 文字列 | 中継の接続先。完全な WebSocket の URL（`wss://…/ws`。開発環境は `ws://localhost:3002/ws`） |
| `limits` | オブジェクト | 適用される上限。`time_limit_seconds`（時間上限。秒）、`profiles`（`limits.json` の `profiles` をそのまま）、`audio_kbps`（音声のビットレート。`audio.bitrate_kbps`） |

- 測定イベント：受理は `start_requested`、拒否は `start_rejected`（拒否理由別）。
- 同時の判定：同時配信数の上限（既定 3）を超える受理はありません。

### `POST /api/broadcasts/:id/ticket`

復帰（再接続）のための、新しい接続チケットを発行します。

| 項目 | 内容 |
|---|---|
| 認可 | ログイン必須。CSRF。他のアカウントの配信は 404 |
| 要求 | 本文なし |
| 応答 | 200 `{"ticket":"…","relay_url":"ws://localhost:3002/ws"}`（項目は、`POST /api/broadcasts` と同じ） |
| エラー | 404 `not_found`、409 `broadcast_ended`（`details` の `end_reason`）、409 `not_resumable` |
| 冪等性 | 冪等ではありません（呼ぶたびに、60 秒で失効する、1 回限りのチケットを発行します） |

- 発行する条件：配信の状態が `awaiting_media`・`confirming`・`live`・`interrupted` のいずれかで、かつ期限内（13.2）。
- 要求の受理時に、配信の期限を評価します（期限切れなら終了させます）。終了済みは 409 `broadcast_ended`（`end_reason`）、`reserved` や期限切れは 409 `not_resumable` です。

### `POST /api/broadcasts/:id/stop`

配信の停止です（利用者の停止操作・別の端末からの停止）。

| 項目 | 内容 |
|---|---|
| 認可 | ログイン必須。CSRF。他のアカウントの配信は 404 |
| 要求 | 本文なし |
| 応答 | 200 `{"broadcast":<BroadcastView>}` |
| エラー | 404 `not_found` |
| 冪等性 | 冪等です。終了済みの配信への停止は、同じ結果（終了済みの `BroadcastView`）を返します。**停止は、必ず成功として完了します**（YouTube 側の完了が、自動停止に委ねられる場合を含む） |

- 終了理由：ライブ・中断の配信は `user_stop`、ライブ確定前の配信（`reserved`・`awaiting_media`・`confirming`）は `user_cancel`。
- 終了と同時に清算状態を定めます（YouTube の資源があれば未清算）。清算の成否・所要時間に関わらず、応答は、終了の記録の直後に返り、利用者の次の操作を妨げません。

### `POST /api/broadcasts/:id/cancel`

ライブ確定前の取り消しです（回線不足を含む）。ライブ確定前の取り消しは、利用枠を消費しません。

| 項目 | 内容 |
|---|---|
| 認可 | ログイン必須。CSRF。他のアカウントの配信は 404 |
| 要求 | `{"reason":"user_cancel"}` または `{"reason":"insufficient_bandwidth"}`（列挙 `end_reason` の値のうち、2 つ） |
| 応答 | 200 `{"broadcast":<BroadcastView>}` |
| エラー | 404 `not_found`、409 `already_live`（ライブの確定後）、422 `invalid_input`（`reason` が不正。または `insufficient_bandwidth` を、`reserved` 以外の配信へ送った）（**仮置き**） |
| 冪等性 | 冪等です。終了済みの配信への取り消しは、同じ結果を返します |

### `GET /api/broadcasts/:id`

配信の表示用の情報の取得です。終了した配信も取得できます。

| 項目 | 内容 |
|---|---|
| 認可 | ログイン必須（GET のため CSRF は不要）。他のアカウントの配信は 404 |
| 応答 | 200 `{"broadcast":<BroadcastView>}` |
| エラー | 404 `not_found` |
| 冪等性 | 冪等（GET）。要求の受理時に、当該配信の期限を評価します |

### `POST /api/usage-events`

ブラウザ側の測定イベントを記録します（18 章）。ベストエフォートです（失敗しても、配信を妨げません）。

| 項目 | 内容 |
|---|---|
| 認可 | ログイン必須。CSRF |
| 要求 | 下の表 |
| 応答 | 204 |
| エラー | 422 `unsupported_event`（ブラウザから送れない種別）、422 `invalid_input` |
| 冪等性 | 冪等ではありません（1 回の要求が 1 件のイベント） |

| 項目 | 型 | 内容 |
|---|---|---|
| `event_type` | 文字列 | ブラウザが送れる種別は、`capability_detected`・`source_granted`・`source_denied`・`line_measured`・`watch_url_copied` の 5 つだけ。ほかの測定イベントの種別（`login_started` など）は、サーバーが記録します |
| `reason_code` | 文字列（任意） | 符号。`^[a-z0-9_]{1,32}$`。自由記述の文字列・デバイス名を送りません（**仮置き**：形式） |
| `value` | 整数（任意） | 数値（0 以上）。例：`line_measured` の実効スループット（kbps）。サーバーが区分に変換して記録します（数値のまま保存しません）（**仮置き**） |
| `browser_class` | オブジェクト（任意） | `{"family":"chromium","supported":true}`。`family` は系統（`chromium`・`firefox`・`webkit`・`other`）、`supported` は能力検出の結果（対応可否）。**ユーザーエージェントの文字列を受け取りません**（**仮置き**：形式） |

```json
{"event_type":"line_measured","value":5200,"browser_class":{"family":"chromium","supported":true}}
```

- 測定イベントは、内部のアカウント識別子にだけ紐づけます。氏名・メールアドレス・チャンネル名・タイトル・IP アドレス・端末を特定する文字列を含めません（18.2・28.2）。

## 4. 受付の拒否（`POST /api/broadcasts`）

判定は、次の順に行い、最初に該当した理由で拒否します（9.2）。**利用者自身の状態に起因し、再試行しても解消しない理由を、システム都合の一時的な理由より先に返します。** 順 0〜3 は、アカウントの現況を参照する前に判定します。

拒否の応答は、`rejected` の形です（HTTP ステータスは、下の表）。

```json
{"rejected":{"reason":"allowance_consumed","resolution":"next_usage_day","retry_at":"2026-10-08T03:00:00+09:00"}}
```

| 項目 | 型 | 内容 |
|---|---|---|
| `reason` | 文字列 | 列挙 `rejection_reason` の値 |
| `resolution` | 文字列 | 再試行で解消するかの区分（列挙 `resolution` の値） |
| `retry_at` | 文字列または null | 再試行の目安時刻（ISO 8601、JST）。下の表の「retry_at」の規則に当てはまる理由だけが持ち、それ以外は null |
| `fields` | 文字列の配列 | `invalid_input` のときだけ。不備のある入力項目の名前（`title`・`privacy_status`・`made_for_kids`・`recaptcha_token`）（**仮置き**：9.2「該当項目を示す」のため） |

```json
{"rejected":{"reason":"invalid_input","resolution":"fix_input","retry_at":null,"fields":["title"]}}
```

| 順 | 拒否理由 | HTTP | 区分 | retry_at | 画面の案内の趣旨（9.2） |
|---|---|---|---|---|---|
| 0 | `invalid_input` | 422 | `fix_input` | なし | 該当項目を示す |
| 1 | `not_logged_in` | 401 | `log_in` | なし | ログインへ誘導する |
| 2 | `rate_limited` | 429 | `wait` | 頻度の枠が空く時刻 | 再試行の目安時刻を示す |
| 3 | `bot_check_failed` | 403 | `wait` | なし | 再試行を案内する |
| 4 | `broadcast_in_progress` | 409 | `stop_first` | なし | 復帰または停止の操作を示す |
| 5 | `youtube_not_connected` | 409 | `connect` | なし | 接続へ誘導する |
| 6 | `authorization_revoked` | 409 | `reconnect` | なし | 再接続へ誘導する |
| 7 | `live_not_enabled` | 409 | `enable_live` | なし | 有効化の手順と再確認の操作を示す |
| 8 | `allowance_consumed` | 409 | `next_usage_day` | 次の JST 03:00 | 次に開始できる時刻を示す |
| 9 | `attempts_exhausted` | 409 | `next_usage_day` | 次の JST 03:00 | 次に開始できる時刻を示す |
| 10 | `intake_paused` | 503 | `after_release` | なし | 受付を停止している旨を示す |
| 11 | `transfer_budget_exceeded` | 503 | `next_month` | 翌月 1 日 00:00 JST | 当月の受付を終了した旨を示す |
| 12 | `capacity_full` | 503 | `wait` | なし | 時間を置いた再試行を案内する |
| 13 | `quota_insufficient` | 503 | `next_quota_day` | 次の割り当て日の始まりを JST で表した時刻 | 再開の目安時刻を示す |

- `retry_at` の決め方（`http-rejections.json` の `retry_at_rule`）：`rate_limit_window` は頻度の枠が空く時刻、`next_usage_day_start` は次の JST 03:00、`next_month_start` は翌月 1 日 00:00 JST、`next_quota_day_start` は、次の割り当て日（太平洋時間の日付）の始まり（太平洋時間の 0 時）を、JST（`+09:00`）で表した時刻です。割り当て日は、固定の時差ではなく、太平洋時間のタイムゾーン定義（夏時間を含む）で算出します。
- bot 判定の検証サービスに到達できない場合は、判定不能として、`bot_check_failed` で拒否します（受理側へ倒しません）。
- 区分（`resolution`）の意味：`fix_input`（修正後に可）・`log_in`（ログイン後に可）・`wait`（時間を置いて可）・`stop_first`（先に停止）・`connect`（接続後に可）・`reconnect`（再接続後に可）・`enable_live`（有効化後に可）・`next_usage_day`（次の利用日に可）・`after_release`（解除後に可）・`next_month`（翌月に可）・`next_quota_day`（次の割り当て日に可）。

## 5. 冪等性の一覧

| エンドポイント | 冪等性 |
|---|---|
| `GET /api/state` | 冪等（GET） |
| `POST /api/auth/login/start` | 冪等ではない（新しい state の認可 URL） |
| `GET /api/auth/callback` | 冪等ではない（認可コードは 1 回限り） |
| `POST /api/auth/logout` | 2 回目は 401 |
| `POST /api/youtube/connect/start` | 冪等ではない |
| `GET /api/youtube/connect/callback` | 冪等ではない |
| `POST /api/youtube/recheck` | 冪等（頻度制限あり） |
| `POST /api/youtube/disconnect` | 冪等（未接続でも 200） |
| `DELETE /api/account` | 2 回目は 401 |
| `POST /api/broadcasts` | 冪等ではない（同時の要求は 1 件だけが受理） |
| `POST /api/broadcasts/:id/ticket` | 冪等ではない（呼ぶたびに新しいチケット） |
| `POST /api/broadcasts/:id/stop` | 冪等（必ず成功） |
| `POST /api/broadcasts/:id/cancel` | 冪等 |
| `GET /api/broadcasts/:id` | 冪等（GET） |
| `POST /api/usage-events` | 冪等ではない（ベストエフォート） |

## 6. 仮置きと疑義

| 項目 | 置いた内容 | 理由 |
|---|---|---|
| `Cache-Control` | すべての応答に `no-store` | 状態・CSRF トークン・認可 URL を、共有のキャッシュ・ブラウザの履歴に残さないため（設計メモに定めが無い） |
| `Location`（コールバックの 302） | 公開オリジンの絶対 URL。バックエンドのホストを含めない | Rails の `redirect_to` は、相対パスを、リクエストのホスト（バックエンド）の絶対 URL にするため、公開オリジンから組み立てる（#7 の `PublicOrigin`） |
| `bl_session` の有効期限の属性 | 付けない（セッション Cookie） | 設計メモは、属性を HttpOnly・SameSite=Lax・本番は Secure としか挙げず、`bl_oauth` の Max-Age のような記述が無い |
| `bl_oauth` の失効 | 成功・失敗のどちらでも失効させる | state の再利用を防ぐ（#8 は成功時だけを記述） |
| `usage` の `next_available_at` | 利用枠を消費済み、または開始試行が上限のとき（次の JST 03:00）。それ以外は null | 設計メモは「消費済みのときだけ」だったが、試行上限のときに、再読み込みの後で画面が時刻を知る手段が拒否の `retry_at` に限られるため、広げた（親の判断。#12 の `/api/state` の実装は、この定めに従う） |
| 汎用のエラー（`invalid_input`・`not_found`・`forbidden`・`internal_error`・`bad_gateway`）と `details` の `fields` | 追加 | #7 が「不正な入力（422）・存在しない（404）・想定外の例外（500）」を、符号なしで求めている |
| `rejected` の `fields` | `invalid_input` のときだけ、不備のある項目名の配列 | 9.2「該当項目を示す」。設計メモの形に、項目名が無い（#5 の `Admission::Rejected` は `fields` を持つ） |
| `title` の文字数 | Unicode のコードポイントの数 | 数え方が、Ruby（文字）と JavaScript（UTF-16）で異なる |
| `connect/callback` の失敗の符号 | `error=access_denied` は `scope_denied`。state の不一致・期限切れ・アカウントの不一致は `unverifiable` | 設計メモの `connect_result` に、これらの失敗の対応が無い |
| 再確認の「1 日 20 回」 | 直近 24 時間 | 要件は、暦日か直近 24 時間かを定めていない（計数はプロセス内の頻度制限） |
| ログインの開始と接続の開始の頻度 | 別々の計数（それぞれ 30 回 / 時 / IP） | 「ログイン・YouTube 接続の開始は IP 単位で 30 回 / 時」が、合算か別々かを定めていない |
| `disconnect` が未接続のとき | 200（冪等） | 設計メモに定めが無い |
| `cancel` の `insufficient_bandwidth` | `reserved` のみ。それ以外は 422 `invalid_input` | #12 は `reserved` のみとするが、エラーの符号が無い |
| `usage-events` の `reason_code`・`value`・`browser_class` | 形式を限る（符号・非負の整数・系統と対応可否のオブジェクト） | 設計メモは、項目名と「UA 文字列を受け取らない」だけを定める。PII の混入を防ぐ |
