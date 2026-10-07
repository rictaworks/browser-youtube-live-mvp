require "rails_helper"

# Cookie の属性（issue #7。requirements.md 7.1・28.1。src/contracts/http-api.md 1.3）。
#   bl_session  セッション識別子のみ。HttpOnly・SameSite=Lax・Path=/。本番は Secure。有効期限の属性は付けない（ブラウザのセッション Cookie）
#   bl_oauth    認可の途中の状態（暗号化）。HttpOnly・SameSite=Lax・Path=/・Max-Age=600。本番は Secure
# 開発・テストは http のため、Secure を付けない（付けると、ブラウザは Cookie を保存しない）。本番は HTTPS のみ。
RSpec.describe CookiePolicy do
  {
    "development" => false,
    "test" => false,
    "production" => true
  }.each do |name, expected|
    it "#{name} の Secure は #{expected}" do
      expect(described_class.secure?(AppEnvironment.new(name))).to be(expected)
    end
  end

  it "環境を省略すると、現在の環境（テストは Secure なし）" do
    expect(described_class.secure?).to be(false)
  end
end

RSpec.describe SessionCookie do
  let(:token) { "dummy-session-token-0123456789abcdefghijklmnop" }
  let(:production) { AppEnvironment.new("production") }
  let(:development) { AppEnvironment.new("development") }

  it "名前は bl_session" do
    expect(described_class::NAME).to eq("bl_session")
  end

  describe ".attributes" do
    it "開発・テスト（http）: 値は識別子のみ・HttpOnly・SameSite=Lax・Path=/。Secure は付けない" do
      expect(described_class.attributes(token, environment: development)).to eq(
        value: token, httponly: true, same_site: :lax, path: "/", secure: false
      )
    end

    it "本番: Secure を付ける" do
      expect(described_class.attributes(token, environment: production)).to eq(
        value: token, httponly: true, same_site: :lax, path: "/", secure: true
      )
    end

    it "有効期限の属性（expires・max_age）を付けない（ブラウザのセッション Cookie。期限はサーバー側で、最終利用から 30 日）" do
      attributes = described_class.attributes(token, environment: production)

      expect(attributes).not_to have_key(:expires)
      expect(attributes).not_to have_key(:max_age)
    end

    it "環境を省略すると、現在の環境（テスト）" do
      expect(described_class.attributes(token)).to include(secure: false)
    end

    [ nil, "", " ", 123 ].each do |value|
      it "識別子 #{value.inspect} は、例外にする" do
        expect { described_class.attributes(value) }.to raise_error(ArgumentError)
      end
    end
  end

  describe ".expiry_attributes（失効させる Cookie）" do
    it "値を持たず、Path・HttpOnly・SameSite が、発行のときと同じ" do
      expect(described_class.expiry_attributes(environment: development)).to eq(httponly: true, same_site: :lax, path: "/", secure: false)
      expect(described_class.expiry_attributes(environment: production)).to eq(httponly: true, same_site: :lax, path: "/", secure: true)
    end
  end
end
