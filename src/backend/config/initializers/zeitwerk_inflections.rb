# Be sure to restart your server when you modify this file.

# Zeitwerk の語の綴りの個別の指定（ファイル名 -> 定数名）。issue #10 の YouTube 連携の窓口。
#
# グローバルな inflect.acronym "YouTube" は足さない。足すと、既存の定数 YoutubeConnection（綴りはこのまま。
# ファイル youtube_connection.rb）の綴りまで変わってしまう。そこで、窓口の定数だけを、ファイル名の単位で指定する。
# ディレクトリの名前（app/gateways/youtube_gateway/ など）にも、同じ指定が効く。
#
# 新しい YouTube 連携のファイルを足したときは、ここへ足す。足し忘れは、bin/rails zeitwerk:check と、
# CI の eager_load が検出する（定数の名前が、ファイル名から期待される綴りと食い違う）。
Rails.autoloaders.each do |autoloader|
  autoloader.inflector.inflect(
    "youtube_gateway" => "YouTubeGateway",
    "fake_youtube_gateway" => "FakeYouTubeGateway",
    "youtube_errors" => "YouTubeErrors",
    "youtube_status" => "YouTubeStatus",
    "youtube_services" => "YouTubeServices"
  )
end
