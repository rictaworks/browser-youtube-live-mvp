require "rails_helper"

# フロントエンド（BFF）からの要求であることの確認（issue #7。requirements.md 6.1・28.1。src/contracts/http-api.md 1.2）。
# X-BFF-Secret（環境変数 BFF_SHARED_SECRET）を、定数時間で比較する。確認を通った要求からだけ、転送ヘッダ（IP・公開オリジン）を読める。
RSpec.describe BffGuard do
  let(:secret) { "dummy-bff-shared-secret-for-guard-spec" }
  let(:guard) { described_class.new(secret: secret) }
  let(:forwarded) do
    ForwardedHeaders::Values.new(forwarded_for: "203.0.113.5", forwarded_host: "app.example.test", forwarded_proto: "https")
  end

  describe "#verify!" do
    it "秘密値が一致すれば、確認を通った要求（VerifiedBffRequest）を返す" do
      verified = guard.verify!(secret, forwarded)

      expect(verified).to be_a(VerifiedBffRequest)
    end

    # 欠落・不一致は、すべて同じ例外（手がかりを返さない）
    {
      "欠落（nil）" => nil,
      "空" => "",
      "空白" => " ",
      "1 文字違い" => "dummy-bff-shared-secret-for-guard-spez",
      "短い（前方一致）" => "dummy-bff-shared-secret",
      "長い（後ろに足した）" => "dummy-bff-shared-secret-for-guard-spec-extra",
      "大文字・小文字の違い" => "DUMMY-BFF-SHARED-SECRET-FOR-GUARD-SPEC",
      "前後の空白" => " dummy-bff-shared-secret-for-guard-spec ",
      "文字列でない（数値）" => 123,
      "文字列でない（配列）" => [ "dummy-bff-shared-secret-for-guard-spec" ]
    }.each do |label, presented|
      it "#{label}は、Rejected にする" do
        expect { guard.verify!(presented, forwarded) }.to raise_error(BffGuard::Rejected)
      end
    end

    it "拒否の例外のメッセージに、秘密値・提示された値を含めない" do
      expect { guard.verify!("dummy-presented-must-not-appear", forwarded) }
        .to raise_error(BffGuard::Rejected) do |error|
          expect(error.message).not_to include("dummy-presented-must-not-appear")
          expect(error.message).not_to include(secret)
        end
    end

    it "定数時間の比較を使う（先頭からの 1 文字ずつの比較ではない）" do
      expect(ActiveSupport::SecurityUtils).to receive(:fixed_length_secure_compare).at_least(:once).and_call_original

      guard.verify!(secret, forwarded)
    end

    it "長さの違いでも、比較の経路が変わらない（要約値どうしを、同じ長さで比較する）" do
      calls = []
      allow(ActiveSupport::SecurityUtils).to receive(:fixed_length_secure_compare).and_wrap_original do |original, left, right|
        calls << [ left.bytesize, right.bytesize ]
        original.call(left, right)
      end

      [ "", "x", secret, "#{secret}-long-long-long" ].each do |presented|
        guard.verify!(presented, forwarded)
      rescue BffGuard::Rejected
        nil
      end

      expect(calls.size).to eq(4)
      expect(calls.uniq).to eq([ [ 32, 32 ] ])
    end
  end

  describe ".new（秘密値が空なら、起動できない）" do
    [ nil, "", "  " ].each do |value|
      it "秘密値 #{value.inspect} は、例外にする（空の秘密値で、すべての要求を通さない）" do
        expect { described_class.new(secret: value) }.to raise_error(BffGuard::NotConfiguredError)
      end
    end
  end

  describe ".from_environment" do
    it "環境変数 BFF_SHARED_SECRET から作る" do
      guard = described_class.from_environment({ "BFF_SHARED_SECRET" => secret })

      expect { guard.verify!(secret, forwarded) }.not_to raise_error
    end

    [ {}, { "BFF_SHARED_SECRET" => "" }, { "BFF_SHARED_SECRET" => "   " } ].each do |environ|
      it "BFF_SHARED_SECRET が未設定・空（#{environ.inspect}）なら、NotConfiguredError にする（名前だけを書く）" do
        expect { described_class.from_environment(environ) }
          .to raise_error(BffGuard::NotConfiguredError, /BFF_SHARED_SECRET/)
      end
    end

    it "環境変数の名前は、requirements.md 29.4 のとおり" do
      expect(described_class::ENV_NAME).to eq("BFF_SHARED_SECRET")
    end
  end
end

RSpec.describe VerifiedBffRequest do
  def verified(forwarded_for: "203.0.113.5", forwarded_host: "app.example.test", forwarded_proto: "https")
    described_class.new(ForwardedHeaders::Values.new(forwarded_for: forwarded_for, forwarded_host: forwarded_host, forwarded_proto: forwarded_proto))
  end

  describe "#client_ip" do
    it "X-Forwarded-For の先頭から作る" do
      expect(verified(forwarded_for: "203.0.113.5, 10.0.0.1").client_ip.to_s).to eq("203.0.113.5")
    end

    it "ヘッダが無い・IP として読めなければ、不明（別の値で補わない）" do
      expect(verified(forwarded_for: nil).client_ip).not_to be_known
      expect(verified(forwarded_for: "abc").client_ip).not_to be_known
    end
  end

  describe "#public_origin" do
    it "X-Forwarded-Host・X-Forwarded-Proto から作る" do
      expect(verified.public_origin.to_s).to eq("https://app.example.test")
    end

    it "ヘッダが無い・正しくなければ、例外にする（必要になったときに）" do
      expect { verified(forwarded_host: nil).public_origin }.to raise_error(PublicOrigin::InvalidError)
      expect { verified(forwarded_proto: "ftp").public_origin }.to raise_error(PublicOrigin::InvalidError)
    end

    it "公開オリジンが無くても、client_ip は読める（片方の不備が、もう片方を妨げない）" do
      expect(verified(forwarded_host: nil).client_ip.to_s).to eq("203.0.113.5")
    end
  end

  it "inspect に、IP・公開オリジンを出さない" do
    expect(verified.inspect).not_to include("203.0.113.5")
    expect(verified.inspect).not_to include("app.example.test")
  end
end
