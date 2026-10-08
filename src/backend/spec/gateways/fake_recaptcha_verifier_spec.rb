require "rails_helper"

# 疑似の bot 判定 FakeRecaptchaVerifier（issue #8）。開発・テストのみ。
# トークン dev-pass = :pass、dev-fail = :fail、dev-indeterminate = :indeterminate、それ以外は :fail。
# 本番では使えない（構築時に環境を検査し、本番なら例外にする）。外部サービスを呼ばない。
RSpec.describe FakeRecaptchaVerifier do
  let(:verifier) { described_class.new }
  let(:now) { Time.utc(2026, 10, 8, 3, 0, 0) }

  def verdict_of(token, action: "login", hostname: "app.example.test", at: now)
    verifier.verify(token: token, expected_action: action, hostname: hostname, now: at)
  end

  describe "トークンと判定の対応" do
    {
      "dev-pass" => :pass,
      "dev-fail" => :fail,
      "dev-indeterminate" => :indeterminate
    }.each do |token, verdict|
      it "#{token} は #{verdict}" do
        expect(verdict_of(token)).to eq(verdict)
      end
    end

    it "それ以外は :fail（疑似でも、判定不能・合格へ倒さない）" do
      [ "", "dev-pass ", " dev-pass", "DEV-PASS", "dev-pass\n", "dev_pass", "pass", "dummy-recaptcha-token", "x" * 5000 ].each do |token|
        expect(verdict_of(token)).to eq(:fail), token.inspect[0, 40]
      end
    end

    it "トークンが文字列でない（nil・数値・配列）は :fail" do
      [ nil, 1, [ "dev-pass" ], { "dev-pass" => 1 }, :"dev-pass" ].each do |token|
        expect(verdict_of(token)).to eq(:fail), token.inspect
      end
    end

    it "行為名は、3 つとも受け付ける（判定には使わない）" do
      %w[ login youtube_connect broadcast_start ].each do |action|
        expect(verdict_of("dev-pass", action: action)).to eq(:pass)
      end
    end
  end

  describe "RecaptchaVerifier と同じ引数の検査" do
    it "未知の行為名・空のホスト・Time でない now は ArgumentError" do
      expect { verdict_of("dev-pass", action: "signup") }.to raise_error(ArgumentError, /expected_action/)
      expect { verdict_of("dev-pass", hostname: "") }.to raise_error(ArgumentError, /hostname/)
      expect { verdict_of("dev-pass", at: "2026-10-08") }.to raise_error(ArgumentError, /now/)
    end

    it "assess も、RecaptchaVerifier と同じ形（Assessment）を返す" do
      result = verifier.assess(token: "dev-pass", expected_action: "login", hostname: "app.example.test", now: now)

      expect(result).to be_a(RecaptchaVerifier::Assessment)
      expect(result.verdict).to eq(:pass)
      expect(result.reason).to eq(:fake)
    end
  end

  describe "外部サービスを呼ばない" do
    it "通信しない（WebMock が通信を禁止していても動く）" do
      require "support/external_http_support"

      expect(verdict_of("dev-pass")).to eq(:pass)
      expect(a_request(:any, /./)).not_to have_been_made
    end
  end

  describe "本番では使えない" do
    it "本番の環境の判定では、構築できない（例外）" do
      expect { described_class.new(environment: AppEnvironment.new("production")) }.to raise_error(FakeServices::NotAllowedError)
    end

    %w[ development test ].each do |name|
      it "#{name} では構築できる" do
        expect { described_class.new(environment: AppEnvironment.new(name)) }.not_to raise_error
      end
    end

    it "既定の環境は、現在の環境（AppEnvironment.current）。本番なら構築できない" do
      allow(AppEnvironment).to receive(:current).and_return(AppEnvironment.new("production"))

      expect { described_class.new }.to raise_error(FakeServices::NotAllowedError)
    end

    it "例外のメッセージは、環境の名前だけ（値を含めない）" do
      expect { described_class.new(environment: AppEnvironment.new("production")) }
        .to raise_error(FakeServices::NotAllowedError, /production/)
    end
  end
end
