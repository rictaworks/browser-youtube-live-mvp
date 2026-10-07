# test/pr41

PR #41（issue #6「アプリケーション Domain Core（2）: 配信の状態遷移・期限の評価・終了処理・清算・先行配信の清算確認・ストリームの取り替え」）のテストです。対象は開発サーバー（`scripts/dc.sh` 経由の docker compose）です。

配信レコードの生命周期の規則を、入出力に依存しない純粋な Ruby として実装した PR です。Rails も DB も使いません。ユーザー（ブラウザ）から見える変更はありません。

```bash
scripts/setup_dev_env.sh   # .env を生成します（済んでいれば何も変わりません）
test/pr41/run_all.sh
```

終了コードが 0 なら成功です。各手順に `timeout` を付け、`ulimit -u` でプロセス数の上限を設けます（`.claude/TEST-HARNESS-SAFETY.md`）。`run_all.sh` は、自分自身を再帰的に起動しません。ファイルは削除しません。

| 手順 | 確かめること |
|---|---|
| `scripts/test_backend.sh --no-db spec/domain/lifecycle` | 実装担当の RSpec（759 件）と、そのスペックの RuboCop。25.1 の遷移表を 1 本ずつ（定義のある 35 本と、残りの 73 組が状態を変えないこと）、13.2 の期限の各行の境界（1 秒前・ちょうど・1 秒後）、全状態 × 通知なしで有限時間に終端へ進むこと、清算・先行配信の清算確認・ストリームの取り替え・保持期間 |
| `bin/rubocop`（Domain Core の 11 ファイル） | `app/domain/` の、この PR のファイルの書式 |
| `scan_text_hygiene.py` | 変更ファイルとこのディレクトリに、絵文字と削除系コマンドの語が無い（CI の hygiene と同じ種類の語を、より厳しく検査） |
| `check_domain_purity.rb` | Domain Core の規則。入出力の型（Rails・ActiveRecord・ActionController・ENV）と実時計（`Time.now` など）を参照しない・#5 の Domain Core に依存しない・期限や回数の数値と、状態・終了理由などの符号を直書きしない（契約から取る）・文字列リテラルは ASCII だけ・グローバル変数を使わない。Ripper で、コメントを除いたコードを検査します |
| `check_acceptance.rb` | issue の受け入れ条件を、公開された API だけで独立に確かめます。件数・到達性・網羅・不変の性質（遷移 35 本・130 通りの終了処理・13.2 の全行の境界・清算の 1・2・4 分の再試行・51 ユニット・先行配信の清算確認の予算・保持期間など） |
| `simulate_no_notification.rb` | 全状態 × 通知なし。事象を一切与えずに時刻だけを進め、期限の評価の指示を状態へ反映して、すべての配信が有限時間で終了し、清算が終端（不要・清算済み・清算不能）に達することを確かめます。13.2 の表の期限どおりに終了すること、清算の経過、乱数（種を固定）で作った 600 の配信 |

`check_domain_purity.rb`・`check_acceptance.rb`・`simulate_no_notification.rb` は、backend のコンテナの中で、標準入力から実行します（コンテナへ `test/` を渡していないため）。

```bash
scripts/dc.sh exec -T backend bundle exec ruby - < test/pr41/check_acceptance.rb
```

PR の本文に、開発者向けの確認手順があります。
