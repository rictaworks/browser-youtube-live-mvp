# セッションの Cookie bl_session（issue #7。requirements.md 7.1・28.1。src/contracts/http-api.md 1.3）。
#
# 値は、セッション識別子のみ（乱数 32 バイトの URL 安全な文字列。状態は、サーバー側の sessions に持つ）。
# HttpOnly・SameSite=Lax・Path=/。本番は Secure（開発・テストの http では Secure を付けない。CookiePolicy）。
# 有効期限の属性（Expires・Max-Age）は付けない（ブラウザのセッション Cookie）。サーバー側が、最終利用から 30 日で失効させる（SessionStore）。
# Rails 標準のセッション（Cookie ストア）は使わない。
module SessionCookie
  NAME = "bl_session".freeze

  # Cookie を設定するときの属性（Rails の cookies[]= へ渡す Hash）
  def self.attributes(token, environment: AppEnvironment.current)
    raise ArgumentError, "token must be a non-empty String" unless token.is_a?(String) && !token.strip.empty?

    { value: token, httponly: true, same_site: :lax, path: "/", secure: CookiePolicy.secure?(environment) }
  end

  # Cookie を失効させるときの属性。Path・HttpOnly・SameSite は、設定のときと同じ（値は持たない）
  def self.expiry_attributes(environment: AppEnvironment.current)
    { httponly: true, same_site: :lax, path: "/", secure: CookiePolicy.secure?(environment) }
  end
end
