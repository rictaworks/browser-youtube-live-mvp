# API（/api）のリクエストスペックの共通の補助（issue #7）。
#
# spec/rails_helper.rb は spec/support を自動では読み込まない。API のスペックは、先頭で
#   require "rails_helper"
#   require "support/api_helpers"
# とし、`include ApiHelpers`・`include_context "API の環境"` で使う。
#
# 後続の issue（#8・#11・#12・#16 など）も、この補助で /api のリクエストスペックを書く。
#   api_get(path, signed_in:)                          ログイン済みの GET（BFF の確認を通る）
#   api_post(path, body, signed_in:)                   ログイン済みの POST（CSRF を通る）
#   api_request(verb, path, ...)                       上の 2 つの元
#   sign_in(user)                                      セッションを発行し、Cookie の値と CSRF トークンを返す
#   public_listener_env・internal_listener_env         待ち受けの口を、リクエストの env へ明示する
#
# テストでは puma.socket が無いので、待ち受けの口は env["bl.listener_port"] で明示する（ListenerPort。黙って公開側と見なさない）。
require "support/model_support"

module ApiHelpers
  # スペックの間だけ、環境変数 BFF_SHARED_SECRET に入れる、明らかなダミー値（開発の .env の値は使わない・表示しない）
  BFF_SECRET = "dummy-bff-shared-secret-for-specs-0001".freeze

  # BFF が付ける、公開オリジン（フロントエンド）の Host とスキーム
  PUBLIC_HOST = "app.example.test".freeze
  PUBLIC_ORIGIN = "https://#{PUBLIC_HOST}".freeze

  # BFF が付ける、利用者の IP（ドキュメント用の範囲。RFC 5737）。ログ・DB・応答に出ないことを、スペックで確かめる
  CLIENT_IP = "203.0.113.10".freeze

  SignedIn = Struct.new(:user, :token, :session, :csrf_token, keyword_init: true)

  def public_listener_env
    { ListenerPort::ENV_KEY => ListenerPort.public_port }
  end

  def internal_listener_env
    { ListenerPort::ENV_KEY => ListenerPort.internal_port }
  end

  # BFF（フロントエンド）が付けるヘッダ。overrides の値が nil のヘッダは、付けない
  def bff_headers(overrides = {})
    {
      "X-BFF-Secret" => BFF_SECRET,
      "X-Forwarded-For" => CLIENT_IP,
      "X-Forwarded-Host" => PUBLIC_HOST,
      "X-Forwarded-Proto" => "https"
    }.merge(overrides).compact
  end

  def csrf_token_for(session_token)
    CsrfToken.new(secret: Rails.application.secret_key_base).derive(session_token)
  end

  # セッションを発行する。user を省略すると、アカウントを作る
  def sign_in(user = nil, now: Time.current)
    user ||= create(:user)
    issued = SessionStore.new.issue(user: user, now: now)
    SignedIn.new(user: user, token: issued.token, session: issued.session, csrf_token: csrf_token_for(issued.token))
  end

  # ブラウザが付けるヘッダ（BFF が通すもの）と、BFF が付けるヘッダの組。
  #   signed_in        ログイン済みなら Cookie（bl_session）を付ける
  #   state_changing   POST などでは、X-BL-Client・Origin（公開オリジン）と、ログイン済みなら X-CSRF-Token も付ける
  def api_headers(signed_in: nil, state_changing: false)
    headers = bff_headers
    headers["Cookie"] = "#{SessionCookie::NAME}=#{signed_in.token}" if signed_in
    if state_changing
      headers["X-BL-Client"] = "web"
      headers["Origin"] = PUBLIC_ORIGIN
      headers["X-CSRF-Token"] = signed_in.csrf_token if signed_in
    end
    headers
  end

  # headers の値が nil のヘッダは、付けない（既定のヘッダを外す）。body は Hash なら JSON にする。raw_body は、そのまま送る
  def api_request(verb, path, body: nil, raw_body: nil, signed_in: nil, headers: {}, env: nil)
    state_changing = !%i[ get head options ].include?(verb)
    payload = raw_body || (body.nil? ? nil : JSON.generate(body))
    merged = api_headers(signed_in: signed_in, state_changing: state_changing)
    merged["Content-Type"] = "application/json" if state_changing
    merged = merged.merge(headers).compact
    public_send(verb, path, params: payload, headers: merged, env: env || public_listener_env)
  end

  def api_get(path, **options)
    api_request(:get, path, **options)
  end

  def api_post(path, body = nil, **options)
    api_request(:post, path, body: body, **options)
  end

  # 応答の本文（JSON）
  def json_body
    JSON.parse(response.body)
  end

  # エラーの形（{"error":{"code":…,"details":…}}）の符号
  def error_code
    json_body.dig("error", "code")
  end
end

RSpec.shared_context "API の環境" do
  # 環境変数 BFF_SHARED_SECRET を、ダミー値にする（BFF の確認は、要求のたびに環境変数を読む）。終わったら元へ戻す
  around do |example|
    original = ENV.fetch("BFF_SHARED_SECRET", nil)
    ENV["BFF_SHARED_SECRET"] = ApiHelpers::BFF_SECRET
    example.run
  ensure
    ENV["BFF_SHARED_SECRET"] = original
  end
end
