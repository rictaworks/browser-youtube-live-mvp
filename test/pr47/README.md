# test/pr47

PR #47（issue #19「中継: FLV 多重化と RTMPS 送出（容器の詰め替え・送出先の検証・送出待ちの管理）」）のテストです。対象は開発サーバー（`scripts/dc.sh` 経由の docker compose の `relay` コンテナ）です。実際の YouTube へは接続しません（受け口は、テスト内で立てる go-rtmp のサーバー（TLS・自己署名）です）。

実装担当が書いた Go のテスト（`src/relay/internal/flv`・`src/relay/internal/rtmps`）に加えて、別の角度の確認（受け入れ条件の対応・ビルドとモジュール・走査・変異テスト）を、1 回で実行します。

```bash
scripts/setup_dev_env.sh                # .env を生成します（済んでいれば何も変わりません）
test/pr47/run_all.sh                # 手順 1〜14（変異テストを含む。二十数分）
test/pr47/run_all.sh --no-mutation  # 変異テストを省略します（省略は「省略」と数え、成功とはみなしません）
```

終了コード: 0 = すべて成功、1 = 失敗がある、2 = 準備ができていない（`.env` が無い・引数の誤り）。各手順のログは、`mktemp` で作る一時ディレクトリに残ります（削除しません。場所は実行の最初と最後に表示します）。変異テストが作る変異のファイルは、`src/relay/.cache/mutants/<実行ごとの名前>/`（gitignore 済み。削除しません）に残ります。

| 手順 | 確かめること |
|---|---|
| 1 | `scripts/test_relay.sh -race -count=1 ./internal/...`: gofmt の差分なし・`go vet`・`go test -race`（internal 全体）。issue の「品質」の受け入れ条件のコマンドです |
| 2 | `scripts/test_relay.sh -race -count=1 ./...`: モジュール全体（#18 の core・契約・main を含む）。この PR が、ほかのパッケージを壊していないこと |
| 3 | `-count=3 -shuffle=on`: 実行の順序・時間への依存が無いこと（ゴルーチン・タイマーを使う試験が、安定していること） |
| 4 | `go test -json` の結果を、ファイルへ書きます（次の手順の入力） |
| 5 | 4 の結果を、`acceptance_map.json`（issue の受け入れ条件 17 件 -> テスト関数）と突き合わせます（`check_acceptance.py`）。列挙したテストが、すべてソースにあり、成功し、スキップが 0 件であること |
| 6 | `CGO_ENABLED=0 GOOS=linux go build ./...`（本番と同じ静的リンク）・`go mod verify`・`go mod tidy -diff`（`go.mod`・`go.sum` が整っていること） |
| 7 | `docker build --target production src/relay`（CLAUDE.md の、中継の本番用イメージのビルド）。新しい依存（go-rtmp・go-flv）を含めて、`go mod download` と静的リンクのビルドが通ること |
| 8 | ファジング 10 秒: 送出先の検証（`FuzzValidate`。受理したものが、許可の規則をすべて満たすこと） |
| 9 | ファジング 10 秒: FLV の往復（`FuzzMuxerRoundTrip`） |
| 10 | 走査器（`scan_sources.py`）の自己検査。合成したソースで、違反を見逃さず、違反でないものを誤検知しないこと |
| 11 | 照合器（`check_acceptance.py`）の自己検査。合成した入力で、失敗・スキップ・実行されていないテスト・ソースに無いテスト・対応するテストの無い受け入れ条件を検出すること |
| 12 | 変異テストの仕組み（`mutate_relay.py`）の自己検査 |
| 13 | `scan_sources.py`: `internal/flv`・`internal/rtmps`・このディレクトリに、絵文字・不可視の書式文字（ゼロ幅スペースなど）・日本語以外の非 ASCII の文字・削除系の語（CI の hygiene と同じ規則を、コメントも含めて適用）が無く、UTF-8 として読めること。`go.mod` が `go-rtmp v0.0.7`・`go-flv v0.3.1` を、直接の依存として固定していること。`core` が `internal` を参照しないこと。Go のソースに実行権限が無く、試作の残りが無いこと |
| 14 | `mutate_relay.py`: 実装を 1 か所ずつ壊し（80 件超）、テストが必ず失敗することを確かめます。最初に、変異なし（同じ内容の差し替え）で、同じテストが成功することを確かめ、仕組みそのものが動いていることを示します。送出先の検証（スキーム・ポート・ユーザー情報・クエリ・ホスト・パス・開発用の許可）・配信キーの伏せ字・送出待ちの上限と閉じ方・接続の期限と切断の見張り・送り切ったあとのおだやかな切断（受け口が閉じるのを待つ）と後始末の期限・FLV の見出しと呼び出し順を、1 つずつ壊します |

## ユーザーから見える変更

ありません。中継の内部の部品（FLV 多重化・RTMPS 送出）の追加だけで、画面・HTTP・WebSocket の API は変わりません（`src/relay/main.go` へは、まだ結線しません。取り込みセッション（issue #20）・WebSocket（issue #21）が使います）。確認は、開発者が `scripts/test_relay.sh -race ./internal/...` と、このディレクトリの `run_all.sh` を実行して、緑になることです。

## 実装担当のテストの範囲（`src/relay/internal/`）

| ファイル | 内容 |
|---|---|
| `flv/muxer_test.go` | 見出しのバイト列（キーフレーム `17 01 00 00 00`・差分 `27 01 00 00 00`・設定 `17 00 ...`・音声 `AF 00`・`AF 01`）と、go-flv のデコーダでの往復・符号化データの無改変・入力と出力のメモリの非共有・onMetaData の 9 項目・復号器設定の検査・呼び出し順（準備ができるまで不可・再接続のあと再送）・並行・ファジング |
| `flv/rules_test.go` | 走査（ネットワーク・ファイル・時計・乱数・RTMP・ほかの層を参照しない。グローバル変数・日本語の直書きが無い）。走査器の自己検査つき |
| `rtmps/destination_test.go` | 送出先の検証 約 110 ケース（スキーム・ホスト・ポート・ユーザー情報・クエリ・パス・全角・パーセントエンコード）・開発用の許可（production に存在しない）・許可リストの注入・エラーが URL の内容を含まないこと・ファジング |
| `rtmps/streamkey_test.go` | 配信キー: どの書式動詞・JSON・slog でも伏せること・エラーに一部も含まないこと・JSON から読めること |
| `rtmps/publisher_test.go`・`fakesink_test.go`・`publisher_property_test.go` | 疑似の sink で、順序・非ブロッキング・送出待ちの幅（PendingMs の定義）・上限の境界（2,999・3,000・3,001 ms）・バイトの上限・Close の送り切り・期限切れ・後始末の期限（TeardownTimeout + CloseLinger）・Abort・切断の検知と分類（ErrPublishRejected・ErrDisconnected）・並行・ゴルーチンのリーク。性質の試験（固定のシードで 120 通りの操作列。届いたものは、受理した書き込みの先頭からの連続した部分であること、など） |
| `rtmps/publisher_integration_test.go`・`testserver_test.go` | go-rtmp の TLS のサーバーを受け口にして、Muxer の出力が、時刻つきで届くこと・送り切る Close・Close が受け口の閉じるのを待つこと（受け口の後始末を遅らせて確かめる）と待ちが有限であること・受け口の切断・publish の拒否・受け口が読み取りを止めたときの上限と Abort・並行・再接続・配信キーがエラー・ログに現れないこと |
| `rtmps/dial_test.go`・`killswitch_unix_test.go` | 接続の期限（RTMP のハンドシェイクに応じない受け口・TLS が止まる受け口・connect に応答が来ない受け口）・取り消し・切断の見張り・証明書の検証（信頼しない認証局・ホスト名の不一致・開発用だけ省略）・killSwitch（記述子の複製・shutdown・解放）・おだやかな切断（finish。読んでいない受信と送り残しがあっても、書いたすべてが相手に届き、終わりは EOF で RST にならないこと。待ちが有限であること。待つ間も shutdown を妨げないこと） |
| `rtmps/rules_test.go` | 走査（平文の RTMP を使わない・`InsecureSkipVerify` の置き場と値・配信キーの中身を得る呼び出しが 1 か所だけ・グローバル変数・日本語の直書き）。走査器の自己検査つき |

## 補足

- `go-rtmp`（v0.0.7）の制約への補い（接続の期限・ソケットの shutdown・単一の書き込みゴルーチン・切断の見張り）は、`src/relay/internal/rtmps/doc.go` にあります。応答が来ない受け口との接続の試行は、go-rtmp の仕様（`connect` が応答を待ち続ける）により、ゴルーチンを 1 つ残します。そのため、この種の試験は、ゴルーチンの数を、試験の前の値と比べます。
- 変異テストは、`go test -overlay` を使い、ソースのファイルを書き換えません。ソースを走査するテスト（`rules_test.go`）は、元のソースを読むので、変異は見えません（走査器の検出力は、合成したソースの自己検査で確かめます）。
