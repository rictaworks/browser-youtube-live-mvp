# 疑似の Google の、アカウント選択の画面（issue #8）。開発・テストのみ。契約の外（src/contracts/http-api.md 1.1）。
#
#   GET /api/dev/google/authorize   FakeGoogleOidc#authorization_url が返す行き先。固定の 3 アカウント（dev-user-1〜dev-user-3）を
#                                   リンクで表示し、選ぶと redirect_uri?code=…&state=… へ戻す（ログインの操作は、本番と同じ経路）。
#                                   コードは、選んだアカウントの sub と、開始の nonce・PKCE の challenge・redirect_uri を含む（ステートレス）
#
# 本番には存在しない: ① 経路を描かない（config/routes.rb。環境の判定で決める。本番では 404 not_found）
# ② 使っている実装が疑似でなければ（実物が選ばれているなら）、画面を出さない ③ 疑似の実装は、本番で構築できない（FakeServices）。
# 開発者向けの近道（ログイン済みの状態を直接作る経路）は、持たない。
#
# Api::BaseController を継承する（BFF の確認・公開オリジン・エラーの形）。ブラウザからは、同一オリジン中継（BFF）を通って届く。
# パラメータを厳しく検査してから、画面を作る（HTML・URL を壊す文字を受け付けない）。ERB の最小のページ。文言は config/locales/ja.yml。
module Dev
  class GoogleController < Api::BaseController
    allow_anonymous

    # 値が決まっている項目（スコープは openid のみ。email・profile を要求させない）
    EXPECTED_FIXED = { "response_type" => "code", "scope" => "openid", "code_challenge_method" => "S256" }.freeze
    # 検査する項目の順（不備のある項目を、この順に挙げる）
    FIELD_ORDER = %w[ response_type scope redirect_uri state nonce code_challenge code_challenge_method ].freeze
    # state・nonce・code_challenge は、base64url の文字だけ（本物の値は 43 文字）
    TOKEN_PATTERN = /\A[A-Za-z0-9_-]{1,#{OAuthStateCookie::MAX_FIELD_LENGTH}}\z/
    CALLBACK_PATH = Api::AuthController::CALLBACK_PATH
    TEMPLATE = "dev/google/authorize".freeze

    def authorize
      oidc = fake_oidc!
      values = validated_values!
      accounts = oidc.accounts.map { |sub| { label: sub, href: callback_link(oidc, sub, values) } }
      render body: render_page(accounts), content_type: "text/html; charset=utf-8"
    end

    private

    # 使っている実装が疑似の Google でなければ、画面を出さない（存在しないものとして 404）
    def fake_oidc!
      oidc = ExternalServices.current.google_oidc
      raise Api::Error::NotFound.new(reason: :fake_google_unavailable) unless oidc.is_a?(FakeGoogleOidc)

      oidc
    end

    # 認可の要求のパラメータを検査して、値を返す。不備があれば、項目名を挙げて 422 invalid_input
    def validated_values!
      values = FIELD_ORDER.to_h { |name| [ name, params[name] ] }
      invalid = FIELD_ORDER.reject { |name| valid_value?(name, values.fetch(name)) }
      raise Api::Error::InvalidInput.new(fields: invalid, reason: :authorize_params_invalid) unless invalid.empty?

      values
    end

    def valid_value?(name, value)
      return false unless value.is_a?(String)
      return value == EXPECTED_FIXED.fetch(name) if EXPECTED_FIXED.key?(name)
      return value == expected_redirect_uri if name == "redirect_uri"

      TOKEN_PATTERN.match?(value)
    end

    # 戻り先は、公開オリジンの /api/auth/callback だけ（任意の URL へ戻さない）
    def expected_redirect_uri
      public_origin.url_for(CALLBACK_PATH)
    end

    # 選ばれたアカウントのリンク先: redirect_uri?code=…&state=…
    def callback_link(oidc, sub, values)
      code = oidc.issue_code(
        sub: sub, nonce: values.fetch("nonce"), code_challenge: values.fetch("code_challenge"),
        redirect_uri: values.fetch("redirect_uri"), now: current_time
      )
      "#{values.fetch('redirect_uri')}?#{URI.encode_www_form(code: code, state: values.fetch('state'))}"
    end

    # 画面（ERB）。ActionController::Base のレンダラで描く（API のコントローラは、ビューを持たない）
    def render_page(accounts)
      ActionController::Base.render(template: TEMPLATE, layout: false, assigns: { accounts: accounts })
    end
  end
end
