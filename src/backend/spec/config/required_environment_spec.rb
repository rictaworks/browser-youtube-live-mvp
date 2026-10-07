require "spec_helper"
require_relative "../../config/app_environment"
require_relative "../../config/required_environment"

# 本番の必須の環境変数の検査（requirements.md 29.4。issue #7）。欠けていれば起動を失敗させる。名前は例外に書き、値は書かない。
RSpec.describe RequiredEnvironment do
  # requirements.md 29.4 の、層が「アプリケーション」の変数（BACKEND_ORIGIN・BACKEND_INTERNAL_URL・RECAPTCHA_SITE_KEY は、他の層）
  expected_names = %w[
    GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET TOKEN_ENCRYPTION_KEY SESSION_SECRET RECAPTCHA_SECRET_KEY
    RELAY_SHARED_SECRET BFF_SHARED_SECRET ADMIN_BASIC_USER ADMIN_BASIC_PASSWORD DATABASE_URL RELAY_PUBLIC_URL
  ]

  let(:production) { AppEnvironment.new("production") }
  let(:complete) { expected_names.to_h { |name| [ name, "dummy-value-of-#{name.downcase}" ] } }

  it "必須の変数は、29.4 のアプリケーション層の 11 個（順も表のとおり）" do
    expect(described_class::NAMES).to eq(expected_names)
    expect(described_class::NAMES).to be_frozen
  end

  describe ".verify!（本番）" do
    it "すべてそろっていれば、何も起こさない" do
      expect { described_class.verify!(production, complete) }.not_to raise_error
    end

    expected_names.each do |name|
      it "#{name} が無ければ、その名前を書いた例外にする" do
        environ = complete.reject { |key, _| key == name }

        expect { described_class.verify!(production, environ) }
          .to raise_error(RequiredEnvironment::MissingError) { |error|
            expect(error.names).to eq([ name ])
            expect(error.message).to include(name)
          }
      end
    end

    it "複数が欠けていれば、すべての名前を、表の順に書く" do
      environ = complete.reject { |key, _| %w[ RELAY_PUBLIC_URL GOOGLE_CLIENT_ID DATABASE_URL ].include?(key) }

      expect { described_class.verify!(production, environ) }
        .to raise_error(RequiredEnvironment::MissingError) { |error|
          expect(error.names).to eq(%w[ GOOGLE_CLIENT_ID DATABASE_URL RELAY_PUBLIC_URL ])
          expect(error.message).to include("GOOGLE_CLIENT_ID", "DATABASE_URL", "RELAY_PUBLIC_URL")
        }
    end

    it "すべてが無ければ、11 個すべての名前を書く" do
      expect { described_class.verify!(production, {}) }
        .to raise_error(RequiredEnvironment::MissingError) { |error| expect(error.names).to eq(expected_names) }
    end

    [ "", " ", "   ", "\t", "\n" ].each do |blank|
      it "空・空白だけ（#{blank.inspect}）は、欠けているとみなす" do
        environ = complete.merge("SESSION_SECRET" => blank)

        expect { described_class.verify!(production, environ) }
          .to raise_error(RequiredEnvironment::MissingError) { |error| expect(error.names).to eq([ "SESSION_SECRET" ]) }
      end
    end

    it "例外のメッセージに、設定されている値を含めない（欠けていない変数の値も、欠けている変数の値も）" do
      environ = complete.merge("BFF_SHARED_SECRET" => " ", "RELAY_SHARED_SECRET" => "dummy-secret-must-not-appear")

      expect { described_class.verify!(production, environ.reject { |key, _| key == "TOKEN_ENCRYPTION_KEY" }) }
        .to raise_error(RequiredEnvironment::MissingError) { |error|
          expect(error.message).not_to include("dummy-secret-must-not-appear")
          expect(error.message).not_to include("dummy-value-of-")
        }
    end

    it "必須の変数に無い、余分な変数があっても通す" do
      expect { described_class.verify!(production, complete.merge("OTHER" => "x")) }.not_to raise_error
    end
  end

  describe ".verify!（開発・テスト）" do
    %w[ development test ].each do |name|
      it "#{name} は、すべてが欠けていても検査しない" do
        expect { described_class.verify!(AppEnvironment.new(name), {}) }.not_to raise_error
      end
    end
  end

  it "MissingError は、欠けた名前の一覧を、凍結して持つ" do
    error = described_class::MissingError.new(%w[ A B ])

    expect(error.names).to eq(%w[ A B ])
    expect(error.names).to be_frozen
  end
end
