require "rails_helper"
require "pp"

# OAuth の認可コードの交換の結果 OAuthGrant（issue #11。requirements.md 7.2・7.3）。
# YouTube 接続の認可コードを交換して得た、アクセストークン・更新トークン（無いことがある）・付与されたスコープ・有効秒数。
# 形が違う値は ArgumentError（黙って通さない）。トークンを、inspect・to_s・pretty_inspect に出さない。凍結されている。
RSpec.describe OAuthGrant do
  let(:youtube_scope) { "https://www.googleapis.com/auth/youtube" }
  let(:access_token) { "ya29.dummy-access-token-must-not-appear" }
  let(:refresh_token) { "1//dummy-refresh-token-must-not-appear" }

  def build(**overrides)
    described_class.new(
      **{ access_token: access_token, refresh_token: refresh_token, scopes: [ youtube_scope ], expires_in: 3599 }.merge(overrides)
    )
  end

  describe "値" do
    it "アクセストークン・更新トークン・スコープ・有効秒数を持つ" do
      grant = build

      expect(grant.access_token).to eq(access_token)
      expect(grant.refresh_token).to eq(refresh_token)
      expect(grant.scopes).to eq([ youtube_scope ])
      expect(grant.expires_in).to eq(3599)
    end

    it "更新トークンが無いことがある（nil）" do
      grant = build(refresh_token: nil)

      expect(grant.refresh_token).to be_nil
      expect(grant).not_to be_refresh_token
    end

    it "更新トークンがあれば refresh_token? は true" do
      expect(build).to be_refresh_token
    end

    it "scope?: 付与されたスコープに含まれるかを、完全一致で答える（前方一致・部分一致で、別のスコープを同じとしない）" do
      grant = build(scopes: [ "https://www.googleapis.com/auth/youtube.readonly" ])

      expect(grant.scope?(youtube_scope)).to be(false)
      expect(grant.scope?("https://www.googleapis.com/auth/youtube.readonly")).to be(true)
      expect(build(scopes: [])).not_to be_scope(youtube_scope)
    end

    it "スコープは複数でもよい" do
      grant = build(scopes: [ "openid", youtube_scope ])

      expect(grant.scope?(youtube_scope)).to be(true)
      expect(grant.scope?("openid")).to be(true)
    end

    it "凍結されている（トークンも、スコープの配列も、書き換えられない）" do
      grant = build

      expect(grant).to be_frozen
      expect(grant.access_token).to be_frozen
      expect(grant.refresh_token).to be_frozen
      expect(grant.scopes).to be_frozen
    end

    it "渡した文字列を後から書き換えても、値は変わらない（複製して持つ）" do
      original = +"ya29.dummy-mutable-token"
      grant = build(access_token: original)

      original << "-changed"

      expect(grant.access_token).to eq("ya29.dummy-mutable-token")
    end
  end

  describe "検査（形が違う値は ArgumentError）" do
    it "アクセストークン: 必須。空・空白を含む・制御文字・長すぎる・文字列でないものは拒否" do
      [ nil, "", "has space", "line\nbreak", "tab\t", "a" * 4097, 123, :sym, [] ].each do |invalid|
        expect { build(access_token: invalid) }.to raise_error(ArgumentError, /access_token/)
      end
    end

    it "更新トークン: nil か、印字できる ASCII の 1〜2048 文字。それ以外は拒否（TokenVault#store が受け付ける形に限る）" do
      [ "", "has space", "line\nbreak", "a" * 2049, 123, :sym, [] ].each do |invalid|
        expect { build(refresh_token: invalid) }.to raise_error(ArgumentError, /refresh_token/)
      end
      expect(build(refresh_token: "a" * 2048).refresh_token.length).to eq(2048)
    end

    it "スコープ: 文字列の配列。配列でない・要素が文字列でない・空白を含む・空の要素は拒否" do
      [ nil, "openid", [ 1 ], [ "has space" ], [ "" ], [ nil ], { "a" => 1 } ].each do |invalid|
        expect { build(scopes: invalid) }.to raise_error(ArgumentError, /scopes/)
      end
    end

    it "有効秒数: 1〜86400 の整数。0・負・文字列・小数・nil は拒否" do
      [ 0, -1, 86_401, "3599", 3599.5, nil ].each do |invalid|
        expect { build(expires_in: invalid) }.to raise_error(ArgumentError, /expires_in/)
      end
      expect(build(expires_in: 1).expires_in).to eq(1)
      expect(build(expires_in: 86_400).expires_in).to eq(86_400)
    end

    it "例外のメッセージに、トークンの値を含めない" do
      expect { build(access_token: "ya29.has space must-not-appear") }.to raise_error(ArgumentError) { |error|
        expect(error.message).not_to include("must-not-appear")
      }
      expect { build(refresh_token: "1//has space must-not-appear") }.to raise_error(ArgumentError) { |error|
        expect(error.message).not_to include("must-not-appear")
      }
    end
  end

  describe "機密" do
    it "inspect・to_s・pretty_inspect に、トークンを出さない。スコープと、更新トークンの有無は出る" do
      grant = build

      [ grant.inspect, grant.to_s, grant.pretty_inspect ].each do |text|
        expect(text).not_to include(access_token)
        expect(text).not_to include(refresh_token)
        expect(text).not_to include("must-not-appear")
      end
      expect(grant.inspect).to include("refresh_token=present")
      expect(build(refresh_token: nil).inspect).to include("refresh_token=absent")
    end

    it "ハッシュ・JSON・配列への変換を持たない（トークンが、ログ・応答へ流れ込む道を作らない）" do
      grant = build

      expect(grant).not_to respond_to(:to_h)
      expect(grant).not_to respond_to(:to_a)
      expect(grant).not_to respond_to(:deconstruct_keys)
    end
  end
end
