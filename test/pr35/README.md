# test/pr35

PR #35（issue #3「契約: HTTP API・内部通信・WebSocket 転送プロトコル・共有定数と各層の定数モジュール」）のテストです。対象は開発サーバー（`scripts/dc.sh` 経由の docker compose）です。

実装担当が書いたテスト（契約の `node --test` 1,013 件、Ruby 333 件、TypeScript 194 件、Go）を、層をまたいで 1 回で実行します。

```bash
scripts/setup_dev_env.sh   # .env を生成します（済んでいれば何も変わりません）
test/pr35/run_all.sh
```

| 手順 | 確かめること |
|---|---|
| `scripts/test_contracts.sh` | 20.4 のマスタデータの件数・符号の重複なし・拒否理由 14 種の網羅・共有ベクタの自己整合（ヘッダの各欄と本文長を独立に再計算） |
| `scripts/test_backend.sh --no-db spec/domain/contract` | Ruby の定数モジュールが契約の JSON と一致する（Rails を起動しない） |
| `scripts/test_frontend.sh core/contract` | TypeScript の定数モジュールが契約の JSON と一致する |
| `scripts/test_relay.sh ./core/contract/...` | Go の定数パッケージが契約の JSON と一致する |
| `scan_contract_files.py` | 契約の文書・データ・定数モジュールに、絵文字と削除系コマンドの実行形が無い |

ユーザー（ブラウザ）から見える変更はありません。PR の本文に、開発者向けの確認手順があります。
