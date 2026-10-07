// Package contract は、3 層の契約（src/contracts）の、中継（Go）側の定数モジュールです。
//
// 列挙の符号（型付きの文字列定数）、制限値・間隔・閾値、WebSocket フレームの種別符号、受付の拒否理由ごとの
// HTTP ステータスと区分を持ちます。値は src/contracts の JSON の複製で、実行時に JSON を読みません
// （デプロイ単位が層ごとのため）。JSON との一致は、このパッケージのテスト（contract_test.go）が、両方向に保証します。
//
// 符号と数値だけを持ち、画面に出す文言を含みません。入出力（HTTP・WebSocket・ファイル・環境変数・時計）を
// 参照しません（Domain Core）。コーデック本体・モデル・コントローラーは、このパッケージの外（後続の issue）です。
package contract
