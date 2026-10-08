# 更新トークンの暗号化保存と、アクセストークンのメモリ上の再利用（issue #10。requirements.md 7.3・7.4・10.6・28.1）。
#
#   store         更新トークンを AES-256-GCM（ActiveSupport::MessageEncryptor。鍵は TOKEN_ENCRYPTION_KEY）で暗号化して、
#                 youtube_connections.refresh_token_ciphertext に保存する
#   access_token  必要時に更新トークンから取得し、有効期限内に限りメモリ上で再利用する（永続化しない。期限の 60 秒前に更新）。
#                 同じアカウントの同時の更新は、1 回にまとめる（AccessTokenCache#synchronize）
#   revoke        Google の失効エンドポイントへ送り、成否にかかわらず、保存したトークンを削除する。結果を返す
#
# 更新が恒久的に失敗（invalid_grant・取り消し）したら、YouTubeErrors::TokenRevoked を投げ、接続状態を revoked にする（7.3）。
# 一時的な失敗（ネットワーク・429・5xx）は YouTubeErrors::TokenTemporarilyUnavailable で、状態を変えない。
# 想定外の応答（クライアントの設定の誤りなど）は YouTubeErrors::UnexpectedResponse で、状態を変えない（全利用者を失効させない）。
# 暗号文が復号できない（鍵の取り違え・破損）ときも、状態を変えず、TokenVault::Undecryptable を投げる。
#
# 鍵: 64 文字の 16 進数（32 バイト。例: openssl rand -hex 32。scripts/setup_dev_env.sh が開発用に生成する）。
# 未設定・形式の誤りは InvalidKey（本番だけでなく、どの環境でも。鍵の値を、メッセージに出さない）。
# 暗号文はアカウントに結びつく（MessageEncryptor の purpose にアカウントの識別子を含める）。他のアカウントの行へ写しても復号できない。
#
# アクセストークンのキャッシュは、プロセスで共有する（YouTubeServices が、同じ AccessTokenCache を渡す）。時刻は引数 now で受け取る。
# 更新トークン（平文・暗号文）・アクセストークン・鍵を、ログ・例外・inspect に出さない。ログは、アカウントの内部の識別子と符号だけ。
class TokenVault
  KEY_NAME = "TOKEN_ENCRYPTION_KEY".freeze
  KEY_FORMAT = /\A\h{64}\z/
  CIPHER = "aes-256-gcm".freeze
  # 暗号文の用途。アカウントの識別子を足して、暗号文をアカウントに結びつける
  PURPOSE = "youtube_refresh_token".freeze
  # 有効期限のこの秒数前に更新する（7.3 の「有効期限内に限り」の余裕。期限ぎりぎりのトークンで、通信中に失効しないため）
  REFRESH_MARGIN_SECONDS = 60
  # 更新トークンの形（印字できる ASCII。空白・改行・制御文字を含まない）。Google の更新トークンは 100 文字ほど
  REFRESH_TOKEN_PATTERN = /\A[\x21-\x7E]{1,2048}\z/
  # 認可失効（revoked）の接続のトークンを要求したときの reason の符号
  CONNECTION_REVOKED = "connection_revoked".freeze
  LOG_TAG = "[token_vault]".freeze

  REVOKE_OUTCOMES = %i[ revoked already_invalid failed no_connection ].freeze
  REVOKE_CAUSES = [ nil, :unavailable, :rejected, :undecryptable ].freeze

  # 鍵が未設定（:missing）・形式の誤り（:format）。メッセージは、変数の名前と期待する形式だけ（鍵の値を含めない）
  class InvalidKey < StandardError
    def initialize(problem)
      super(
        if problem == :missing
          "#{KEY_NAME} is not set"
        else
          "#{KEY_NAME} must be 64 hexadecimal characters (32 bytes)"
        end
      )
    end
  end

  # アカウントに YouTube の接続が無い（未接続）。メッセージは、アカウントの内部の識別子だけ
  class NotConnected < StandardError
    attr_reader :user_id

    def initialize(user_id:)
      @user_id = user_id
      super("youtube connection is not found user_id=#{user_id}")
    end
  end

  # 保存した暗号文を復号できない（鍵の取り違え・暗号文の破損・他のアカウントの暗号文）。接続の状態は変えない。
  # メッセージは、アカウントの内部の識別子だけ（暗号文・鍵を含めない）
  class Undecryptable < StandardError
    attr_reader :user_id

    def initialize(user_id:)
      @user_id = user_id
      super("refresh token cannot be decrypted user_id=#{user_id}")
    end
  end

  # 失効の結果。outcome は、:revoked（Google が受理）・:already_invalid（すでに失効している）・:failed（Google 側で確認できなかった）・
  # :no_connection（保存したトークンが無かった）。cause は :failed のときの原因（:unavailable 一時的な失敗・:rejected 想定外の応答・
  # :undecryptable 復号できない）。どの結果でも、保存したトークンは削除してある
  RevokeResult = Data.define(:outcome, :cause) do
    def initialize(outcome:, cause: nil)
      raise ArgumentError, "outcome must be one of #{REVOKE_OUTCOMES.inspect}" unless REVOKE_OUTCOMES.include?(outcome)
      raise ArgumentError, "cause must be one of #{REVOKE_CAUSES.inspect}" unless REVOKE_CAUSES.include?(cause)

      super
    end

    # Google 側で、トークンが無効になったと確認できた
    def confirmed?
      %i[ revoked already_invalid ].include?(outcome)
    end
  end

  # 鍵（64 文字の 16 進数）を、32 バイトの鍵にする。未設定・形式の誤りは InvalidKey
  def self.parse_key(value)
    raise InvalidKey.new(:missing) if value.nil? || (value.is_a?(String) && value.strip.empty?)
    raise InvalidKey.new(:format) unless value.is_a?(String) && KEY_FORMAT.match?(value)

    [ value ].pack("H*").freeze
  end

  # key は TOKEN_ENCRYPTION_KEY の値。token_client は refresh・revoke に応えるもの（GoogleTokenClient・FakeGoogleTokenClient）。
  # cache は、プロセスで共有する AccessTokenCache（省くと、新しいキャッシュを持つ）
  def initialize(key:, token_client:, cache: AccessTokenCache.new, logger: Rails.logger)
    raise ArgumentError, "token_client is required" if token_client.nil?
    raise ArgumentError, "cache must be a TokenVault::AccessTokenCache" unless cache.is_a?(AccessTokenCache)

    @encryptor = ActiveSupport::MessageEncryptor.new(self.class.parse_key(key), cipher: CIPHER, serializer: :json)
    @token_client = token_client
    @cache = cache
    @logger = logger
  end

  # 更新トークンを暗号化して保存する。保存した接続（YoutubeConnection）を返す。
  #   接続が無い: 接続を作る（接続済み。接続の時刻・確認の時刻は now）
  #   接続がある: 暗号文だけを置き換える（状態・ストリームの識別子・時刻は変えない。接続の成立に伴う更新は、呼び出し側（#11）が行う）
  # そのアカウントのメモリ上のアクセストークンは捨てる。保存の SQL は、バインド値を使う（ログに暗号文が出ない）。
  def store(user_id:, refresh_token:, now: Time.current)
    user = OwnerScope.owner_id!(user_id)
    token = refresh_token!(refresh_token)
    Preconditions.time!(now, "now")

    @cache.synchronize(user) do
      persist!(user, encrypt(token, user), now)
      @cache.delete(user)
    end
    @logger.info("#{LOG_TAG} stored user_id=#{user}")
    YoutubeConnection.owned_by(user).take!
  end

  # now で有効なアクセストークン。有効期限の 60 秒前までは、メモリ上のものを使い回す。過ぎたら、更新トークンから取得し直す。
  # 失敗は YouTubeErrors::TokenRevoked（恒久。接続状態を revoked にする）・TokenTemporarilyUnavailable・UnexpectedResponse、
  # TokenVault::NotConnected（未接続）・Undecryptable
  def access_token(user_id:, now:)
    user = OwnerScope.owner_id!(user_id)
    Preconditions.time!(now, "now")

    cached = @cache.fetch(user, now: now, margin_seconds: REFRESH_MARGIN_SECONDS)
    return cached if cached

    @cache.synchronize(user) do
      # 待っているあいだに、別のスレッドが更新していれば、それを使う（Google への更新を 1 回にまとめる）
      @cache.fetch(user, now: now, margin_seconds: REFRESH_MARGIN_SECONDS) || refresh!(user, now)
    end
  end

  # そのアカウントのメモリ上のアクセストークンを捨てる（YouTube が拒否したトークンを、使い続けない）
  def forget_access_token(user_id:)
    @cache.delete(OwnerScope.owner_id!(user_id))
  end

  # Google の失効エンドポイントへ更新トークンを送り、成否にかかわらず、保存したトークン（接続）を削除する。結果（RevokeResult）を返す。
  # 失効の失敗は、例外にせず、結果で返す（呼び出し側（#16）が扱う）。想定外の例外（実装の誤り）でも、削除はしてから、そのまま伝える。
  def revoke(user_id:)
    user = OwnerScope.owner_id!(user_id)

    result = @cache.synchronize(user) do
      connection = YoutubeConnection.owned_by(user).take
      next RevokeResult.new(outcome: :no_connection) if connection.nil?

      begin
        revoke_at_google(connection, user)
      ensure
        YoutubeConnection.owned_by(user).where(id: connection.id).delete_all
        @cache.delete(user)
      end
    end
    cause = result.cause ? " cause=#{result.cause}" : ""
    @logger.info("#{LOG_TAG} revoked user_id=#{user} outcome=#{result.outcome}#{cause}")
    result
  end

  # 鍵・キャッシュの内容を出さない
  def inspect
    "#<#{self.class.name}>"
  end

  private

  # 接続の行を作る（無ければ）。あれば、暗号文だけを置き換える。行ロックで、同じアカウントの更新を直列にする。
  # 同時に作られて一意制約に当たったら（別のプロセス）、1 回だけやり直す（やり直すと、更新になる）。
  # 呼び出し側のトランザクションを壊さないよう、SAVEPOINT で包む
  def persist!(user, ciphertext, now)
    attempts = 0
    begin
      YoutubeConnection.transaction(requires_new: true) do
        connection = YoutubeConnection.owned_by(user).lock.take
        if connection
          connection.update!(refresh_token_ciphertext: ciphertext)
        else
          YoutubeConnection.create!(
            user_id: user, state: Contract::YoutubeConnectionState::CONNECTED, refresh_token_ciphertext: ciphertext,
            connected_at: now, last_verified_at: now
          )
        end
      end
    rescue ActiveRecord::RecordNotUnique
      attempts += 1
      retry if attempts < 2
      raise
    end
  end

  # 更新トークンから、アクセストークンを取得してキャッシュに置く（アカウントの排他の中で呼ぶ）
  def refresh!(user, now)
    connection = YoutubeConnection.owned_by(user).take
    raise NotConnected.new(user_id: user) if connection.nil?
    raise revoked_connection(user) if connection.state == Contract::YoutubeConnectionState::REVOKED

    tokens = request_tokens(connection, user, decrypt!(connection.refresh_token_ciphertext, user))
    @cache.put(user, tokens.access_token, expires_at: now + tokens.expires_in)
    tokens.access_token
  end

  def request_tokens(connection, user, refresh_token)
    @token_client.refresh(refresh_token: refresh_token)
  rescue YouTubeErrors::TokenRevoked => error
    # 恒久的な失敗: 取り消し・期限切れ。接続状態を認可失効にし、メモリ上のトークンを捨てる（再接続が要る）
    @cache.delete(user)
    connection.mark_revoked!
    log_failure(user, error)
    raise
  rescue YouTubeErrors::Base => error
    # 一時的な失敗・想定外の応答: 状態を変えない
    log_failure(user, error)
    raise
  end

  def revoked_connection(user)
    error = YouTubeErrors::TokenRevoked.new(call_kind: :token_refresh, reason: CONNECTION_REVOKED)
    log_failure(user, error)
    error
  end

  def revoke_at_google(connection, user)
    outcome = @token_client.revoke(token: decrypt!(connection.refresh_token_ciphertext, user))
    RevokeResult.new(outcome: outcome)
  rescue Undecryptable
    RevokeResult.new(outcome: :failed, cause: :undecryptable)
  rescue YouTubeErrors::TokenTemporarilyUnavailable => error
    log_failure(user, error)
    RevokeResult.new(outcome: :failed, cause: :unavailable)
  rescue YouTubeErrors::Base => error
    log_failure(user, error)
    RevokeResult.new(outcome: :failed, cause: :rejected)
  end

  def encrypt(token, user)
    @encryptor.encrypt_and_sign(token, purpose: purpose(user))
  end

  # 復号できなければ Undecryptable。ログは、符号だけ（暗号文・鍵を出さない）
  def decrypt!(ciphertext, user)
    token = @encryptor.decrypt_and_verify(ciphertext, purpose: purpose(user))
    return token if token.is_a?(String) && !token.empty?

    raise undecryptable(user)
  rescue ActiveSupport::MessageEncryptor::InvalidMessage
    raise undecryptable(user)
  end

  def undecryptable(user)
    @logger.warn("#{LOG_TAG} refresh failed user_id=#{user} cause=undecryptable")
    Undecryptable.new(user_id: user)
  end

  def purpose(user)
    "#{PURPOSE}:#{user}"
  end

  def refresh_token!(value)
    return value if value.is_a?(String) && REFRESH_TOKEN_PATTERN.match?(value)

    raise ArgumentError, "refresh_token must be a printable token without whitespace (1 to 2048 characters)"
  end

  # アカウントの内部の識別子と、符号だけ（error.message は、クラス・呼び出し・ステータス・reason の符号）
  def log_failure(user, error)
    @logger.warn("#{LOG_TAG} refresh failed user_id=#{user} #{error.message}")
  end
end
