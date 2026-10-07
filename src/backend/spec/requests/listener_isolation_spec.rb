require "rails_helper"
require "support/api_helpers"

# 口の分離（issue #7。requirements.md 6.1・11.9・28.1。src/contracts/internal-api.md 1）。
# /api・/admin・/up は、公開側の口（PORT。既定 3001）だけで応答し、/internal は、内部側の口（3101）だけで応答する。反対側では 404。
# 内部側の口は、外部から到達できない経路でのみ受ける（docker compose の内部ネットワーク・Railway のプライベートネットワーク）。
# テストでは puma.socket が無いので、env["bl.listener_port"] をヘルパーで明示する。実サーバーの確認は、test/pr<番号>/ の curl。
RSpec.describe "口の分離", type: :request do
  include ApiHelpers
  include_context "API の環境"

  let(:not_found) { { "error" => { "code" => "not_found", "details" => {} } } }

  describe "公開側の口" do
    it "/up に 200" do
      get "/up", env: public_listener_env

      expect(response).to have_http_status(:ok)
    end

    it "/api は応答する（BFF の確認を通らなければ 403。経路は、公開側にある）" do
      get "/api/usage-events", env: public_listener_env

      expect(response).to have_http_status(403)
      expect(error_code).to eq("forbidden")
    end

    it "/api/usage-events（POST）は応答する" do
      api_post "/api/usage-events", { event_type: "watch_url_copied" }, signed_in: sign_in

      expect(response).to have_http_status(204)
    end

    %w[ /internal /internal/ /internal/v1/verify /internal/v1/broadcasts/00000000-0000-0000-0000-000000000000/heartbeat ].each do |path|
      it "#{path} は 404（内部通信の経路は、公開側の口では応答しない）" do
        get path, headers: { "X-Relay-Secret" => "dummy-relay-secret" }, env: public_listener_env
        expect(response).to have_http_status(404)
        expect(json_body).to eq(not_found)

        post path, headers: { "X-Relay-Secret" => "dummy-relay-secret" }, params: "{}", env: public_listener_env
        expect(response).to have_http_status(404)
        expect(json_body).to eq(not_found)
      end
    end
  end

  describe "内部側の口" do
    # 内部側の口に届く要求は、BFF の秘密値を持っていても、/api・/admin・/up に応答しない
    {
      "/up" => :get,
      "/api/usage-events" => :post,
      "/api/usage-events（GET）" => :get,
      "/api/state" => :get,
      "/api/no-such-endpoint" => :get,
      "/admin" => :get,
      "/admin/" => :get,
      "/admin/broadcasts" => :get
    }.each do |label, verb|
      it "#{label} は 404（公開側の経路は、内部側の口では応答しない）" do
        path = label.split("（").first
        public_send(verb, path, headers: api_headers(state_changing: verb == :post), env: internal_listener_env)

        expect(response).to have_http_status(404)
        expect(json_body).to eq(not_found)
      end
    end

    it "ログイン済みの正しい要求でも、/api は 404（記録を作らない）" do
      signed_in = sign_in

      expect do
        post "/api/usage-events",
             params: JSON.generate({ event_type: "watch_url_copied" }),
             headers: api_headers(signed_in: signed_in, state_changing: true).merge("Content-Type" => "application/json"),
             env: internal_listener_env
      end.not_to change(UsageEvent, :count)

      expect(response).to have_http_status(404)
    end

    it "404 の応答は、BFF の確認・CSRF の検査を行わない（経路の存在を、明かさない。秘密値の有無で、応答が変わらない）" do
      get "/api/usage-events", env: internal_listener_env
      without_secret = [ response.status, response.body ]
      get "/api/usage-events", headers: bff_headers, env: internal_listener_env

      expect([ response.status, response.body ]).to eq(without_secret)
      expect(response).to have_http_status(404)
    end

    it "404 の応答は、JSON・Cache-Control: no-store" do
      get "/api/usage-events", env: internal_listener_env

      expect(response.headers["Content-Type"]).to eq("application/json; charset=utf-8")
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
  end

  describe "どちらの口でもない（設定の誤り）" do
    let(:other) { { ListenerPort::ENV_KEY => 3999 } }

    it "公開側・内部側のどちらの経路にも、応答しない（404）" do
      get "/up", env: other
      expect(response).to have_http_status(404)

      get "/api/usage-events", headers: bff_headers, env: other
      expect(response).to have_http_status(404)

      get "/internal/v1/verify", env: other
      expect(response).to have_http_status(404)
    end
  end

  describe "口の番号が分からない" do
    it "puma.socket も、明示した口の番号も無い要求は、例外にする（黙って公開側と見なさない）" do
      expect { get "/up" }.to raise_error(ListenerPort::UnknownPortError)
    end

    it "/api も、同じ（BFF の確認より前に、例外）" do
      expect { get "/api/usage-events", headers: bff_headers }.to raise_error(ListenerPort::UnknownPortError)
    end

    it "存在しない経路でも、同じ（404 にしない）" do
      expect { get "/no-such-path" }.to raise_error(ListenerPort::UnknownPortError)
    end
  end

  describe "公開側の口の番号は、環境変数 PORT" do
    around do |example|
      original = ENV.fetch("PORT", nil)
      ENV["PORT"] = "8080"
      example.run
    ensure
      ENV["PORT"] = original
    end

    it "PORT=8080 のとき、口 8080 は公開側、口 3001 はどちらでもない、口 3101 は内部側" do
      get "/up", env: { ListenerPort::ENV_KEY => 8080 }
      expect(response).to have_http_status(:ok)

      get "/up", env: { ListenerPort::ENV_KEY => 3001 }
      expect(response).to have_http_status(404)

      get "/up", env: { ListenerPort::ENV_KEY => 3101 }
      expect(response).to have_http_status(404)
    end
  end

  describe "ルーティングの構造（後続の issue が、経路を足しても、分離を崩さない）" do
    # 経路の先頭の区間 => 応答してよい口
    expectations = { "api" => PublicListener, "admin" => PublicListener, "up" => PublicListener, "internal" => InternalListener }

    def listener_of(route)
      app = route.app
      return nil unless app.respond_to?(:constraints)

      app.constraints.find { |constraint| constraint.is_a?(PublicListener) || constraint.is_a?(InternalListener) }
    end

    def top_segment(route)
      route.path.spec.to_s.delete_prefix("/").split("/").first.to_s.sub(/\(.*\)\z/, "")
    end

    it "/api・/admin・/up の経路は、PublicListener の制約の中にあり、/internal の経路は、InternalListener の制約の中にある" do
      routes = Rails.application.routes.routes.reject { |route| route.path.spec.to_s.start_with?("/rails/") }
      checked = 0

      routes.each do |route|
        segment = top_segment(route)
        expected = expectations[segment]
        next unless expected

        checked += 1
        expect(listener_of(route)).to be_a(expected), "#{route.verb} #{route.path.spec} は、#{expected} の制約の外にある"
      end

      expect(checked).to be >= 3 # /up・/api/usage-events・/api の存在しない経路
    end

    it "最後の経路は、どの口でも 404 を返す、すべての経路に一致する経路（反対側の口の経路を含む）" do
      last = Rails.application.routes.routes.to_a.last

      expect(last.path.spec.to_s).to start_with("/*")
      expect(listener_of(last)).to be_nil
    end

    it "/api の経路を受ける、すべてのコントローラは、Api::BaseController を継承する（BFF の確認・CSRF の検査を、必ず通る）" do
      controllers = Rails.application.routes.routes.filter_map do |route|
        next unless top_segment(route) == "api"

        route.defaults[:controller]
      end.uniq

      expect(controllers).not_to be_empty
      controllers.each do |name|
        klass = "#{name.camelize}Controller".safe_constantize
        expect(klass).not_to be_nil, "#{name} のコントローラが見つからない"
        expect(klass.ancestors).to include(Api::BaseController), "#{klass} が Api::BaseController を継承していない"
      end
    end
  end
end
