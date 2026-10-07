require "spec_helper"
require_relative "../../config/app_environment"

RSpec.describe AppEnvironment do
  describe ".new" do
    {
      "development" => :development,
      "test" => :test,
      "production" => :production,
      :test => :test
    }.each do |input, expected|
      it "#{input.inspect} は #{expected.inspect} になる" do
        expect(described_class.new(input).name).to eq(expected)
      end
    end

    [ "staging", "prod", "Production", " test", "", nil ].each do |input|
      it "未知の値 #{input.inspect} は例外にする（既定の環境へ倒さない）" do
        expect { described_class.new(input) }
          .to raise_error(AppEnvironment::UnknownEnvironmentError, /unknown environment/)
      end
    end
  end

  describe "#external_services" do
    {
      "development" => :fake,
      "test" => :fake,
      "production" => :live
    }.each do |name, expected|
      it "#{name} は #{expected.inspect}" do
        expect(described_class.new(name).external_services).to eq(expected)
      end
    end
  end

  describe "環境の問い合わせ" do
    it "development? は development だけ true" do
      expect(described_class.new("development")).to be_development
      expect(described_class.new("test")).not_to be_development
      expect(described_class.new("production")).not_to be_development
    end

    it "test? は test だけ true" do
      expect(described_class.new("test")).to be_test
      expect(described_class.new("development")).not_to be_test
    end

    it "production? は production だけ true" do
      expect(described_class.new("production")).to be_production
      expect(described_class.new("development")).not_to be_production
      expect(described_class.new("test")).not_to be_production
    end
  end

  describe "#session_secret" do
    let(:secret) { "dummy-session-secret-for-spec" }

    context "production" do
      subject(:environment) { described_class.new("production") }

      it "SESSION_SECRET があれば、その値を返す" do
        expect(environment.session_secret({ "SESSION_SECRET" => secret })).to eq(secret)
      end

      it "SESSION_SECRET が未設定なら例外にする（起動を失敗させる）" do
        expect { environment.session_secret({}) }
          .to raise_error(AppEnvironment::InvalidSecretError, /SESSION_SECRET is required/)
      end

      it "SESSION_SECRET が空・空白だけなら例外にする" do
        [ "", "   " ].each do |blank|
          expect { environment.session_secret({ "SESSION_SECRET" => blank }) }
            .to raise_error(AppEnvironment::InvalidSecretError)
        end
      end

      it "公開されている開発用の値は、本番では使わせない" do
        expect { environment.session_secret({ "SESSION_SECRET" => AppEnvironment::DEVELOPMENT_SESSION_SECRET }) }
          .to raise_error(AppEnvironment::InvalidSecretError, /development value/)
      end

      it "例外のメッセージに、設定された値を含めない" do
        expect { environment.session_secret({ "SESSION_SECRET" => AppEnvironment::DEVELOPMENT_SESSION_SECRET }) }
          .to raise_error { |error| expect(error.message).not_to include(AppEnvironment::DEVELOPMENT_SESSION_SECRET) }
      end
    end

    %w[ development test ].each do |name|
      context name do
        subject(:environment) { described_class.new(name) }

        it "SESSION_SECRET があれば、その値を返す" do
          expect(environment.session_secret({ "SESSION_SECRET" => secret })).to eq(secret)
        end

        it "SESSION_SECRET が未設定なら、明示した開発用の値を返す" do
          expect(environment.session_secret({})).to eq(AppEnvironment::DEVELOPMENT_SESSION_SECRET)
        end

        it "SESSION_SECRET が空なら、明示した開発用の値を返す" do
          expect(environment.session_secret({ "SESSION_SECRET" => "" })).to eq(AppEnvironment::DEVELOPMENT_SESSION_SECRET)
        end
      end
    end
  end

  describe "DEVELOPMENT_SESSION_SECRET" do
    it "開発用だと分かる値で、Rails の署名鍵として使える長さがある" do
      expect(AppEnvironment::DEVELOPMENT_SESSION_SECRET).to include("development-only")
      expect(AppEnvironment::DEVELOPMENT_SESSION_SECRET.length).to be >= 64
    end
  end
end
