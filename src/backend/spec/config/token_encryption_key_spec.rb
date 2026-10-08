require "rails_helper"

# 起動時の検査: TOKEN_ENCRYPTION_KEY の形式（issue #11。#10 のレビューの申し送り。requirements.md 7.3・28.1・29.4）。
# 更新トークンの暗号鍵は、64 桁の 16 進数（32 バイト）。形式の検査（TokenVault.parse_key）が、初回の使用時にしか働かないと、
# 形式の誤りが、最初の YouTube 接続（利用者の操作）まで見つからない。そこで、起動時（config/initializers/token_encryption_key.rb）に検査し、
# 形式が誤りなら、環境を問わず、起動を失敗させる。メッセージは、変数の名前と期待する形式だけ（値を書かない）。
#   設定されていて、形式が誤り       起動を失敗させる（開発・テスト・本番のすべて）
#   未設定・空・空白だけ            この検査では通す。本番は、必須の環境変数の検査（RequiredEnvironment）が、先に止める。
#                                   開発・テストは、疑似を使う最初の使用で止まる（CI は、鍵なしで DB の準備・RSpec を動かす）
RSpec.describe "起動時の検査: TOKEN_ENCRYPTION_KEY の形式" do
  let(:valid_key) { "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }

  def load_initializer
    load Rails.root.join("config/initializers/token_encryption_key.rb").to_s
  end

  def with_environment(name, environ)
    allow(AppEnvironment).to receive(:current).and_return(AppEnvironment.new(name))
    stub_const("ENV", environ)
  end

  %w[ development test production ].each do |name|
    describe "#{name}（環境を問わない）" do
      it "形式が正しければ、通る" do
        with_environment(name, { "TOKEN_ENCRYPTION_KEY" => valid_key })

        expect { load_initializer }.not_to raise_error
      end

      it "大文字の 16 進数でも、通る（TokenVault.parse_key と同じ規則）" do
        with_environment(name, { "TOKEN_ENCRYPTION_KEY" => valid_key.upcase })

        expect { load_initializer }.not_to raise_error
      end

      [
        [ "短い（63 桁）", "a" * 63 ],
        [ "長い（65 桁）", "a" * 65 ],
        [ "16 進数でない文字を含む（g）", "g" * 64 ],
        [ "前後に空白を含む", " #{'a' * 64} " ],
        [ "末尾に改行を含む", "#{'a' * 64}\n" ],
        [ "途中に空白を含む", "#{'a' * 32} #{'a' * 31}" ],
        [ "16 進数でなく、長さだけ合っている", "z" * 64 ]
      ].each do |label, bad_key|
        it "設定されていて、形式が誤り（#{label}）: 起動を失敗させる（InvalidKey）。変数の名前を書き、値を書かない" do
          with_environment(name, { "TOKEN_ENCRYPTION_KEY" => bad_key })

          expect { load_initializer }.to raise_error(TokenVault::InvalidKey) { |error|
            expect(error.message).to include("TOKEN_ENCRYPTION_KEY")
            expect(error.message).not_to include(bad_key.strip) unless bad_key.strip.empty?
          }
        end
      end

      it "未設定・空・空白だけは、この検査では通す（欠落の検査は、本番の必須の環境変数の検査と、疑似の最初の使用）" do
        [ {}, { "TOKEN_ENCRYPTION_KEY" => "" }, { "TOKEN_ENCRYPTION_KEY" => "   " }, { "TOKEN_ENCRYPTION_KEY" => "\n" } ].each do |environ|
          with_environment(name, environ)

          expect { load_initializer }.not_to raise_error
        end
      end
    end
  end

  it "本番で、未設定なら、必須の環境変数の検査（RequiredEnvironment）が、起動を失敗させる（この検査より先）" do
    environ = RequiredEnvironment::NAMES.to_h { |env_name| [ env_name, "dummy-value-of-#{env_name.downcase}" ] }.except("TOKEN_ENCRYPTION_KEY")

    expect { RequiredEnvironment.verify!(AppEnvironment.new("production"), environ) }
      .to raise_error(RequiredEnvironment::MissingError) { |error| expect(error.names).to eq([ "TOKEN_ENCRYPTION_KEY" ]) }
  end

  it "検査には、TokenVault.parse_key を使う（形式の規則を、2 か所に持たない）" do
    source = Rails.root.join("config/initializers/token_encryption_key.rb").read

    expect(source).to include("TokenVault.parse_key")
    expect(source).not_to match(/\\h\{64\}|\[0-9a-fA-F\]/)
  end

  it "このテストの環境でも、起動できている（開発の .env の鍵は、形式が正しい）" do
    key = ENV.fetch("TOKEN_ENCRYPTION_KEY", nil)

    expect(key.nil? || key.strip.empty? || key.match?(TokenVault::KEY_FORMAT)).to be(true)
  end
end
