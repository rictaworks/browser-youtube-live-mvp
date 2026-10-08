# YouTube 接続（issue #11）のスペックの共通の補助。
#
# 実際の Google・YouTube は呼ばない（疑似の Google（FakeGoogleOidc）・疑似の YouTube（FakeYouTubeGateway）・WebMock）。
# 値は明らかなダミー。秘密（トークン・チャンネル名）は、末尾が must-not-appear で、ログ・DB・応答に現れないことの検査に使う。
#
# spec/rails_helper.rb は spec/support を自動では読み込まない。使うスペックは、先頭で
#   require "support/youtube_connect_support"
# とし、最上位の describe の中で include する。
#   include_context "YouTube 接続の環境"        環境変数 TOKEN_ENCRYPTION_KEY をダミー値にして、疑似の YouTube・アクセストークンの共有を初期状態へ戻す
#
#   connect_services                            疑似の Google・疑似の YouTube・チャンネル名のキャッシュを束ねた YouTubeConnectService
#   begin_connect(user)                         認可の開始（start）。bl_oauth の中身と同じ Payload と、認可 URL の PKCE の challenge を返す
#   grant_code(flow, kind:)                     疑似の同意画面が発行する認可コード
#   complete_connect(flow, ...)                 コールバック（complete）
require "rails_helper"
require "support/model_support"
require "support/log_capture"
require "services/support/ledger_support"

module YouTubeConnectSupport
  # TokenVault が受け付ける鍵の形（64 桁の 16 進数）。ダミー（資格情報ではない）
  KEY = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".freeze
  SECRET = "dummy-secret-key-base-for-youtube-connect-0001".freeze
  CALLBACK_URI = "https://app.example.test/api/youtube/connect/callback".freeze

  # 認可の開始から、コールバックまでの状態。started は YouTubeConnectService::Start、payload は bl_oauth の中身
  Flow = Struct.new(:started, :payload, :challenge, :user, keyword_init: true)

  def connect_key
    KEY
  end

  def callback_uri
    CALLBACK_URI
  end

  def youtube_scope
    "https://www.googleapis.com/auth/youtube"
  end

  # PKCE（S256）の code_challenge
  def s256_challenge(verifier)
    Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
  end

  # 疑似の YouTube・疑似のトークンエンドポイント・暗号鍵（環境の判定は test）
  def connect_stack
    @connect_stack ||= YouTubeServices.build(AppEnvironment.new("test"), env: { "TOKEN_ENCRYPTION_KEY" => KEY })
  end

  def fake_oidc
    @fake_oidc ||= FakeGoogleOidc.new(secret: SECRET)
  end

  def channel_names
    @channel_names ||= ChannelNameCache.new
  end

  def fake_youtube
    connect_stack.youtube_gateway
  end

  def token_vault
    connect_stack.token_vault
  end

  def connect_service(oidc: fake_oidc)
    YouTubeConnectService.new(
      oidc: oidc, token_vault: token_vault, youtube_gateway: fake_youtube, channel_names: channel_names
    )
  end

  # 認可の開始。bl_oauth に入れる状態（Payload）と、認可 URL の PKCE の challenge を、まとめて返す
  def begin_connect(user, service: connect_service)
    started = service.start(user: user, redirect_uri: callback_uri)
    query = Rack::Utils.parse_query(URI.parse(started.authorization_url).query)
    payload = OAuthStateCookie::Payload.new(
      state: started.state, nonce: started.nonce, code_verifier: started.code_verifier, purpose: "connect", user_id: user.id
    )
    Flow.new(started: started, payload: payload, challenge: query.fetch("code_challenge"), user: user)
  end

  # 疑似の同意画面が発行する認可コード（kind は FakeGoogleOidc::YOUTUBE_GRANT_KINDS）
  def grant_code(flow, kind: FakeGoogleOidc::FULL, at: Time.current, oidc: fake_oidc)
    oidc.issue_youtube_code(kind: kind, code_challenge: flow.challenge, redirect_uri: callback_uri, now: at)
  end

  # コールバック。引数の既定は、正しい流れ（同じアカウント・同じ state・bl_oauth あり）。差し替えて、異常を作る
  def complete_connect(flow, code:, service: connect_service, user: flow.user, payload: flow.payload, state: flow.started.state, error: nil, now: Time.current)
    service.complete(user: user, payload: payload, code: code, state: state, error: error, redirect_uri: callback_uri, now: now)
  end

  # 認可の開始から成立（または不成立）まで。kind は疑似の同意画面の選択
  def run_connect(user, kind: FakeGoogleOidc::FULL, service: connect_service, now: Time.current)
    flow = begin_connect(user, service: service)
    complete_connect(flow, code: grant_code(flow, kind: kind, at: now), service: service, now: now)
  end

  # DB のすべての表の全列を、文字列にして連結する（機密が、どの表にも保存されていないことの検査）
  def database_dump
    connection = ActiveRecord::Base.connection
    (connection.tables - %w[ schema_migrations ar_internal_metadata ]).map do |table|
      connection.select_all("SELECT * FROM #{connection.quote_table_name(table)}").to_a.to_s
    end.join("\n")
  end

  # そのコードで付与されるトークン（OAuthGrant）。疑似の Google は、同じコードに同じトークンを返す（期待値の算出に使う）
  def grant_of(flow, code)
    fake_oidc.exchange_youtube_code(code: code, code_verifier: flow.started.code_verifier, redirect_uri: callback_uri)
  end
end

RSpec.shared_context "YouTube 接続の環境" do
  # 環境変数 TOKEN_ENCRYPTION_KEY（CI には無い）を、ダミー値にする。疑似の YouTube・アクセストークンのキャッシュは、プロセスで共有されるので、
  # 例の前後で初期状態へ戻す
  around do |example|
    original = ENV.fetch("TOKEN_ENCRYPTION_KEY", nil)
    ENV["TOKEN_ENCRYPTION_KEY"] = YouTubeConnectSupport::KEY
    YouTubeServices.reset_shared!
    example.run
  ensure
    ENV["TOKEN_ENCRYPTION_KEY"] = original
    YouTubeServices.reset_shared!
  end
end
