# 疑似の Google の同意画面（YouTube 接続。issue #11）。開発・テストのみ。契約の外（src/contracts/http-api.md 1.1）。
#
#   GET /api/dev/google/connect          FakeGoogleOidc#youtube_authorization_url が返す行き先。認可の要求のパラメータを、本物に求める値と同じか検査してから
#                                        （スコープは youtube の 1 種・offline・consent・PKCE の S256・戻り先は公開オリジンの YouTube 接続のコールバック・
#                                        include_granted_scopes と nonce は無い）、選択肢（リンク）を表示する。表示は、識別子（SCENARIOS）だけ
#   GET /api/dev/google/connect/choose   選択肢を選ぶと、戻り先へ 302 で戻す。同意した選択肢は認可コード、拒否は error=access_denied を付ける。
#                                        チャンネルが無い・ライブ未有効・確認不能の選択肢は、疑似の YouTube（FakeYouTubeGateway）へ失敗を注入してから戻す
#                                        （ブラウザから、接続の不成立を再現するため。注入は次の確認の 1 回だけ）
#
# ログインの疑似の画面（Dev::GoogleController）と同じ作り: 本番には存在しない ① 経路を描かない（config/routes.rb。環境の判定で決める。本番では 404 not_found）
# ② 使っている実装が疑似でなければ（実物が選ばれているなら）、画面を出さない ③ 疑似の実装は、本番で構築できない（FakeServices）。
# 開発者向けの近道（接続済みの状態を直接作る経路）は、持たない: 利用者の操作は、本番と同じ経路（アカウント画面の「YouTube を接続」-> connect/start ->
# この画面 -> コールバック）。Api::BaseController を継承する（BFF の確認・公開オリジン・エラーの形）。ブラウザからは、同一オリジン中継（BFF）を通って届く。
# パラメータを厳しく検査してから、画面を作る（HTML・URL を壊す文字を受け付けない）。ERB の最小のページ。コード・state をログに出さない。
module Dev
  class GoogleConnectController < Api::BaseController
    allow_anonymous

    # 選択肢 1 つ。key は画面に表示する識別子。grant は付与の種類（FakeGoogleOidc::YOUTUBE_GRANT_KINDS。nil は、利用者の拒否）。
    # failure は、疑似の YouTube へ注入する失敗（error と、効かせる呼び出しの種別 on）。nil は注入しない
    Scenario = Data.define(:key, :grant, :failure)

    SCENARIOS = [
      Scenario.new(key: "allow", grant: FakeGoogleOidc::FULL, failure: nil),
      Scenario.new(key: "allow_live_not_enabled", grant: FakeGoogleOidc::FULL, failure: { error: :live_not_enabled, on: :probe_live_enabled }.freeze),
      Scenario.new(key: "allow_no_channel", grant: FakeGoogleOidc::FULL, failure: { error: :no_channel, on: :probe_channel_lookup }.freeze),
      Scenario.new(key: "allow_unverifiable", grant: FakeGoogleOidc::FULL, failure: { error: :transient, on: :probe_channel_lookup }.freeze),
      Scenario.new(key: "allow_without_youtube", grant: FakeGoogleOidc::WITHOUT_YOUTUBE_SCOPE, failure: nil),
      Scenario.new(key: "allow_without_refresh_token", grant: FakeGoogleOidc::WITHOUT_REFRESH_TOKEN, failure: nil),
      Scenario.new(key: "deny", grant: nil, failure: nil)
    ].freeze

    # 値が決まっている項目（本物の認可の要求と同じ。スコープは設定、戻り先は公開オリジンのコールバックから決まる）
    EXPECTED_FIXED = {
      "response_type" => "code",
      "code_challenge_method" => GoogleOidcClient::CODE_CHALLENGE_METHOD,
      "access_type" => GoogleOidcClient::YOUTUBE_ACCESS_TYPE,
      "prompt" => GoogleOidcClient::YOUTUBE_PROMPT
    }.freeze
    # 検査する項目の順（不備のある項目を、この順に挙げる）
    FIELD_ORDER = %w[ response_type scope redirect_uri state code_challenge code_challenge_method access_type prompt login_hint ].freeze
    # 付けてはいけない項目（過去の付与を混ぜない・ID トークンを使わない）。付いていれば、不備として挙げる
    FORBIDDEN_FIELDS = %w[ include_granted_scopes nonce ].freeze
    # state・code_challenge は、base64url の文字だけ（本物の値は 43 文字）。login_hint は、Google の識別子（sub）の文字だけ
    TOKEN_PATTERN = /\A[A-Za-z0-9_-]{1,#{OAuthStateCookie::MAX_FIELD_LENGTH}}\z/
    LOGIN_HINT_PATTERN = /\A[A-Za-z0-9_-]{1,255}\z/
    # 拒否のときに戻り先へ付ける error（Google と同じ値）
    DENIED_ERROR = YouTubeConnectService::DENIED_ERROR
    TEMPLATE = "dev/google_connect/consent".freeze

    def consent
      oidc = fake_oidc!
      values = validated_values!(oidc)
      render body: render_page(values), content_type: "text/html; charset=utf-8"
    end

    def choose
      oidc = fake_oidc!
      values = validated_values!(oidc)
      scenario = scenario!
      inject_failure(scenario)
      redirect_to return_url(oidc, scenario, values), allow_other_host: true, status: :found
    end

    private

    # 使っている実装が疑似の Google でなければ、画面を出さない（存在しないものとして 404）
    def fake_oidc!
      oidc = ExternalServices.current.google_oidc
      raise Api::Error::NotFound.new(reason: :fake_google_unavailable) unless oidc.is_a?(FakeGoogleOidc)

      oidc
    end

    # 認可の要求のパラメータを検査して、値（付けてはいけない項目を除く）を返す。不備があれば、項目名を挙げて 422 invalid_input
    def validated_values!(oidc)
      values = FIELD_ORDER.to_h { |name| [ name, params[name] ] }
      invalid = FIELD_ORDER.reject { |name| valid_value?(name, values.fetch(name), oidc) }
      invalid += FORBIDDEN_FIELDS.select { |name| params.key?(name) }
      raise Api::Error::InvalidInput.new(fields: invalid, reason: :authorize_params_invalid) unless invalid.empty?

      values
    end

    def valid_value?(name, value, oidc)
      return false unless value.is_a?(String)
      return value == EXPECTED_FIXED.fetch(name) if EXPECTED_FIXED.key?(name)
      return value == oidc.youtube_scope if name == "scope"
      return value == expected_redirect_uri if name == "redirect_uri"
      return LOGIN_HINT_PATTERN.match?(value) if name == "login_hint"

      TOKEN_PATTERN.match?(value)
    end

    # 戻り先は、公開オリジンの YouTube 接続のコールバックだけ（任意の URL へ戻さない）
    def expected_redirect_uri
      public_origin.url_for(Api::YoutubeController::CALLBACK_PATH)
    end

    def scenario!
      key = params[:scenario]
      scenario = SCENARIOS.find { |candidate| key.is_a?(String) && candidate.key == key }
      raise Api::Error::InvalidInput.new(fields: %w[ scenario ], reason: :scenario_invalid) if scenario.nil?

      scenario
    end

    # 失敗を注入する選択肢は、疑似の YouTube へ、次の確認の 1 回だけの失敗を仕込む（同じプロセスの疑似の YouTube。YouTubeServices が共有する）
    def inject_failure(scenario)
      failure = scenario.failure
      return if failure.nil?

      gateway = YouTubeServices.current.youtube_gateway
      raise Api::Error::NotFound.new(reason: :fake_youtube_unavailable) unless gateway.is_a?(FakeYouTubeGateway)

      gateway.fail_next(failure.fetch(:error), on: failure.fetch(:on))
    end

    # 戻り先の URL: redirect_uri?code=…&state=…（同意）または redirect_uri?error=access_denied&state=…（拒否）
    def return_url(oidc, scenario, values)
      redirect_uri = values.fetch("redirect_uri")
      state = values.fetch("state")
      query =
        if scenario.grant.nil?
          URI.encode_www_form(error: DENIED_ERROR, state: state)
        else
          code = oidc.issue_youtube_code(
            kind: scenario.grant, code_challenge: values.fetch("code_challenge"), redirect_uri: redirect_uri, now: current_time
          )
          URI.encode_www_form(code: code, state: state)
        end
      "#{redirect_uri}?#{query}"
    end

    # 画面（ERB）。ActionController::Base のレンダラで描く（API のコントローラは、ビューを持たない）
    def render_page(values)
      choices = SCENARIOS.map { |scenario| { label: scenario.key, href: choose_path(values, scenario) } }
      ActionController::Base.render(
        template: TEMPLATE, layout: false,
        assigns: { choices: choices, scope: values.fetch("scope"), login_hint: values.fetch("login_hint") }
      )
    end

    # 選択の経路（同一オリジンの相対パス）。同じ認可の要求のパラメータと、選択肢の識別子
    def choose_path(values, scenario)
      "#{api_dev_google_connect_choose_path}?#{URI.encode_www_form(values.merge('scenario' => scenario.key))}"
    end
  end
end
