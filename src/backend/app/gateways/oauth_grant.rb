# OAuth の認可コードの交換の結果（issue #11。requirements.md 7.2・7.3）。YouTube 接続の認可コードを交換して得た付与。
# GoogleOidcClient#exchange_youtube_code（実物）と FakeGoogleOidc#exchange_youtube_code（疑似）が返す。
#
#   access_token   アクセストークン。接続時の確認（チャンネルの有無・ライブ配信が有効か）の呼び出しに、1 回だけ使う。永続化しない
#   refresh_token  更新トークン。無いことがある（nil）。応答に無い場合は、接続を成立させない（7.2「更新トークンの欠落」）。成立のときだけ、暗号化して保存する
#   scopes         付与されたスコープ（利用者が YouTube の権限を外して同意したときは、youtube が含まれない。7.2「スコープの部分拒否」）
#   expires_in     アクセストークンの有効秒数
#
# 形が違う値は ArgumentError（黙って通さない）。更新トークンの形は、TokenVault#store が受け付ける形と同じ（保存の段階で初めて拒否されない）。
# トークンを、inspect・to_s・pretty_inspect に出さない（スコープと、更新トークンの有無だけ出る）。ハッシュ・配列への変換を持たない
# （ログ・応答へ流れ込む道を作らない）。凍結されている。
class OAuthGrant
  # スコープの形（印字できる ASCII。空白を含まない）。Google のスコープは、URL の形
  SCOPE_PATTERN = /\A[\x21-\x7E]{1,512}\z/

  attr_reader :access_token, :refresh_token, :scopes, :expires_in

  def initialize(access_token:, refresh_token:, scopes:, expires_in:)
    @access_token = token!(access_token, GoogleTokenClient::TOKEN_PATTERN, "access_token")
    @refresh_token = refresh_token.nil? ? nil : token!(refresh_token, TokenVault::REFRESH_TOKEN_PATTERN, "refresh_token")
    @scopes = scopes!(scopes)
    @expires_in = expires_in!(expires_in)
    freeze
  end

  def refresh_token?
    !@refresh_token.nil?
  end

  # 付与されたスコープに含まれるか。完全一致（前方一致・部分一致で、別のスコープを同じとしない）
  def scope?(scope)
    @scopes.include?(scope)
  end

  def inspect
    "#<#{self.class.name} scopes=#{@scopes.inspect} refresh_token=#{refresh_token? ? 'present' : 'absent'} [FILTERED]>"
  end

  def to_s
    inspect
  end

  private

  # 例外のメッセージに、値を載せない（トークンを含みうる）
  def token!(value, pattern, name)
    raise ArgumentError, "#{name} must be a printable token without whitespace" unless value.is_a?(String) && pattern.match?(value)

    value.dup.freeze
  end

  def scopes!(value)
    valid = value.is_a?(Array) && value.all? { |scope| scope.is_a?(String) && SCOPE_PATTERN.match?(scope) }
    raise ArgumentError, "scopes must be an Array of scope Strings without whitespace" unless valid

    value.map { |scope| scope.dup.freeze }.freeze
  end

  def expires_in!(value)
    unless value.is_a?(Integer) && GoogleTokenClient::EXPIRES_IN_RANGE.cover?(value)
      raise ArgumentError, "expires_in must be an Integer in #{GoogleTokenClient::EXPIRES_IN_RANGE}"
    end

    value
  end
end
