# test/pr48

PR #48（issue #8「認証: Google ログイン（OIDC・PKCE）・bot 判定・再登録の保留・開発環境の疑似 Google」）のテストです。対象は開発サーバー（`scripts/dc.sh` 経由の docker compose と、ホストの `localhost`）です。

実装担当が書いたテスト（`src/backend/spec/` の RSpec）を、実サーバー・フロントエンドの同一オリジン中継・実ブラウザ・本番の起動の検査・変異の確認と合わせて、1 回で実行します。

```bash
scripts/setup_dev_env.sh      # .env を生成します（済んでいれば何も変わりません）
test/pr48/run_all.sh      # すべて（十数分かかります。変異の確認が長い）
```

終了コードは、成功が 0、失敗が 1、前提を満たさない場合が 2 です。SKIP（確認できなかった）は成功に数えず、件数を表示します（Playwright が無いとき、実ブラウザの確認が SKIP になります）。

## 手順

| 手順 | 確かめること |
|---|---|
| 1. RSpec と RuboCop | この issue のスペックと、変更した #7 の基盤のスペック（`spec/gateways`・`spec/controllers`・`spec/requests`・`spec/sources`・`spec/config`・`spec/lib`・認証と基盤の `spec/services`）。テスト用 DB は `bl_test_issue8`（`TEST_DB_NAME` で変えられる）。実際の Google・reCAPTCHA を呼ばない（WebMock。ID トークンの署名には、スペックの中でメモリの上に作った RSA 鍵を使う） |
| 2. `CI=true` | 同じスペックを、eager_load を有効にして実行します（CI と同じ。`app/gateways` の読み込みの誤りを見つけます） |
| 3. RuboCop | アプリケーション・config のファイル |
| 4. Zeitwerk | `bin/rails zeitwerk:check` |
| 5. Brakeman | 静的解析の警告 0 件（backend 全体） |
| 6. bundler-audit | `jwt`・`webmock` を足した `Gemfile.lock` に、既知の脆弱性が無い |
| 7. `live_server_check.rb` | **実サーバー（Puma）** に対して、HTTP で、疑似の Google でのログインの全体を確かめます（41 項目）。`login/start`（BFF の確認・入力・bot 判定・認可 URL・`bl_oauth`）・疑似の認可画面・コールバック（state の不一致・拒否・成功・公開オリジンへの 302・`bl_session` の属性）・セッションの利用と固定化の防止・ログアウト・頻度制限（31 回目で 429）・ログに state・nonce・コード・識別子・IP・sub が出ないこと |
| 8. `curl_bff_check.sh` | ホストの `curl` から、**フロントエンドの同一オリジン中継（`http://localhost:3000`）を通して**、同じ流れを確かめます（Cookie の入れ物で受け渡し）。`Set-Cookie`・`Location` が、中継を通って欠落なく届くこと。バックエンドのドメインが、応答に出ないこと |
| 9. `browser_flow_check.cjs` | **実ブラウザ（Playwright の Chromium）** で、ランディングの「LOG IN WITH GOOGLE」→ 疑似の Google のアカウント選択 → `/studio` を操作します。`bl_session` の属性（HttpOnly・SameSite=Lax・ブラウザのセッション Cookie）、`document.cookie` から見えないこと、戻る操作での再選択が `/?login_error=oauth_failed`（ログインの失敗の通知）になること、外部のドメインへ通信しないこと。スクリーンショットは `ARTIFACT_DIR` へ |
| 10. `check_production.sh` | **本番（`RAILS_ENV=production`）の起動の検査**（コンテナの中。DB・外部サービスへは接続しません）。実物の資格情報が欠けていれば疑似へ倒れず起動に失敗する／実物が選ばれる／疑似は構築できない／`/api/dev/` の経路が無く 404／コールバックの `Location` は公開オリジン（`X-Forwarded-Host`。バックエンドの Host を使わない）／`bl_oauth` の失効に `Secure`／すべての `/api` の動作がログインの方針を宣言している ほか（`production_check.rb`。20 項目）。開発では疑似が選ばれること |
| 11. `mutation_check.sh` | **変異の確認**。アプリケーションの 1 か所（state の照合・PKCE・nonce・`exp`・アルゴリズム・`iss`・`aud`・`client_secret`・スコープ・公開鍵のキャッシュの古い鍵への倒れ・`remoteip` の送信・無料枠の超過・到達不能の扱い・再登録の保留・セッションの入れ替え・`bl_oauth` の失効・bot 判定・頻度制限・リダイレクト先・P1 の宣言・`Secure`・疑似のリダイレクト先の検査・TLS の検証・リダイレクトの追従 ほか）を、実行中のプロセスの中で壊し、該当するスペックが落ちることを確かめます。基準（変異なし）が緑であることも確かめます。既定は重要な 30 件（`MUTATION_SET=all` で 40 件） |
| 12・13. `scan_sources.py` | この issue の成果物とこのディレクトリに、絵文字・不可視の文字・削除系コマンド・機密の直書き・秘密鍵のファイル（`*.pem`・`*.key`）が無い（走査器の自己検査つき） |

## issue #8 の受け入れ条件との対応

| 受け入れ条件 | 確かめる手順 |
|---|---|
| `login/start`: 頻度制限（IP 31 回目で 429・`retry_at`）→ bot 判定（`login`）→ 認可 URL（`openid` のみ・`code`・S256・state・nonce・`redirect_uri` は公開オリジンの `/api/auth/callback`）。`bl_oauth` に暗号化して持つ。`login_started` | 1・7・8・9 |
| `callback`: state の照合（不一致・欠落・期限切れ・`error` は `oauth_failed`）→ コードの交換（`client_secret`・検証子）→ ID トークンの検証（署名・`iss`・`aud`・`exp`・`iat`・`nonce`・`sub`）→ sub でアカウント特定 → 新しいセッション（固定化の防止）→ `last_login_at` → `login_completed` → 302 `/studio`。`bl_oauth` を失効 | 1・7・8・9・11 |
| 外部への HTTP は `ExternalHttp`（接続 3 秒・読み取り 5 秒・リダイレクトを追わない・TLS 検証あり）。通信失敗は `oauth_failed`。トークンを永続化しない・`sub` 以外を保存しない | 1・11（アカウントの行の全列・DB の全表の走査を含む） |
| bot 判定: `RecaptchaVerifier#verify` → `:pass`・`:fail`・`:indeterminate`（行為名・ホスト・有効期限 2 分・スコア。到達不能・5xx・解釈できない応答・`error-codes` が空でない・無料枠の超過は `:indeterminate`）。IP を送らない・トークンをログへ出さない | 1・11 |
| `AccountRegistry`: `:existing`・`:created`・`:held`。保留は `sub` の HMAC-SHA256 と利用日（その利用日の終わりまで。JST 02:59 は保留・03:00 は可）。`record_hold`・`release_expired`。`logout`（204） | 1・7・11 |
| 疑似 Google: `AppEnvironment.external_services` で選択（本番は常に実物）。`/api/dev/google/authorize` は開発・テストのみで、本番はルート自体が無い（404）。固定の 3 アカウント。疑似の reCAPTCHA（`dev-pass`・`dev-fail`・`dev-indeterminate`・それ以外は `:fail`） | 1・7・8・9・10 |
| テスト: OIDC の正常・異常、state、PKCE、交換・通信の失敗、reCAPTCHA の行列、頻度制限、セッション固定化、再登録の保留、メール・氏名の非保存、ログに機密が出ない。RSpec・RuboCop・Brakeman が緑 | 1〜6 |
| #7 の提案 P1: `requires_login` か `allow_anonymous` の宣言が無い動作は、要求時に拒否（500 `internal_error`。原因はログ）。全動作の網羅スペック | 1・10・11 |
| #7 の提案 P5: 本番の `assume_ssl`・`force_ssl` が true（静的）。本番の構成での `Set-Cookie` に `Secure` | 1・10 |
| コールバックのリダイレクト先は `PublicOrigin`（`error=access_denied` の `Location` はフロントエンドのホスト） | 1・7・8・9・10 |

## 注意

- **最初のデプロイでの実測が要る前提**: コールバックの `Location` は、フロントエンドの中継が付ける `X-Forwarded-Host` から作ります。Railway が `X-Forwarded-Host` を上書きすると、リダイレクト先がバックエンドのホストになり、ログインの戻りが壊れます（同じ理由で、`POST` の `Origin` の照合も失敗します）。スペックと手順 10 は、「上書きされない」前提で、公開オリジンになることを確かめます。実際の Railway で、最初のデプロイのときに実測してください。
- 開発 DB には、手順 7・8・9 で、疑似のアカウント（`dev-user-1`・`dev-user-2`。ログインの操作で必ずできるもの）・測定イベント（`login_started`・`login_completed`）が作られます。セッションは、手順 7 のログアウトで消えます。
- 手順 7 の前に、backend が古いコード（`app/gateways` が無い）のときだけ、`scripts/dc.sh restart backend` を実行します（healthy になるまで待ちます）。共有の開発環境なので、ほかの担当の作業中は、短時間の再起動になります。

## 環境変数（任意）

| 変数 | 内容 |
|---|---|
| `TEST_DB_NAME` | 手順 1・2・4・11 のテスト用 DB の名前（既定 `bl_test_issue8`）。`bl_test_` で始まる名前に限ります（開発 DB は使えません） |
| `MUTATION_SET` | `key`（既定）または `all` |
| `PLAYWRIGHT_DIR` | playwright のディレクトリ（無ければ、npx のキャッシュなどから探します） |
| `ARTIFACT_DIR` | 手順 9 のスクリーンショットの置き場 |
| `FRONTEND_PORT` | フロントエンドのポート（既定 3000） |
| `STEP_TIMEOUT` | 1 手順の上限の秒数（既定 900。変異の確認だけ 2400） |

## 安全上の約束

- ファイルも DB も削除しません。作業用の一時ファイルは `mktemp` の場所に残します（最後に場所を表示します）。使い終わった DB・Cookie の入れ物は、必要なら手動で削除してください。
- 実際の Google・YouTube・reCAPTCHA・本番へは接続しません（疑似・WebMock・コンテナの中だけ）。秘密値（`.env`）は、画面へ出しません。
- ハーネスの安全（`.claude/TEST-HARNESS-SAFETY.md`）: 自己再帰ガード（TH1。`ISSUE08_RUN_ALL_ACTIVE`）・`ulimit -u`・各手順の `timeout`（TH3）。
- このディレクトリのソースに、削除系コマンドの語と絵文字を書きません（CI の hygiene が検査します。語を書く必要がある走査器は、語を分けて組み立てます）。

## ユーザーテスト手順（非エンジニア向け）

PR の本文にあります。開発環境での操作です。実際の Google ログインは、本番のみです（OAuth クライアントの発行が要ります）。

1. 開発サーバーを起動します（`scripts/dc.sh up -d --wait`）。
2. ブラウザで `http://localhost:3000/` を開きます。「LOG IN WITH GOOGLE」のボタンが出ます。
3. ボタンを押します。**開発用の疑似の Google の画面**（見出し「Google」と、`dev-user-1`・`dev-user-2`・`dev-user-3` の 3 つのリンク）に移ります。
4. `dev-user-1` を選びます。サイトの `/studio` へ戻ります。**この時点では、スタジオの画面が未実装のため、「Not Found（404）」の画面（「ページが見つかりません。アドレスを確認して、あらためて開いてください。」）が出ます。** これは想定どおりで、ログインのあとに `/studio` へ戻れたことを表します。
5. ブラウザの「戻る」を押してアカウント選択の画面へ戻り、もう一度 `dev-user-1` を選びます。ランディングへ戻り、**「ログインできませんでした。時間を置いて、もう一度お試しください。」** の通知が出ます（一度使った認可の途中の状態は、使い回せません）。
6. もう一度「LOG IN WITH GOOGLE」から、やり直せます。

この PR では、**ログイン済みであることの表示は確認できません**。ログイン済みかを返す API（`GET /api/state`。issue #12）と、スタジオの画面（`/studio`。issue #29）が、まだ無いためです。この時点で `http://localhost:3000/account` を開くと、「処理を完了できませんでした。時間を置いて、再試行してください。」のエラーの通知が出ます（状態の API が無いため）。ログインの成否は、手順 4 の `/studio` への移動と、手順 5 の失敗の通知で確かめます。
