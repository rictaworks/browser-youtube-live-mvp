# test/pr50

PR #50（issue #10「YouTube 連携の窓口: TokenVault・YouTubeGateway（実物・疑似）・エラー対応・取り込み先の検証」）のテストです。対象は開発サーバー（`scripts/dc.sh` 経由の docker compose の backend コンテナと db コンテナ）です。

実際の Google・YouTube・本番へは、一度も接続しません（資格情報が無いためです）。実物の窓口は WebMock で HTTP を差し替えて検証し、疑似の窓口は開発環境の判定（`AppEnvironment#external_services` が `:fake`）で選ばれることを、通信の禁止のもとで確かめます。

この PR に、利用者が画面で確かめられる変更はありません（backend の内部の部品だけです）。そのため、確認は開発者が下のスクリプトで行います。実際の YouTube への接続は、#11 以降（接続・準備の実装）で初めて通ります。

```bash
scripts/setup_dev_env.sh                   # .env を生成します（済んでいれば何も変わりません）
test/pr50/run_all.sh                   # 手順 0〜8・10〜12（数分）
test/pr50/run_all.sh --with-mutation   # 手順 9（変異テスト。さらに数分）も実行します
```

終了コードは、成功が 0、失敗が 1、準備ができていない場合（`.env` が無い・引数の誤り・コンテナに入れない）が 2 です。各手順のログは、`mktemp` の場所に残ります（場所は実行の最初と最後に表示します）。スクリプトはファイルも DB も消しません。使い終わった `bl_test_issue10_*` の DB は、必要なら手動で整理してください。

## 手順

| 手順 | 確かめること |
|---|---|
| 0. コンテナの起動 | `scripts/dc.sh up -d --wait db backend`。db と backend が healthy になること |
| 1. RSpec と RuboCop | テスト用 DB を**実行のたびに新しい名前で作り**、`spec/gateways`・`spec/models`・`spec/sources` を実行します（この issue のスペックに加えて、設定の鍵の一覧を更新した #8 のスペックを含みます）。同時の操作・実際にコミットするスペックを含みます。`scripts/test_backend.sh` が呼ぶ、コンテナの中の同じスクリプトです |
| 2. eager_load を有効にした RSpec | 同じスペックを、CI（GitHub Actions）と同じ `CI=true`（Rails の eager_load を有効にする）で実行します |
| 3. backend 全体の回帰 | `scripts/test_backend.sh`（RSpec の全件・RuboCop の全体・Brakeman・bundler-audit） |
| 4. Zeitwerk の読み込み検査 | `bin/rails zeitwerk:check`。`YouTube` を含む定数（個別の指定を `config/initializers/zeitwerk_inflections.rb` に置いています）が、eager load ですべて読み込めること |
| 5. 使い捨ての DB を用意 | 手順 6・7 が使う DB（`<TEST_DB_NAME>_scratch`）に、スキーマを読み込みます。スキーマの書き出し先はコンテナの `/tmp` にして、コミット対象の `db/structure.sql` は書き換えません |
| 6. 受け入れの確認（`acceptance.rb`） | 黒箱です。RSpec を使わず、公開の API だけを呼び、issue の受け入れ条件を 87 項目、1 つずつ確かめます。結果は、SQL（台帳・接続の行）と WebMock の記録で、独立に確かめます（受け入れ条件との対応は、下の表）。実行ごとに割り当て日を変えるので、同じ DB で繰り返し実行できます |
| 7. 開発環境での通しの確認（`dev_flow_check.rb`） | `RAILS_ENV=development` で、環境の判定により疑似の窓口が選ばれ、配信の作成・ストリームの作成・紐づけ・5 秒後の `live`・完了への遷移まで、**通信を 1 回も試みずに**進むこと（通信の禁止は WebMock。禁止が働いていることは、対照の通信で確かめます）。失敗の注入が、要求ごとに作り直した窓口にも続くこと。本番の許可リストが疑似の取り込み口を通さず、本番では疑似を構築できないこと。ログに更新トークン・アクセストークン・配信キー・タイトル・暗号鍵が出ないこと |
| 8. 既存の画面 | 3 層のヘルスチェック（backend `/up`・frontend `/healthz`・relay `/health`）が 200 |
| 9. 変異テスト（`mutate_gateway.rb`。`--with-mutation` のとき） | コンテナの `/tmp` にアプリケーションの複製を作り、窓口の実装を 1 か所ずつ（62 通り）壊して、対応するスペックが失敗する（検出する）ことを確かめます。先に、変異なしの複製でスペックが通ることを確かめます（通らないスペックでの「検出」は、検出ではないためです）。共有の作業ツリーは書き換えません |
| 10. 走査器の自己検査 | `scan_sources.py --self-test`。合成したソースで、走査器が違反を見逃さず、違反でないものを誤検知しないこと |
| 11. ソースの走査 | `scan_sources.py`。この issue の成果物（`app/gateways` のこの issue のファイル・スペック・設定・このディレクトリ）に、絵文字・不可視の文字・削除系コマンドの語・資格情報の形式・暗号鍵らしい値（既知のダミー以外）が無いこと。秘密鍵のファイル（`*.pem`・`*.key`）が `src/backend` に無いこと。実行権限つきのファイルが無いこと（このディレクトリの起動用のスクリプトを除く） |
| 12. `structure.sql` の不変 | 実行の前後で、コミット対象の `db/structure.sql` が書き換わっていないこと |

## 変異テストの範囲（手順 9）

窓口の経路・呼び出しの表・要求と応答・エラーの分類・取り込み先の検証・TokenVault・接続の状態の遷移・疑似・実装の選択のそれぞれで、壊し方を決めています。主なものは次のとおりです。

- 窓口の経路: 枠が足りなくても HTTP を送る・記帳をアクセストークンの取得より前にする・割り当て超過の印を付けない（または UTC の日付に付ける）・共通枠の割り当て日を UTC にする・保存した識別子の確認を使わない・トランザクションの内側の検査を外す・401 でメモリ上のトークンを捨てない・壊れた gzip を受け止めない・タイムアウトの型を取り違える・接続と配信のアカウントの一致を見ない・3xx を成功にする・実時計を読む・標準出力やログへ書く・タイトルをログへ出す
- 呼び出しの表: 状態確認が終了・清算枠から支出できない・準備の呼び出しが終了・清算枠を取り崩せる・削除の単価を取り違える
- 要求と応答: `part` から `contentDetails` を落とす・自動停止やモニターの指定を変える・取り込み先に平文の RTMP を使う・取り込み先の検証を省く・配信キーの形の検査を緩める・応答と要求の識別子の一致を見ない・ストリームの健全性の警告の条件を広げる
- エラーの分類: `concurrentBroadcastsExceedLimit` を再試行の対象にする・404 を `NotFound` にしない・先行配信の清算の権限の応答を認可失効にする・符号の形でない `reason` をそのまま記録する・`NotAllowed` を清算済みとして扱う
- 取り込み先の検証: スキーム・ポート・ユーザー情報の検査を外す・疑似の取り込み口を本番でも許可する・アプリ名の形を緩める
- TokenVault: 更新の余裕（60 秒）・待っているあいだの更新の再利用・アカウントごとの排他・暗号文のアカウントへの結びつき・鍵の長さの検査・暗号方式（認証つきでないもの）・恒久／一時の失敗の状態の扱い・失効した接続への通信・接続の解除で保存したトークンを残す・キャッシュの期限の境界・5xx の `invalid_grant` の扱い
- 接続の状態の遷移: すでにその状態でも更新済みとする・ストリームの識別子が無くても破棄済みとする
- 疑似: `live` になる境界（ちょうど 5 秒）・`part` の尊重・認可ヘッダの検査・未知のパスの応答・失敗の注入の消費・疑似の窓口を本番で構築できる・本番で疑似を選ぶ

## issue #10 の受け入れ条件との対応

| 受け入れ条件 | 確かめる手順・スペック |
|---|---|
| `TokenVault#store`（AES-256-GCM・鍵の検査・アカウントに結びつく暗号文・平文と暗号文を出さない） | 1（`token_vault_spec.rb`）・6・9 |
| `TokenVault#access_token`（有効期限内のメモリ上の再利用・期限の 60 秒前の更新・永続化しない・スレッドセーフ・同時の更新の重複排除） | 1（`token_vault_spec.rb`・`access_token_cache_spec.rb`・`token_vault_concurrency_spec.rb`）・6・9 |
| 更新の恒久的な失敗は `TokenRevoked` で接続状態を `revoked` に・一時的な失敗は `TokenTemporarilyUnavailable` で状態を変えない | 1（`token_vault_spec.rb`・`google_token_client_spec.rb`）・6・9 |
| `TokenVault#revoke`（失効エンドポイントへ送り、成否にかかわらず保存したトークンを消し、結果を返す。メモリのアクセストークンも捨てる） | 1（`token_vault_spec.rb`・`google_token_client_spec.rb`）・6・9 |
| `YouTubeGateway` の 24.2 のメソッド 9 つが、1 つの経路（`call`）を通る・窓口を通さない HTTP が `app/` に無い | 1（`youtube_gateway_spec.rb`・`youtube_gateway_calls_spec.rb`・`youtube_gateway_sources_spec.rb`）・6 |
| 配信の作成内容（`part=snippet,contentDetails,status`・自動開始・自動停止・モニター無効・開始予定時刻は 1 分後）と、ストリームの作成内容（`part`・`rtmp`・`variable`・`isReusable`）・保存した識別子での確認（空の `items` も 404 も無効）・取り込み先は `rtmpsIngestionAddress` | 1（`youtube_gateway_spec.rb`・`fake_youtube_api_spec.rb`）・6・9 |
| 呼び出しのたびの記帳（単価・枠）・枠の不足は HTTP を呼ばず `QuotaInsufficient`・HTTP の失敗でも実費を記帳・記帳は HTTP の前に独立して確定 | 1（`youtube_gateway_ledger_spec.rb`・`youtube_gateway_commit_spec.rb`・`youtube_gateway_calls_spec.rb`）・6・7・9 |
| `quotaExceeded` は `mark_exhausted!` を呼び `QuotaExceeded` | 1（`youtube_gateway_ledger_spec.rb`）・6・9 |
| `IngestDestination.validate!`（RTMPS・許可ホスト・ポート 443・ユーザー情報とクエリの拒否・`ensure_stream` が返す前に検証・疑似の取り込み口は開発とテストだけ） | 1（`ingest_destination_spec.rb`・`youtube_gateway_spec.rb`）・6・7・9 |
| 配信キーをログ・例外・台帳の明細・`inspect` に出さない | 1（`youtube_values_spec.rb`・`youtube_gateway_sources_spec.rb`・各スペックのログの検査）・6・7・9 |
| エラーの分類（`reason` の表引き・全種・`disposition`・未知の `reason` は `UnexpectedResponse`）・`YouTubeStatus` の 8 値と「存在しない」・ストリームの健全性（`bad` または `error` のときだけ警告） | 1（`youtube_errors_spec.rb`・`youtube_gateway_errors_spec.rb`・`youtube_status_spec.rb`・`youtube_values_spec.rb`）・6・9 |
| 状態の遷移は `YouTubeConnection` のメソッドで行い、窓口は状態を変えない・先行配信の清算での権限の応答は認可失効にしない | 1（`youtube_connection_transitions_spec.rb`・`youtube_gateway_errors_spec.rb`・`youtube_errors_spec.rb`）・6・7・9 |
| `FakeYouTubeGateway`（決定的な識別子・開発用の取り込み口・状態の遷移と 5 秒・失敗の注入・台帳へ同じ単価で記帳・本番では構築できない） | 1（`fake_youtube_api_spec.rb`・`fake_youtube_gateway_spec.rb`・`fake_google_token_client_spec.rb`）・6・7・9 |
| `AppEnvironment#external_services` が `:fake` なら疑似、`:live` なら実物（本番で疑似を選ばない・資格情報が欠ければ疑似へ倒さず例外） | 1（`youtube_services_spec.rb`）・6・7・9 |
| WebMock で、API の応答の形・呼び出しの順序・パラメータ・認可ヘッダ・記帳・`quotaExceeded`・エラー分類の全種を検査 | 1・6 |
| RSpec・RuboCop・Brakeman が緑 | 1〜3 |

## 実装担当のスペックの範囲

| ファイル | 内容 |
|---|---|
| `spec/gateways/youtube_gateway_spec.rb` | 実物の窓口（WebMock）。9 つのメソッドの要求（`part`・本文・認可ヘッダ）と応答の解釈、`ensure_stream` の再利用と作成、取り込み先の検証、接続時の確認 |
| `spec/gateways/youtube_gateway_calls_spec.rb` | 呼び出しの閉じた表（単価の出どころ・枠）。終了・清算枠を使えるのは、状態確認・完了への遷移・削除だけ |
| `spec/gateways/youtube_gateway_ledger_spec.rb` | 台帳への記帳、枠の不足で HTTP を呼ばないこと、超過の印、トークンの取得 -> 記帳 -> HTTP の順序、トランザクションの内側での拒否 |
| `spec/gateways/youtube_gateway_commit_spec.rb` | 実際にコミットする。HTTP の時点で記帳が別の接続から見えること、HTTP の待ちのあいだ行ロックを持たないこと、失敗しても記帳が残ること、同時の呼び出しで記帳が失われないこと |
| `spec/gateways/youtube_gateway_errors_spec.rb` | 全公開メソッドが同じ経路で分類すること、窓口が接続の状態を変えないこと、清算の結果へ直接写せること |
| `spec/gateways/youtube_errors_spec.rb` | `reason` の表引き（全種）、`disposition`、未知の `reason`、秘密を出さないこと |
| `spec/gateways/youtube_status_spec.rb`・`youtube_values_spec.rb` | `YouTubeStatus` の 8 値と「存在しない」、`StreamInfo`・`StreamHealth`・`ProbeResult`・`UnstartedBroadcast`（秘密を `inspect`・`to_s` に出さない） |
| `spec/gateways/ingest_destination_spec.rb` | 取り込み先の許可と拒否の表（スキーム・ホスト・ポート・ユーザー情報・クエリ・フラグメント・アプリ名の形） |
| `spec/gateways/token_vault_spec.rb` | 暗号化の往復、鍵違い、アカウントへの結びつき、再利用と 60 秒前の更新、恒久／一時の失敗、失効（`revoke`）、秘密がログに出ないこと |
| `spec/gateways/token_vault_concurrency_spec.rb` | 同時の更新の重複排除（別のインスタンスからでも 1 回）、別のアカウントの並行、恒久的な失敗の伝わり方 |
| `spec/gateways/access_token_cache_spec.rb` | キャッシュの期限の境界、アカウントごとの排他 |
| `spec/gateways/google_token_client_spec.rb`・`fake_google_token_client_spec.rb` | トークンエンドポイントとの通信（更新・失効）と、その疑似 |
| `spec/gateways/fake_youtube_api_spec.rb`・`fake_youtube_gateway_spec.rb` | 疑似の YouTube の応答の形と状態の遷移、疑似の窓口が実物と同じ経路を通ること、失敗の注入 |
| `spec/gateways/youtube_services_spec.rb` | 環境の判定による実装の選択（開発・テストは疑似、本番は実物。資格情報が欠ければ例外） |
| `spec/gateways/external_services_spec.rb` | #8 のスペック。設定の鍵の一覧に、この issue の追記（`google_oidc` の `revoke_endpoint` と、`youtube` の節）を反映 |
| `spec/models/youtube_connection_transitions_spec.rb` | `mark_connected!`・`mark_live_not_enabled!`・`mark_revoked!`・`discard_stream!`（所有者を限った一括の更新・すでにその状態なら false） |
| `spec/sources/youtube_gateway_sources_spec.rb` | `app/` の走査（字句解析）。YouTube への HTTP は窓口の 1 か所だけ、台帳への支出は窓口だけ、実時計・標準出力・日本語の直書き・秘密のログ出力が無いこと |

補助は `spec/support/youtube_gateway_support.rb`（明らかなダミーの値・接続と配信の組み立て・API の応答の形の組み立て）です。

## 環境変数（任意）

| 変数 | 内容 |
|---|---|
| `TEST_DB_NAME` | 手順 1〜4 のテスト用 DB の名前。既定は `bl_test_issue10_<日時>`（実行のたびに新しい名前）。`bl_test_` で始まる名前に限ります（開発 DB は使えません） |
| `SCRATCH_DB_NAME` | 手順 5〜7 の使い捨ての DB の名前（既定 `<TEST_DB_NAME>_scratch`） |
| `MUTATION_DB_NAME` | 手順 9 の使い捨ての DB の名前（既定 `<TEST_DB_NAME>_mut`） |
| `STEP_TIMEOUT` | 1 手順の上限の秒数（既定 900。全件の回帰は 1500、変異テストは 2400） |

## ファイル

| ファイル | 内容 |
|---|---|
| `run_all.sh` | 1 回で実行する入口です。手順ごとにログを残し、最後に結果の一覧を表示します |
| `acceptance.rb` | 手順 6。`bundle exec ruby -` へ標準入力で渡します（`RAILS_ENV=test` と使い捨ての DB の URL は、`run_all.sh` が与えます） |
| `dev_flow_check.rb` | 手順 7。同じく標準入力で渡します（`RAILS_ENV=development` と使い捨ての DB の URL は、`run_all.sh` が与えます） |
| `mutate_gateway.rb` | 手順 9。コンテナの `ruby` へ標準入力で渡します |
| `scan_sources.py` | 手順 10・11。`--self-test` で自己検査、引数にリポジトリのルートを渡すと走査します |

## 安全

- 開発 DB（`bl_development`）は使いません。受け入れの確認・通しの確認・変異テストは、`bl_test_` で始まる使い捨ての DB を作って使います。コンテナの `DATABASE_URL` が開発 DB を指していることを確かめてから、DB の名前だけを差し替えます。
- 実際の Google・YouTube へは接続しません。受け入れの確認と通しの確認は、WebMock で、差し替えていない通信を失敗にします。
- トークン・配信キー・タイトルには、明らかなダミーの値だけを使います。ログの検査は、これらの値が出力に現れないことを確かめます。
- 自己再帰のガード・プロセス数の上限（`ulimit -u`）・各手順の `timeout` を置いています。ファイルも DB も消しません。
