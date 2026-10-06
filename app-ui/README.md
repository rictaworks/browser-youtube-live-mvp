# app-ui — 画面モック

`src/` へ再現するための画面モック（図案）。仕様書ではなく、見た目の正本として扱う。仕様は `requirements.md` が正で、食い違いを見つけたら `requirements.md` に従い、モックを直す。

## 出どころ

Claude Design のプロジェクト「browser-youtube-live-mvp モック」（デザインシステムは `veyra-gemini`）から、ファイルの内容をそのまま写した。写した後にバイト数が元と一致することを確認している。

| ファイル | 内容 | バイト数 |
|---|---|---|
| `Landing.dc.html` | ランディング | 10,775 |
| `Account.dc.html` | アカウント | 9,733 |
| `Studio.dc.html` | 配信の画面。画面上部の「MOCK STATE」で 8 つの状態（待機・YouTube 未接続・開始ダイアログ・開始中・配信中・劣化・終了・非対応環境）を切り替えられる | 29,434 |
| `styles.css` | トークンの読み込み | 211 |
| `tokens/*.css` | 色・タイポグラフィ・余白・効果・基本スタイル（`base`・`colors`・`effects`・`fonts`・`spacing`・`typography`） | — |

## 入れていないもの

| 項目 | 理由 |
|---|---|
| `support.js`（約 66 KB） | Claude Design が出力する実行時。`.dc.html` を描画するのに要る。再生成する場合は Claude Design 側から取得する |
| `tokens/fonts-local.css`（約 12.8 KB）・woff2 フォント | フォントの同梱ファイル。`styles.css` が読み込むが、このリポジトリには入れていない。ライセンスの確認が済むまで入れない |
| `assets/`（`images/hero.webp` ほか） | 画像。出どころと利用許諾が未確認 |

## 見方

`.dc.html` は `support.js` が無いと描画されない（`<x-dc>`・`sc-if`・`sc-for` は Claude Design の記法）。そのため、このフォルダだけでは画面は開けない。内容の確認は、ファイルを読むか、Claude Design 側のプロジェクトを開いて行う。

## 再現するときの決まり

- `src/` にはこのモックの見た目を再現する。`.dc.html` の記法はそのまま持ち込まない（Next.js のコンポーネントとして書き直す）。
- 色・余白・書体は `tokens/*.css` の変数を使う。値を直接書かない。
- モックにある色の `--live`（赤）と `--warn`（琥珀）は、デザインシステムに無い追加色。採用するかは本人の判断待ち（`CLAUDE.md` の未決事項）。
- 製品名の「Browser Live」は仮の表記。
- モックの文言が `requirements.md` と食い違う場合は、`requirements.md` の文言を使う。
