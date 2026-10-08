# test/pr54

PR #54（issue #11「YouTube 接続: 段階的な認可・接続時の確認・再確認・チャンネル名のメモリ保持」）のテストです。対象は開発サーバー（`scripts/dc.sh` 経由の docker compose と、ホストの `localhost`）です。

実装担当が書いたテスト（`src/backend/spec/` の RSpec）を、起動時の検査・実サーバー・フロントエンドの同一オリジン中継・実ブラウザ・本番の起動の検査・変異の確認と合わせて、1 回で実行します。

```bash
scripts/setup_dev_env.sh      # .env を生成します（済んでいれば何も変わりません）
test/pr54/run_all.sh      # すべて（十数分かかります。RSpec が 2 回、変異の確認が長い）
RUN_ALL_ONLY=zeitwerk,scan test/pr54/run_all.sh   # 手順を選んで実行します（名前は下の表）
```

終了コードは、成功が 0、失敗が 1、前提を満たさない場合が 2 です。SKIP（確認できなかった）は成功に数えず、件数を表示します（Playwright が無いとき、実ブラウザの確認が SKIP になります）。

## 手順

| 手順（`RUN_ALL_ONLY` の名前） | 確かめること |
|---|---|
| 1. RSpec と RuboCop（`rspec`） | この issue のスペックと、変更した基盤（頻度制限・疑似の Google・外部サービスの選択・ルート）のスペック（`spec/config`・`spec/gateways`・`spec/requests`・`spec/services`・`spec/sources`）。テスト用 DB は `bl_test_issue11_run`（`TEST_DB_NAME` で変えられる）。実際の Google・YouTube・reCAPTCHA を呼ばない（疑似の実装と WebMock） |
| 2. `CI=true`（`rspec_ci`） | 同じスペックを、eager_load を有効にして実行します（CI と同じ。読み込みの誤りを見つけます） |
| 3. RuboCop（`rubocop`） | アプリケーション・config のファイル |
| 4. Zeitwerk（`zeitwerk`） | `bin/rails zeitwerk:check`（`YouTubeConnectService` の大文字小文字の対応を含む） |
| 5. Brakeman（`brakeman`） | 静的解析の警告 0 件（backend 全体） |
| 6. bundler-audit（`audit`） | 既知の脆弱性が無い |
| 7. `check_startup_key.sh`（`startup_key`） | **起動時の検査**（#10 のレビューの申し送り）。`TOKEN_ENCRYPTION_KEY` が設定されていて形式が誤りなら、開発・テスト・本番のすべてで起動に失敗する／メッセージは変数の名前と期待する形式だけ（値を書かない）／形式が正しければ（大文字の 16 進数も）起動できる／開発での未設定・空・空白だけは通す／本番での未設定・誤りは必須の環境変数の検査が止める |
| 8. `live_server_check.rb`（`live`） | **実サーバー（Puma）** に対して、HTTP で、疑似の Google・疑似の YouTube での接続の全体を確かめます（59 項目）。`connect/start`（BFF の確認・ログイン・CSRF・入力・bot 判定・認可 URL の中身（スコープは youtube の 1 種・`offline`・`consent`・`login_hint`・S256。`include_granted_scopes` と `nonce` は無い）・`bl_oauth` の属性）・疑似の同意画面（選択肢 7 つ。不正な要求は 422）・成立（302 `/account?connect=connected`・暗号文だけを保存・測定イベント）・再接続（暗号文の置き換え・配信用ストリームの識別子の破棄）・不成立（権限の部分拒否・更新トークンなし・チャンネルなし・確認不能・拒否。接続の行を作らない・Google 側の失効・既存の接続は変更しない）・コールバックの検査（state の不一致・`bl_oauth` なし・別のアカウント）・測定イベントは、ログイン中のアカウントが開始した接続（有効な `bl_oauth`）だけ記録すること（匿名・`bl_oauth` なし・でたらめな要求を何度送っても、行が増えない）・再確認（200・直後は 429・接続なしは 409・認可失効は 200）・頻度制限（31 回目で 429）・ログに state・認可コード・`bl_oauth`・セッションの識別子・トークン・チャンネル名・IP が出ないこと |
| 9. `curl_bff_check.sh`（`curl`） | ホストの `curl` から、**フロントエンドの同一オリジン中継（`http://localhost:3000`）を通して**、同じ流れを確かめます（35 項目。Cookie の入れ物で受け渡し）。`Set-Cookie`（`bl_oauth` の `HttpOnly`・`SameSite=Lax`・`Max-Age=600`）・`Location` が、中継を通って欠落なく届くこと。バックエンドのドメインが、応答に出ないこと |
| 10. `browser_flow_check.cjs`（`browser`） | **実ブラウザ（Playwright の Chromium）** で、ランディングの「LOG IN WITH GOOGLE」からログインし、認可 URL を開く → 疑似の同意画面（見出し Google・選択肢 7 つ）→ 選択 → 戻り先 → `/account?connect=…` の遷移を確かめます（27 項目）。`bl_oauth` が残らないこと、戻る操作での再選択が `connect=unverifiable` になること、外部のドメインへ通信しないこと、画面・URL・`document.cookie` にトークンが出ないこと。スクリーンショットは `ARTIFACT_DIR` へ。**ブラウザの画面の「YouTube を接続」のボタンは、状態の API（`GET /api/state`。#12）ができるまで出ない**ため、ボタンが呼ぶ API は、ページの中の `fetch`（同じ手順の CSRF つき POST）で呼びます |
| 11. `check_production.sh`（`production`） | **本番（`RAILS_ENV=production`）の起動の検査**（コンテナの中。DB・外部サービスへは接続しません）。YouTube 接続の手続きが実物（`GoogleOidcClient`・`YouTubeGateway`・`TokenVault`）で組み立つ／疑似は構築できない／実物の認可 URL（`accounts.google.com`・スコープは youtube の 1 種・`offline`・`consent`・PKCE。`include_granted_scopes` と `nonce` は無い）／疑似の同意画面の経路（`/api/dev/`）が無く 404／接続の経路はある／ログインの方針が宣言されている ほか（13 項目）。開発では疑似が選ばれること |
| 12. `mutation_check.sh`（`mutation`） | **変異の確認**。アプリケーションの 1 か所（state の照合・アカウントの照合・`error` の扱い・権限と更新トークンの判定・不成立のトークンの失効（既存の接続があるとき失効させない）・成立の保存の原子性・行ロックの順序・ストリームの識別子の破棄・disposition の扱い・認可失効の再確認・チャンネル名のキャッシュ（期限・境界・アカウントの分離・永続化・失敗の否定キャッシュ）・空白だけのチャンネル名の扱い・想定外の例外のときの受け取ったトークンの破棄・測定イベントを記録する条件（匿名・開始していない要求は記録しない）・pp の表記・ログのフィルタ（`login_hint`）・再確認の門の消費と共通枠・頻度制限・bot 判定・`bl_oauth` の失効・公開オリジンへの戻り・認可 URL の項目・PKCE の検証子・クライアントの秘密値・疑似のコード交換の検証・疑似の同意画面の戻り先の検査 ほか）を、実行中のプロセスの中で壊し、該当するスペックが落ちることを確かめます。基準（変異なし）が緑であることも確かめます。**変異の定義の誤り（定数の書き損じなど）で落ちたものは、「落ちた」と数えず、失敗にします。** 既定は重要な 44 件（`MUTATION_SET=all` で 74 件）。`MUTATION_ONLY=名前,名前` で選べます |
| 13・14. `scan_sources.py`（`scan_selftest`・`scan`） | この issue の成果物とこのディレクトリに、絵文字・不可視の文字・削除系コマンド・機密の直書き（秘密鍵・クラウドの鍵・Google のトークンの実物の形・長い 16 進数の秘密値の代入）・秘密鍵のファイル（`*.pem`・`*.key`）が無い（走査器の自己検査つき） |

## issue #11 の受け入れ条件との対応

| 受け入れ条件 | 確かめる手順 |
|---|---|
| `connect/start`: ログイン必須・CSRF・入力の検査 → 進行中の配信は 409 `broadcast_in_progress` → IP 単位 30 回／時（31 回目で 429・`retry_at`）→ bot 判定（行為名 `youtube_connect`）→ 認可 URL（youtube の 1 種・`offline`・`consent`・`login_hint`・PKCE・state。`include_granted_scopes` と `nonce` は無い）。`bl_oauth` に用途 `connect` と内部のアカウント識別子。`connect_started` | 1・2・8・9・10・11・12 |
| `connect/callback`: `bl_oauth`（用途 `connect`）の state の照合・ログイン中のセッションのアカウントとの一致（不一致は不成立）・コードの交換 | 1・8・9・10・12 |
| 判定（7.2 の表）: スコープに youtube が無い → `scope_denied`／更新トークンなし → `no_refresh_token`／チャンネルなし → `no_channel`／ライブ未有効 → `live_not_enabled`／確認不能 → `unverifiable`。確認は 1 ユニットの一覧取得 2 回で、共通枠から支出（共通枠が尽きていれば `unverifiable`） | 1・8・9・10・12 |
| 成立: 更新トークンを暗号化して保存（`TokenVault`）・`youtube_connections` の作成または更新・**保存済みの配信用ストリームの識別子を成立のたびに破棄**（10.5）・チャンネル名をメモリに置く・302 `/account?connect=connected｜live_not_enabled`・`connect_completed` | 1・8・9・10・12 |
| 不成立: トークンを保存せず破棄・**既存の接続が無い場合に限り Google 側でも失効**・既存の接続の状態・トークン・ストリームの識別子を変更しない・302 `/account?connect=<結果>`・`connect_failed`（理由の符号のみ） | 1・8・9・10・12 |
| 外部呼び出しの失敗時も、トークン・コード・チャンネル名をログへ出さない | 1・8・12 |
| `recheck`: ログイン必須・CSRF・アカウント単位 1 分に 1 回・1 日 20 回（超過は 429・`retry_at`）・接続なしは 409 `not_connected`・認可失効は 200（`state: revoked`）・接続済み／ライブ未有効は再確認して `connected` ⇄ `live_not_enabled` を更新・確認不能は 503 `unverifiable` で状態を変えない・更新の恒久的な失敗や権限の不足は `revoked` | 1・8・9・12 |
| 日付またぎ: 共通枠が尽きた日は当該割り当て日の終わりまで受け付けない（夏時間を含む）。`RecheckGate#next_allowed_at(user)` | 1・12 |
| `ChannelNameCache`: プロセス内メモリのみ・取得から最長 10 分（時計は注入）・永続化しない（DB・ログ・`Rails.cache`）・スレッドセーフ・アカウント単位・破棄できる。`fetch` で再取得を省く。`YouTubeConnectService#channel_title(user)`（失敗は `nil`＋記録） | 1・2・12 |
| テスト: 接続の全分岐と 25.4 の各矢印・不成立で既存の接続が変更されない・既存の接続が無いときだけ失効・再接続でのストリームの識別子の破棄・再確認の頻度制限と日付またぎ・2 アカウントで影響しない・暗号化した更新トークンのみ保存（アクセストークン・チャンネル名が DB に無い）・チャンネル名の 10 分の失効 | 1・2・8・12 |
| RSpec・RuboCop・Brakeman が緑 | 1〜6 |
| 差し戻し R1: `connect/callback` の測定イベントは、**ログイン中のアカウントが開始した接続（そのアカウントの有効な `bl_oauth`）だけ**記録する。匿名の要求・`bl_oauth` が無い／無効・ほかのアカウントの `bl_oauth` は、302 `unverifiable` とログは今のままで、DB へ書き込まない | 1・2・8・12 |
| 差し戻し S1: `channel_title` の失敗を短時間（`config/youtube_connect.yml`。60 秒）だけ覚え、その間は YouTube を呼ばない（`ChannelNameCache` の否定キャッシュ。永続化しない・アカウントごと・`delete` で消える） | 1・2・12 |
| 差し戻し S2: `login_hint` を、ログから除くパラメータへ足す | 1・2・8・12 |
| 差し戻し S3: `Start`・`Verdict`・`ChannelNameCache::Entry` の `pp`・`pretty_inspect` に、値を出さない | 1・2・12 |
| 差し戻し S4: 空・空白だけのチャンネル名は、取得できなかったものとして扱う（接続は成立のまま。500 にしない） | 1・2・12 |
| 差し戻し S5: コード交換のあとの想定外の例外でも、成立（保存）しなかったときは、受け取ったトークンを破棄する（既存の接続が無ければ Google 側で失効）。保存が済んだあとの例外では失効させない | 1・2・12 |
| #10 の申し送り: `TOKEN_ENCRYPTION_KEY` の形式の起動時の検査／接続の行ロックを持ったまま `TokenVault` を呼ばない（デッドロックしない）／窓口はトランザクションの外で呼ぶ／不成立のトークンを台帳の外で失効させる口 | 1・2・7・11・12 |

## 注意

- **ブラウザの画面から「YouTube を接続」を押す操作は、この PR ではできません。** アカウント画面（#23）は完了済みで、ボタンの部品は main にあります。画面に出ないのは、接続状態を返す API（`GET /api/state`。#12）がまだ無いためです。この時点で `http://localhost:3000/account` を開くと、「処理を完了できませんでした。時間を置いて、再試行してください。」のエラーの通知だけが出ます。この PR の確認は、API を直接呼ぶ手順 8・9・10 が担います（手順 10 は、ボタンの代わりに、ページの中から同じ API を呼び、以降はブラウザの実際の遷移に任せます）。
- 実際の Google・YouTube は呼びません（疑似）。実物の Google の同意画面・実物の YouTube の応答は、確認できていません（OAuth クライアントの発行は本人の作業。CLAUDE.md の U6）。`login_hint` に `sub` を渡すことは、Google の公式ドキュメントの記載に基づきます（issue の備考。事前確認済み）。
- 開発 DB には、手順 8・9・10 で、アカウント `dummy-live-check-*`・`dummy-curl-check-*` などのダミーのアカウント・接続・測定イベント・台帳の明細（共通枠の消費）が作られます。実行のたびに新しい名前です。共通枠の消費は、開発 DB の当日の台帳に残ります。
- 手順 8 の前に、backend が古いコード（YouTube 接続の経路が無い）のときだけ、`scripts/dc.sh restart backend` を実行します（healthy になるまで待ちます）。共有の開発環境なので、ほかの担当の作業中は、短時間の再起動になります。
- **テスト用 DB に、強制終了した実行が、コミット済みの行を残すことがあります。** 同時の操作のスペック（`youtube_connect_service_concurrency_spec.rb`）は、各例の前後で自分の作った行を整理しますが、実行が途中で打ち切られると、その行が残り、ほかのスペックの「接続の行は 0 件」の確認が落ちます。そのときは `TEST_DB_NAME` を新しい名前（例: `bl_test_issue11_run2`）に変えてください（無ければ自動で作られます）。
- 手順 12 の `service_lock_before_store`（接続の行をロックしてから `TokenVault` を呼ぶ、行ロックの順序の誤り）は、Ruby の排他と DB の行ロックの待ち合い（デッドロック）になります。同時の操作のスペックは、各スレッドの接続に行ロックの待ちの上限（PostgreSQL の `lock_timeout`、10 秒）を設けているため、止まらずに `ActiveRecord::LockWaitTimeout` で落ちます（ほかの変異より 10 秒ほど長くかかります）。上限が無いと、スペックが止まり、例の後の整理が終わらず、コミット済みの行が残ります。

## 環境変数（任意）

| 変数 | 内容 |
|---|---|
| `TEST_DB_NAME` | 手順 1・2・4・12 のテスト用 DB の名前（既定 `bl_test_issue11_run`）。`bl_test_` で始まる名前に限ります（開発 DB は使えません） |
| `RUN_ALL_ONLY` | 実行する手順の名前（カンマ区切り）。`rspec`・`rspec_ci`・`rubocop`・`zeitwerk`・`brakeman`・`audit`・`startup_key`・`live`・`curl`・`browser`・`production`・`mutation`・`scan_selftest`・`scan` |
| `MUTATION_SET` | `key`（既定）または `all` |
| `MUTATION_ONLY` / `SKIP_BASELINE` | `mutation_check.sh` を単独で動かすとき。変異の名前（カンマ区切り）／基準を省く（`1`） |
| `PLAYWRIGHT_DIR` | playwright のディレクトリ（無ければ、npx のキャッシュなどから探します） |
| `ARTIFACT_DIR` | 手順 10 のスクリーンショットの置き場 |
| `FRONTEND_PORT` | フロントエンドのポート（既定 3000） |
| `STEP_TIMEOUT` | 1 手順の上限の秒数（既定 900。変異の確認だけ 2400） |

## 安全上の約束

- ファイルも DB も削除しません。作業用の一時ファイルは `mktemp` の場所に残します（最後に場所を表示します）。使い終わった DB・Cookie の入れ物は、必要なら手動で削除してください。
- 実際の Google・YouTube・reCAPTCHA・本番へは接続しません（疑似・WebMock・コンテナの中だけ）。秘密値（`.env`）は、画面へ出しません。
- ハーネスの安全（`.claude/TEST-HARNESS-SAFETY.md`）: 自己再帰ガード（TH1。`ISSUE11_RUN_ALL_ACTIVE`）・`ulimit -u`・各手順の `timeout`（TH3）。
- このディレクトリのソースに、削除系コマンドの語と絵文字を書きません（CI の hygiene が検査します。語を書く必要がある走査器は、語を分けて組み立てます）。

## ユーザーテスト手順（非エンジニア向け）

PR の本文にあります。開発環境での操作です。実際の Google ログイン・実際の YouTube への接続は、本番のみです（OAuth クライアントの発行が要ります）。この PR は API が中心で、**アカウント画面の「YouTube を接続」のボタンは、まだ出ません**（アカウント画面〔#23〕は完了済みで、画面に出ないのは接続状態の API〔#12〕がまだ無いためです）。次の手順は、いまの画面でできることだけを書いています。

1. 開発サーバーを起動します（`scripts/dc.sh up -d --wait`）。
2. ブラウザで `http://localhost:3000/` を開き、「LOG IN WITH GOOGLE」から `dev-user-1` を選んでログインします。`/studio` は、まだ画面が無いため、「ページが見つかりません」の画面が出ます（想定どおりです。ログインのあとに戻れたことを表します）。
3. `http://localhost:3000/account` を開きます。「処理を完了できませんでした。時間を置いて、再試行してください。」のエラーの通知だけが出ます（接続状態の API ができるまでの想定どおりの表示です）。
4. 接続の流れは、ブラウザの自動操作の確認で見ます。`PLAYWRIGHT_DIR=<playwright のディレクトリ> ARTIFACT_DIR=<保存先> node test/pr54/browser_flow_check.cjs --repo .` を実行し、最後に「確認 27 項目、失敗 0 項目」と表示されること、保存先のスクリーンショット（`1_consent.png` = 疑似の同意画面に選択肢が 7 つ並ぶ画面、`2_account.png` = 成立のあとのアカウント画面）を確認します。
5. 疑似の同意画面の選択肢は、`allow`（成立）・`allow_live_not_enabled`（ライブ配信が有効でない）・`allow_no_channel`（チャンネルがない）・`allow_unverifiable`（確認できない）・`allow_without_youtube`（YouTube の権限を許可しなかった）・`allow_without_refresh_token`（更新トークンが渡されなかった）・`deny`（拒否）です。それぞれ、`/account?connect=` に `connected`・`live_not_enabled`・`no_channel`・`unverifiable`・`scope_denied`・`no_refresh_token`・`scope_denied` が付いて戻ります。

「YouTube を接続」を押して選択肢を選ぶ操作は、#12 が入ったあとの PR で、ブラウザの画面から行えるようになります。
