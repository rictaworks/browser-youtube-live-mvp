# ログイン（/api/auth/*）のリクエストスペックの共通の補助（issue #8）。
#
# spec/rails_helper.rb は spec/support を自動では読み込まない。使うスペックは、先頭で
#   require "rails_helper"
#   require "support/api_helpers"
#   require "support/auth_flow_helpers"
# とし、`include ApiHelpers`・`include AuthFlowHelpers`・`include_context "API の環境"` で使う。
#
#   fresh_rate_limiter         頻度制限の計数を、このスペックの間だけ、新しいものへ差し替える（プロセスで共有の計数を、他のスペックと混ぜない）
#   use_gateways               ExternalServices.current が返す実装を差し替える（実物の GoogleOidcClient・RecaptchaVerifier を WebMock で動かすとき）
#   login_start / callback     login/start・callback を呼ぶ
#   set_cookie_lines           応答の Set-Cookie の各行
#   cookie_value               応答が設定した Cookie の値（失効させる行は nil）
#   authorize_path_of          認可 URL のうち、BFF がバックエンドへ転送する経路（パスとクエリ）
require "nokogiri"

module AuthFlowHelpers
  # 頻度制限を、時計を渡せる新しいものにして、RateLimiter.shared に差し替える。時計は { now: Time } のハッシュ
  def fresh_rate_limiter(clock_holder)
    limiter = RateLimiter.new(clock: -> { clock_holder.fetch(:now) })
    allow(RateLimiter).to receive(:shared).and_return(limiter)
    limiter
  end

  def use_gateways(google_oidc:, recaptcha_verifier:)
    gateways = ExternalServices::Gateways.new(google_oidc: google_oidc, recaptcha_verifier: recaptcha_verifier)
    allow(ExternalServices).to receive(:current).and_return(gateways)
    gateways
  end

  # Rack::Test の Cookie の入れ物は、前の応答の Cookie を、次の要求へ自動で付ける（Cookie ヘッダを明示しない要求に限る）。
  # 実際のブラウザの動作は、各スペックが Cookie ヘッダで明示する。空の Cookie ヘッダで、入れ物の Cookie を送らないようにする
  NO_COOKIES = { "Cookie" => "" }.freeze

  # 定数は、スペックの本体から（字句の範囲の外から）は引けないので、読み取り口を置く
  def no_cookies
    NO_COOKIES
  end

  def login_start(token = "dev-pass", signed_in: nil, headers: {}, **options)
    headers = NO_COOKIES.merge(headers) if signed_in.nil?
    api_post "/api/auth/login/start", { recaptcha_token: token }, signed_in: signed_in, headers: headers, **options
  end

  # コールバック（GET）。oauth_cookie は bl_oauth の値、session_token は bl_session の値（無ければ付けない）
  def callback(code: nil, state: nil, error: nil, oauth_cookie: nil, session_token: nil, headers: {})
    query = { code: code, state: state, error: error }.compact
    path = query.empty? ? "/api/auth/callback" : "/api/auth/callback?#{URI.encode_www_form(query)}"
    api_get path, headers: { "Cookie" => cookie_header_of(oauth_cookie, session_token) }.merge(headers)
  end

  def cookie_header_of(oauth_cookie, session_token)
    cookies = []
    cookies << "#{OAuthStateCookie::NAME}=#{oauth_cookie}" if oauth_cookie
    cookies << "#{SessionCookie::NAME}=#{session_token}" if session_token
    cookies.join("; ")
  end

  # 応答の Set-Cookie の各行（Rack 3 は、配列または改行区切りの文字列）
  def set_cookie_lines
    Array(response.headers["Set-Cookie"]).flat_map { |value| value.to_s.split("\n") }
  end

  def cookie_line(name)
    set_cookie_lines.find { |line| line.start_with?("#{name}=") }
  end

  # 応答が設定した Cookie の値。失効させる行（値が空）・無い Cookie は nil
  def cookie_value(name)
    line = cookie_line(name)
    return nil if line.nil?

    value = line.split(";").first.to_s.delete_prefix("#{name}=")
    value.empty? ? nil : value
  end

  # 失効させる Set-Cookie か（値が空で、過去の期限）
  def expired_cookie?(name)
    line = cookie_line(name)
    return false if line.nil?

    line.start_with?("#{name}=;") && line.downcase.include?("expires=thu, 01 jan 1970")
  end

  # 認可 URL のパスとクエリ（BFF がバックエンドへ転送する先）
  def authorize_path_of(url)
    uri = URI.parse(url)
    "#{uri.path}?#{uri.query}"
  end

  # 疑似の認可画面（HTML）の、アカウントごとのリンク先（コールバックの URL）。名前 => URL
  def account_links(html = response.body)
    Nokogiri::HTML(html).css("a").to_h { |anchor| [ anchor.text.strip, anchor["href"] ] }
  end

  # コールバックの URL（絶対 URL）から、BFF が転送するパスとクエリ
  def path_and_query(url)
    uri = URI.parse(url)
    "#{uri.path}?#{uri.query}"
  end

  # 疑似のログインを、最後まで行う（開始 → 疑似の認可画面 → アカウントの選択 → コールバック）。
  # コールバックの応答の状態にしておく。返り値は、開始の応答の認可 URL と、bl_oauth の値
  def run_fake_login(account: "dev-user-1", session_token: nil)
    login_start
    expect(response).to have_http_status(:ok)
    authorization_url = json_body.fetch("authorization_url")
    oauth_cookie = cookie_value(OAuthStateCookie::NAME)

    api_get authorize_path_of(authorization_url), headers: NO_COOKIES
    expect(response).to have_http_status(:ok)
    callback_url = account_links.fetch(account)

    api_get path_and_query(callback_url), headers: { "Cookie" => cookie_header_of(oauth_cookie, session_token) }
    [ authorization_url, oauth_cookie ]
  end
end
