# Cookie の Secure 属性の方針（issue #7。requirements.md 7.1・28.1）。
#
# 本番は、HTTPS だけで配信するので、Secure を付ける。
# 開発・テストは、http なので、Secure を付けない。付けると、ブラウザは http の応答の Cookie を保存せず（Rails も、Secure の Cookie を、
# SSL でない要求には書かない）、開発・テストでログインできなくなる。
module CookiePolicy
  def self.secure?(environment = AppEnvironment.current)
    environment.production?
  end
end
