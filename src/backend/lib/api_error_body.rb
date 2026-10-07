# 契約のエラーの形（src/contracts/http-api.md 1.6）: {"error":{"code":"<符号>","details":{…}}}。
# コントローラ（Api::BaseController）と、コントローラの外の Rack の部品（ホストの拒否・存在しない経路）が、同じ形を使う。
# 画面に出す文言を含まない（符号と数値だけ）。HTML のエラーページを返さない。
module ApiErrorBody
  CONTENT_TYPE = "application/json; charset=utf-8".freeze
  # すべての応答に no-store を付ける（状態・CSRF トークン・認可 URL を、共有のキャッシュ・ブラウザの履歴に残さない。契約 1.2）
  CACHE_CONTROL = "no-store".freeze

  # エラーの本文（Hash）。details を省略すると、空のオブジェクト（契約: 省略は空と同じ）
  def self.build(code, details = {})
    raise ArgumentError, "code must be a non-empty String" unless code.is_a?(String) && !code.empty?

    { "error" => { "code" => code, "details" => details } }
  end

  # Rack の応答（状態・ヘッダ・本文）の 3 つ組
  def self.rack_response(status, code, details = {})
    body = JSON.generate(build(code, details))
    # Rack 3 は、ヘッダ名を小文字で受け取る（大文字を含む名前は、下流のミドルウェアが、別のヘッダとして扱う）
    headers = {
      "content-type" => CONTENT_TYPE,
      "cache-control" => CACHE_CONTROL,
      "content-length" => body.bytesize.to_s
    }
    [ status, headers, [ body ] ]
  end
end
