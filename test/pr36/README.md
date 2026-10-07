# test/pr36

PR #36（issue #22「フロントエンド基盤: デザイントークン・共通レイアウト・文言カタログ・共通部品・利用規約とプライバシーポリシー」）のテストです。対象は開発サーバー（`scripts/dc.sh` 経由の docker compose。ホストの `localhost`）です。

```bash
scripts/setup_dev_env.sh      # .env を生成します（済んでいれば何も変わりません）
test/pr36/run_all.sh          # すべて（初回は、パッケージとフォントの取得で数分かかります）
test/pr36/run_all.sh --stop   # 最後に scripts/dc.sh stop で止めます
```

| 手順 | 確かめること |
|---|---|
| `scripts/test_frontend.sh` | ESLint・`tsc --noEmit`・Jest（実装担当の 760 件超：配色のコントラスト比・文言カタログのキーと未使用・日本語のハードコードの検知・絵文字・`alert`／`confirm`／`prompt` の検知・部品の状態・キーボード操作・`aria`・各画面） |
| `npm run build` | 本番ビルド（`next/font/google` による 3 書体の自己ホスト。取得できなければ失敗する） |
| curl の smoke | `/terms`・`/privacy` が 200・`lang="ja"`・ページごとの `<title>`・フッターに 2 つのリンク・外部の CDN（フォント・アイコン）を参照しない・連絡先 `info@rictaworks.jp`、存在しないページが 404 でフッター付き、`/healthz` が従来どおり |

実ブラウザでの確認（フォントの描画・Tab キーでのフォーカスの輪郭・狭い表示幅の 1 カラム）は、PR の本文のユーザーテスト手順にあります（実装担当は、Chromium 153 で axe-core・W3C Nu validator・表示幅 375〜1440 px を確認済み）。

ユーザーテストのログインは、この PR にはまだありません（ランディングとログインは #23）。
