# BFF の確認（X-BFF-Secret）を通った要求（issue #7。requirements.md 6.1・28.1）。
#
# 利用者の IP と公開オリジンは、確認を通った要求の転送ヘッダからだけ読む。転送ヘッダは、ミドルウェアの先頭で env から取り除かれ、
# 別の場所に保管されている（lib/forwarded_headers.rb）。保管した値を渡して、これを作れるのは、確認を通した BffGuard だけ。
# IP・公開オリジンは、必要になったときに作る（片方の不備が、もう片方を妨げない）。inspect に、値を出さない。
class VerifiedBffRequest
  # forwarded は ForwardedHeaders::Values
  def initialize(forwarded)
    @forwarded = forwarded
  end

  # 利用者の IP（X-Forwarded-For の先頭）。ヘッダが無い・IP として読めなければ、不明（別の値で補わない）
  def client_ip
    @client_ip ||= ClientIp.parse(@forwarded.forwarded_for)
  end

  # 公開オリジン（X-Forwarded-Host・X-Forwarded-Proto）。無い・正しくなければ PublicOrigin::InvalidError
  def public_origin
    @public_origin ||= PublicOrigin.from_forwarded(host: @forwarded.forwarded_host, proto: @forwarded.forwarded_proto)
  end

  def inspect
    "#<#{self.class.name} [FILTERED]>"
  end
end
