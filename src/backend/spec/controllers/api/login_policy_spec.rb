require "rails_helper"
require "support/api_helpers"
require "support/log_capture"

# ログインの方針の宣言（issue #8。#7 のレビューの提案 P1。OWASP A01・A04）。
# /api の各動作は、requires_login（ログインが要る）か allow_anonymous（匿名で受ける）のどちらか 1 つを、明示して宣言する。
# 宣言が無い動作・両方に宣言した動作は、動作の本体を実行せず、500 internal_error（応答に詳細を出さない）。
# 宣言を書き忘れた API が、匿名で到達できる事故を防ぐ。原因は、ログに識別子（コントローラ・動作・リクエスト ID）つきで出す。
# 動作の本体が実行されたことの記録（実行されなかったことを、応答の本文だけでなく、副作用でも確かめる）
module LoginPolicyProbe
  @executions = []

  class << self
    attr_reader :executions
  end
end

RSpec.describe Api::BaseController, "ログインの方針の宣言", type: :controller do
  include ApiHelpers
  include ActiveSupport::Testing::TimeHelpers
  include_context "API の環境"

  let(:internal_error) { { "error" => { "code" => "internal_error", "details" => {} } } }
  let(:executions) { LoginPolicyProbe.executions }

  before { LoginPolicyProbe.executions.clear }

  controller(Api::BaseController) do
    requires_login only: %i[ members_only ]
    allow_anonymous only: %i[ open_action ]

    def members_only
      LoginPolicyProbe.executions << action_name
      render json: { ran: action_name }
    end

    def open_action
      LoginPolicyProbe.executions << action_name
      render json: { ran: action_name }
    end

    # 宣言が無い動作
    def undeclared_action
      LoginPolicyProbe.executions << action_name
      render json: { ran: action_name }
    end
  end

  before do
    routes.draw do
      get "members_only" => "api/base#members_only"
      get "open_action" => "api/base#open_action"
      get "undeclared_action" => "api/base#undeclared_action"
      post "undeclared_action" => "api/base#undeclared_action"
    end
  end

  def verified_request(secret: ApiHelpers::BFF_SECRET)
    request.headers["X-BFF-Secret"] = secret
    request.env[ForwardedHeaders::ENV_KEY] = ForwardedHeaders::Values.new(forwarded_for: "203.0.113.5", forwarded_host: "app.example.test", forwarded_proto: "https")
  end

  describe "宣言した方針どおりに動く" do
    it "requires_login の動作: セッションが無ければ 401 not_logged_in。本体は実行されない" do
      verified_request
      get :members_only

      expect(response).to have_http_status(401)
      expect(JSON.parse(response.body)).to eq({ "error" => { "code" => "not_logged_in", "details" => {} } })
      expect(executions).to be_empty
    end

    it "requires_login の動作: 有効なセッションがあれば、本体が実行される" do
      signed_in = sign_in
      verified_request
      cookies[SessionCookie::NAME] = signed_in.token
      get :members_only

      expect(response).to have_http_status(:ok)
      expect(executions).to eq([ "members_only" ])
    end

    it "allow_anonymous の動作: セッションが無くても、本体が実行される" do
      verified_request
      get :open_action

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq({ "ran" => "open_action" })
      expect(executions).to eq([ "open_action" ])
    end
  end

  describe "宣言が無い動作は、拒否する（fail closed）" do
    it "セッションが無い要求: 500 internal_error。本体は実行されない。詳細を応答に出さない" do
      verified_request
      get :undeclared_action

      expect(response).to have_http_status(500)
      expect(JSON.parse(response.body)).to eq(internal_error)
      expect(executions).to be_empty
    end

    it "ログイン済みの要求でも、同じ（ログインしていれば通る、ではない）" do
      signed_in = sign_in
      verified_request
      cookies[SessionCookie::NAME] = signed_in.token
      get :undeclared_action

      expect(response).to have_http_status(500)
      expect(JSON.parse(response.body)).to eq(internal_error)
      expect(executions).to be_empty
    end

    it "状態を変える要求（POST）でも、本体は実行されない" do
      verified_request
      request.headers["X-BL-Client"] = "web"
      post :undeclared_action

      expect(response).to have_http_status(500)
      expect(executions).to be_empty
    end

    it "応答に、コントローラ・動作・方針の名前を出さない。Cache-Control: no-store。Cookie を設定しない" do
      verified_request
      get :undeclared_action

      expect(response.body).not_to match(/undeclared|policy|controller|requires_login|allow_anonymous|Api::/)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["Content-Type"]).to start_with("application/json")
      expect(response.headers["Set-Cookie"]).to be_nil
    end

    it "原因をログに出す: 方針・コントローラ・動作（応答には出さない）。リクエスト ID は、本物のミドルウェアを通る要求で確かめる" do
      verified_request
      output = capture_logs { get :undeclared_action }

      expect(output).to include("[api] login policy")
      expect(output).to include("policy=undeclared")
      expect(output).to include("controller=Api::BaseController")
      expect(output).to include("action=undeclared_action")
      expect(output).to include("request_id=")
    end

    it "BFF の確認が先: 秘密値が違う要求は、403 forbidden（宣言の有無を、外へ明かさない）" do
      verified_request(secret: "dummy-wrong-secret")
      get :undeclared_action

      expect(response).to have_http_status(403)
      expect(JSON.parse(response.body)).to eq({ "error" => { "code" => "forbidden", "details" => {} } })
    end

    it "拒否した要求で、セッションの最終利用を更新しない（宣言の無い API が、セッションを延命させない）" do
      now = Time.utc(2026, 10, 7, 4, 30, 0)
      signed_in = sign_in(nil, now: now)
      verified_request
      cookies[SessionCookie::NAME] = signed_in.token

      travel_to(now + 1.day) { get :undeclared_action }

      expect(response).to have_http_status(500)
      expect(Session.find(signed_in.session.id).last_used_at).to eq(now)
    end
  end

  describe "両方に宣言した動作は、矛盾なので拒否する" do
    controller(Api::BaseController) do
      requires_login
      allow_anonymous only: %i[ both_action ]

      def both_action
        LoginPolicyProbe.executions << action_name
        render json: { ran: true }
      end
    end

    before do
      routes.draw { get "both_action" => "api/base#both_action" }
    end

    it "500 internal_error。本体は実行されない。ログに policy=conflict" do
      verified_request
      output = capture_logs { get :both_action }

      expect(response).to have_http_status(500)
      expect(JSON.parse(response.body)).to eq(internal_error)
      expect(executions).to be_empty
      expect(output).to include("policy=conflict")
      expect(output).to include("action=both_action")
    end
  end

  describe ".login_policy_for（動作ごとの方針）" do
    def policy_of(login: nil, anonymous: nil, action:)
      klass = Class.new(Api::BaseController) do
        requires_login(**login) unless login.nil?
        allow_anonymous(**anonymous) unless anonymous.nil?
      end
      klass.login_policy_for(action)
    end

    # login / anonymous: nil（宣言しない）または requires_login・allow_anonymous へ渡す引数
    [
      # 宣言が無い
      [ nil, nil, "x", :undeclared ],
      # requires_login だけ
      [ {}, nil, "x", :login ],
      [ { only: %i[ a ] }, nil, "a", :login ],
      [ { only: %i[ a ] }, nil, "b", :undeclared ],
      [ { except: %i[ a ] }, nil, "a", :undeclared ],
      [ { except: %i[ a ] }, nil, "b", :login ],
      # allow_anonymous だけ
      [ nil, {}, "x", :anonymous ],
      [ nil, { only: %i[ a ] }, "a", :anonymous ],
      [ nil, { only: %i[ a ] }, "b", :undeclared ],
      [ nil, { except: %i[ a ] }, "a", :undeclared ],
      [ nil, { except: %i[ a ] }, "b", :anonymous ],
      # 組み合わせ: すべての動作を、どちらかで覆う
      [ { only: %i[ a ] }, { except: %i[ a ] }, "a", :login ],
      [ { only: %i[ a ] }, { except: %i[ a ] }, "b", :anonymous ],
      [ { except: %i[ b ] }, { only: %i[ b ] }, "a", :login ],
      [ { except: %i[ b ] }, { only: %i[ b ] }, "b", :anonymous ],
      # 組み合わせ: 覆われない動作は、宣言が無い
      [ { only: %i[ a ] }, { only: %i[ b ] }, "c", :undeclared ],
      # 矛盾: 同じ動作を、両方に宣言した
      [ {}, {}, "x", :conflict ],
      [ {}, { only: %i[ b ] }, "b", :conflict ],
      [ {}, { only: %i[ b ] }, "a", :login ],
      [ { only: %i[ a b ] }, { only: %i[ b c ] }, "b", :conflict ]
    ].each do |login, anonymous, action, expected|
      it "login=#{login.inspect} anonymous=#{anonymous.inspect} の #{action}: #{expected}" do
        expect(policy_of(login: login, anonymous: anonymous, action: action)).to eq(expected)
      end
    end

    it "動作の名前は、文字列でもシンボルでもよい" do
      klass = Class.new(Api::BaseController) { requires_login only: %i[ a ] }

      expect(klass.login_policy_for(:a)).to eq(:login)
      expect(klass.login_policy_for("a")).to eq(:login)
    end

    it "宣言は、クラスごとに持つ。親・兄弟のクラスへ影響しない" do
      first = Class.new(Api::BaseController) { allow_anonymous }
      second = Class.new(Api::BaseController)

      expect(first.login_policy_for("x")).to eq(:anonymous)
      expect(second.login_policy_for("x")).to eq(:undeclared)
      expect(Api::BaseController.login_policy_for("x")).to eq(:undeclared)
    end

    it "Api::BaseController の動作 route_not_found（存在しない /api の経路の 404）は、匿名と宣言している" do
      expect(Api::BaseController.login_policy_for("route_not_found")).to eq(:anonymous)
      expect(Api::BaseController.anonymous_allowed_for?("route_not_found")).to be(true)
      expect(Api::BaseController.login_required_for?("route_not_found")).to be(false)
    end

    it "anonymous_allowed_for? は、宣言が無ければ false" do
      expect(Api::BaseController.anonymous_allowed_for?("anything")).to be(false)
    end
  end

  describe "共通の部品は、動作として公開されない" do
    it "宣言の確認の部品は private（public のメソッドは、Rails が動作として扱う）" do
      expect(Api::BaseController.private_method_defined?(:declared_login_policy!)).to be(true)
      expect(Api::BaseController.public_method_defined?(:declared_login_policy!)).to be(false)
    end

    it "Api::BaseController の動作は、存在しない経路の 404 だけ（動作を増やしていない）" do
      expect(Api::BaseController.action_methods.to_a).to eq([ "route_not_found" ])
    end
  end
end
