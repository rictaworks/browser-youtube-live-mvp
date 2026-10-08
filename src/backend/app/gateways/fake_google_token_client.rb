# 疑似の Google のトークンエンドポイント（issue #10）。開発・テストのみ。GoogleTokenClient と同じ使い方（refresh・revoke）で、
# 外部サービスを呼ばない。本番では構築できない（FakeServices.verify_environment!）。
#
#   refresh  決定的なアクセストークン fake-access-token-N（N は呼び出しごとに 1 から増える）と、有効秒数 3600 を返す
#   revoke   :revoked を返す
#   fail_next(kind, times:)  次の呼び出しだけ、失敗させる（失敗の注入。テストと開発の両方から指定できる）
#     token_revoked        次の refresh が TokenRevoked（invalid_grant）
#     token_unavailable    次の refresh が TokenTemporarilyUnavailable
#     unexpected           次の refresh が UnexpectedResponse
#     revoke_unavailable   次の revoke が TokenTemporarilyUnavailable
#
# 注入と番号は、このインスタンスのメモリにだけ持つ（スレッドセーフ）。注入した失敗は、番号を進めない。
class FakeGoogleTokenClient
  ACCESS_TOKEN_PREFIX = "fake-access-token-".freeze
  EXPIRES_IN_SECONDS = 3600

  # 失敗の注入の種類 -> どの呼び出しに効くか
  INJECTIONS = {
    token_revoked: :refresh,
    token_unavailable: :refresh,
    unexpected: :refresh,
    revoke_unavailable: :revoke
  }.freeze

  def initialize(environment: AppEnvironment.current)
    FakeServices.verify_environment!(environment)

    @mutex = Mutex.new
    reset_state
  end

  def refresh(refresh_token:)
    raise ArgumentError, "refresh_token must be a non-empty token String" unless token?(refresh_token)

    @mutex.synchronize do
      injected = @queues.fetch(:refresh).shift
      raise failure_for(injected) if injected

      @refresh_count += 1
      GoogleTokenClient::Tokens.new(access_token: "#{ACCESS_TOKEN_PREFIX}#{@refresh_count}", expires_in: EXPIRES_IN_SECONDS)
    end
  end

  def revoke(token:)
    raise ArgumentError, "token must be a non-empty token String" unless token?(token)

    @mutex.synchronize do
      injected = @queues.fetch(:revoke).shift
      raise failure_for(injected) if injected
    end
    :revoked
  end

  # 次の呼び出し（kind が効く呼び出し）を、times 回、失敗させる
  def fail_next(kind, times: 1)
    raise ArgumentError, "kind must be one of #{INJECTIONS.keys.inspect}" unless INJECTIONS.key?(kind)
    raise ArgumentError, "times must be a positive Integer" unless times.is_a?(Integer) && times.positive?

    @mutex.synchronize { @queues.fetch(INJECTIONS.fetch(kind)).concat(Array.new(times, kind)) }
    nil
  end

  # 注入と番号を、初期状態へ戻す
  def reset!
    @mutex.synchronize { reset_state }
    nil
  end

  def inspect
    "#<#{self.class.name}>"
  end

  private

  def reset_state
    @refresh_count = 0
    @queues = { refresh: [], revoke: [] }
  end

  def token?(value)
    value.is_a?(String) && !value.strip.empty?
  end

  def failure_for(kind)
    case kind
    when :token_revoked then YouTubeErrors::TokenRevoked.new(call_kind: :token_refresh, status: 400, reason: GoogleTokenClient::REVOKED_CODE)
    when :token_unavailable then YouTubeErrors::TokenTemporarilyUnavailable.new(call_kind: :token_refresh, status: 503)
    when :unexpected then YouTubeErrors::UnexpectedResponse.new(call_kind: :token_refresh, status: 400, reason: "invalid_client")
    when :revoke_unavailable then YouTubeErrors::TokenTemporarilyUnavailable.new(call_kind: :token_revoke, status: 503)
    end
  end
end
