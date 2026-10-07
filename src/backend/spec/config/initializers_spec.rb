require "rails_helper"

# 起動時の検査（issue #7）。設定の不備は、黙って既定へ倒さず、起動を失敗させる。
#   config/initializers/required_environment.rb  本番の必須の環境変数
#   config/initializers/listener_ports.rb        PORT が内部側の口と同じ設定
#   config/initializers/request_pipeline.rb      ミドルウェアの構成
RSpec.describe "起動時の検査（initializers）" do
  def load_initializer(name)
    load Rails.root.join("config/initializers/#{name}.rb").to_s
  end

  let(:production) { AppEnvironment.new("production") }
  let(:complete_environment) { RequiredEnvironment::NAMES.to_h { |name| [ name, "dummy-value-of-#{name.downcase}" ] } }

  describe "required_environment.rb" do
    it "本番で、必須の環境変数が欠けていれば、例外にする（起動を失敗させる）。どの名前が欠けているかを書く" do
      allow(AppEnvironment).to receive(:current).and_return(production)
      stub_const("ENV", complete_environment.except("RELAY_SHARED_SECRET", "GOOGLE_CLIENT_ID"))

      expect { load_initializer("required_environment") }
        .to raise_error(RequiredEnvironment::MissingError, /GOOGLE_CLIENT_ID.*RELAY_SHARED_SECRET/)
    end

    it "本番で、すべてそろっていれば、通る" do
      allow(AppEnvironment).to receive(:current).and_return(production)
      stub_const("ENV", complete_environment)

      expect { load_initializer("required_environment") }.not_to raise_error
    end

    %w[ development test ].each do |name|
      it "#{name} は、欠けていても検査しない" do
        allow(AppEnvironment).to receive(:current).and_return(AppEnvironment.new(name))
        stub_const("ENV", {})

        expect { load_initializer("required_environment") }.not_to raise_error
      end
    end

    it "このテストの環境（test）では、起動できている（検査の対象外）" do
      expect(AppEnvironment.current.name).to eq(:test)
    end
  end

  describe "listener_ports.rb" do
    it "PORT が内部側の口（3101）と同じなら、例外にする（内部側の口が、公開側から到達できてしまう）" do
      stub_const("ENV", { "PORT" => "3101" })

      expect { load_initializer("listener_ports") }.to raise_error(ListenerPort::ConfigurationError)
    end

    it "PORT が口の番号として読めなければ、例外にする" do
      stub_const("ENV", { "PORT" => "abc" })

      expect { load_initializer("listener_ports") }.to raise_error(ListenerPort::ConfigurationError)
    end

    it "既定（PORT 無し）・Railway の口（PORT=8080）は、通る" do
      stub_const("ENV", {})
      expect { load_initializer("listener_ports") }.not_to raise_error

      stub_const("ENV", { "PORT" => "8080" })
      expect { load_initializer("listener_ports") }.not_to raise_error
    end
  end

  describe "request_pipeline.rb（ミドルウェアの構成）" do
    let(:names) { Rails.application.middleware.map { |middleware| middleware.klass.name } }

    it "ForwardedHeaders が先頭、ListenerPort が、その次" do
      expect(names.first(2)).to eq(%w[ ForwardedHeaders ListenerPort ])
    end

    it "Rails 標準の Logger の代わりに、IP を出さない RequestLogger を使う" do
      expect(names).to include("RequestLogger")
      expect(names).not_to include("Rails::Rack::Logger")
    end

    it "RequestLogger は、標準の Logger と同じ位置（ShowExceptions の手前）にある" do
      expect(names.index("RequestLogger")).to eq(names.index("ActionDispatch::ShowExceptions") - 1)
    end

    it "RequestLogger には、標準の Logger と同じログのタグ（config.log_tags）を渡している" do
      middleware = Rails.application.middleware.find { |entry| entry.klass == RequestLogger }

      expect(middleware.args).to eq([ Rails.application.config.log_tags ])
    end
  end
end
