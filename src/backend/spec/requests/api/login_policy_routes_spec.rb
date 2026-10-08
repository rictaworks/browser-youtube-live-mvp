require "rails_helper"
require "support/api_helpers"
require "support/log_capture"

# /api の全動作が、ログインの方針を宣言していること（issue #8。#7 のレビューの提案 P1。OWASP A01・A04）。
# 経路の走査（spec/requests/listener_isolation_spec.rb と同じ形）と、コントローラのファイルの走査の両方で確かめる。
# 後続の issue（#11・#12・#16 など）が API を足すと、この走査が、宣言の書き忘れを検出する。
#   requires_login     ログインが要る動作
#   allow_anonymous    匿名で受ける動作を、明示する（ログイン前の API・疑似の Google など）
# 動作の本体が実行されたことの記録
module LoginPolicyRoutesProbe
  @executions = []

  class << self
    attr_reader :executions
  end
end

RSpec.describe "ログインの方針の宣言（/api の全動作）", type: :request do
  include ApiHelpers
  include_context "API の環境"

  def top_segment(route)
    route.path.spec.to_s.delete_prefix("/").split("/").first.to_s.sub(/\(.*\)\z/, "")
  end

  def controller_class(name)
    "#{name.camelize}Controller".safe_constantize
  end

  # /api の経路が受ける [コントローラ名, 動作名] の一覧
  def api_actions
    Rails.application.routes.routes.filter_map do |route|
      next unless top_segment(route) == "api"

      [ route.defaults[:controller], route.defaults[:action] ]
    end.uniq
  end

  describe "経路の走査" do
    it "/api の経路を受ける、すべての動作は、requires_login か allow_anonymous のどちらか 1 つを宣言している" do
      pairs = api_actions

      expect(pairs.size).to be >= 5 # usage-events・login/start・callback・logout・存在しない経路（開発・テストは、疑似の Google も）
      pairs.each do |controller, action|
        klass = controller_class(controller)
        expect(klass).not_to be_nil, "#{controller} のコントローラが見つからない"
        policy = klass.login_policy_for(action)
        expect(%i[ login anonymous ]).to include(policy), "#{klass}##{action} は、方針が #{policy}（requires_login か allow_anonymous を宣言してください）"
      end
    end

    it "宣言された方針の一覧（ログインが要る API と、匿名で受ける API を、取り違えていない）" do
      expected = {
        [ "api/usage_events", "create" ] => :login,
        [ "api/auth", "login_start" ] => :anonymous,
        [ "api/auth", "callback" ] => :anonymous,
        [ "api/auth", "logout" ] => :login,
        [ "api/base", "route_not_found" ] => :anonymous,
        [ "dev/google", "authorize" ] => :anonymous
      }

      actual = api_actions.to_h { |controller, action| [ [ controller, action ], controller_class(controller).login_policy_for(action) ] }

      expected.each do |pair, policy|
        expect(actual).to include(pair), "#{pair.join('#')} の経路が無い"
        expect(actual.fetch(pair)).to eq(policy), "#{pair.join('#')} は #{policy} のはず（実際: #{actual.fetch(pair)}）"
      end
    end
  end

  # 本物のミドルウェア（リクエスト ID・転送ヘッダの隔離・口の分離）を通る要求で、宣言が無い動作が拒否されることを確かめる。
  # 経路は、このスペックの間だけ、確認用のコントローラ 2 つに差し替える（終わったら、config/routes.rb から引き直す）。
  describe "宣言が無い動作への実際の要求（確認用の経路）" do
    let(:undeclared_probe) do
      Class.new(Api::BaseController) do
        def index
          LoginPolicyRoutesProbe.executions << action_name
          render json: { ran: true }
        end
      end
    end
    let(:declared_probe) do
      Class.new(Api::BaseController) do
        allow_anonymous

        def index
          LoginPolicyRoutesProbe.executions << action_name
          render json: { ran: true }
        end
      end
    end

    before do
      LoginPolicyRoutesProbe.executions.clear
      stub_const("Api::UndeclaredProbeController", undeclared_probe)
      stub_const("Api::DeclaredProbeController", declared_probe)
      Rails.application.routes.draw do
        constraints(PublicListener.new) do
          namespace :api do
            get "probe/undeclared", to: "undeclared_probe#index"
            post "probe/undeclared", to: "undeclared_probe#index"
            get "probe/declared", to: "declared_probe#index"
            match "*unmatched", to: "base#route_not_found", via: :all, format: false
          end
        end
      end
    end

    after { Rails.application.reload_routes! }

    it "宣言が無い動作: 500 internal_error（契約のエラーの形）。本体は実行されない。ログにリクエスト ID と原因" do
      output = capture_logs { api_get "/api/probe/undeclared" }

      expect(response).to have_http_status(500)
      expect(json_body).to eq({ "error" => { "code" => "internal_error", "details" => {} } })
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["Content-Type"]).to eq("application/json; charset=utf-8")
      expect(LoginPolicyRoutesProbe.executions).to be_empty
      expect(output).to match(/\[api\] login policy is not usable policy=undeclared controller=Api::UndeclaredProbeController action=index request_id=\S+/)
    end

    it "宣言が無い動作: ログイン済みでも、状態を変える要求（CSRF の検査を通る POST）でも、同じ" do
      signed_in = sign_in

      api_get "/api/probe/undeclared", signed_in: signed_in
      expect(response).to have_http_status(500)

      api_post "/api/probe/undeclared", { a: 1 }, signed_in: signed_in
      expect(response).to have_http_status(500)
      expect(LoginPolicyRoutesProbe.executions).to be_empty
    end

    it "宣言が無い動作でも、BFF の確認が先（秘密値が無い要求は 403 forbidden）" do
      api_get "/api/probe/undeclared", headers: { "X-BFF-Secret" => nil }

      expect(response).to have_http_status(403)
      expect(error_code).to eq("forbidden")
    end

    it "匿名と宣言した動作は、ログインしていなくても到達できる" do
      api_get "/api/probe/declared"

      expect(response).to have_http_status(:ok)
      expect(json_body).to eq({ "ran" => true })
    end

    it "存在しない経路の 404 は、これまでどおり（匿名と宣言している）" do
      api_get "/api/probe/no-such"

      expect(response).to have_http_status(404)
      expect(error_code).to eq("not_found")
    end
  end

  describe "コントローラのファイルの走査（経路の無い動作も検査する）" do
    # Api::BaseController を継承する、アプリケーションのコントローラ（app/controllers/api と app/controllers/dev の下）
    def api_controller_classes
      files = Dir[Rails.root.join("app/controllers/{api,dev}/**/*_controller.rb").to_s]
      files.filter_map do |file|
        name = Pathname.new(file).relative_path_from(Rails.root.join("app/controllers")).to_s.delete_suffix(".rb").camelize
        klass = name.safe_constantize
        klass if klass && klass < Api::BaseController
      end
    end

    it "検査の対象が空ではない（ファイル名の取り違えで、検査が空にならない）" do
      names = api_controller_classes.map(&:name)

      expect(names).to include("Api::UsageEventsController", "Api::AuthController", "Dev::GoogleController")
    end

    it "各コントローラの動作（public のメソッド。Api::BaseController の動作を除く）は、すべて宣言された方針を持つ" do
      inherited = Api::BaseController.action_methods

      api_controller_classes.each do |klass|
        (klass.action_methods - inherited).each do |action|
          expect(%i[ login anonymous ]).to include(klass.login_policy_for(action)), "#{klass}##{action} が、方針を宣言していない"
        end
      end
    end
  end
end
