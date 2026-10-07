require "spec_helper"
require "puma"
require "puma/configuration"
require_relative "../../config/server_ports"

# Puma が、公開側（PORT。既定 3001）と内部通信（3101）の 2 つの口で待ち受ける設定であること。
# Puma の設定を読むだけで、サーバーは起動しない（Rails も DB も使わない）。
RSpec.describe "config/puma.rb" do
  let(:config_path) { File.expand_path("../../config/puma.rb", __dir__) }

  # 環境変数を一時的に差し替える。値が nil なら、その環境変数を未設定にする（ENV[key] = nil は未設定にする）
  def with_env(overrides)
    original = overrides.keys.to_h { |key| [ key, ENV[key] ] }
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    original.each { |key, value| ENV[key] = value }
  end

  def puma_options(env = {})
    with_env({ "PORT" => nil, "RAILS_MAX_THREADS" => nil }.merge(env)) do
      configuration = Puma::Configuration.new({ config_files: [ config_path ] })
      configuration.load
      configuration.clamp
      configuration.options
    end
  end

  describe "待ち受ける口" do
    it "PORT が未設定なら、公開側は 3001、内部側は 3101 の 2 つで待ち受ける" do
      expect(puma_options[:binds]).to eq([ "tcp://0.0.0.0:3001", "tcp://0.0.0.0:3101" ])
    end

    it "PORT があれば、公開側はその口にする（内部側は変わらない）" do
      expect(puma_options("PORT" => "8080")[:binds]).to eq([ "tcp://0.0.0.0:8080", "tcp://0.0.0.0:3101" ])
    end

    it "内部側の口の番号は、環境変数ではなく、設定の定数（ServerPorts::INTERNAL）である" do
      expect(ServerPorts::INTERNAL).to eq(3101)
      expect(ServerPorts::PUBLIC_DEFAULT).to eq(3001)
      expect(puma_options("PORT" => "8080", "INTERNAL_PORT" => "9999")[:binds].last).to eq("tcp://0.0.0.0:3101")
    end
  end

  describe "スレッド" do
    it "RAILS_MAX_THREADS が未設定なら 3" do
      options = puma_options

      expect([ options[:min_threads], options[:max_threads] ]).to eq([ 3, 3 ])
    end

    it "RAILS_MAX_THREADS があれば、その数" do
      options = puma_options("RAILS_MAX_THREADS" => "5")

      expect([ options[:min_threads], options[:max_threads] ]).to eq([ 5, 5 ])
    end
  end
end
