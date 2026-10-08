require "rails_helper"
require "support/youtube_connect_support"

# YouTube 接続の開始 YouTubeConnectService#start（issue #11。requirements.md 7.2・23.1。src/contracts/http-api.md 3 章 connect/start）。
#   認可 URL を作る: スコープは youtube の 1 種のみ・PKCE・state・offline・consent・login_hint（ログイン中の Google の識別子 sub）。
#   state・PKCE の検証子は、呼び出しごとに新しい乱数。bl_oauth（暗号化・短命の Cookie）に入れるのは、コントローラ。
#   進行中の配信があるアカウントは、再接続を受け付けない（7.4）。
RSpec.describe YouTubeConnectService, "#start（認可の開始）" do
  include YouTubeConnectSupport
  include_context "YouTube 接続の環境"

  let(:user) { create(:user, google_sub: "dev-user-1") }
  let(:service) { connect_service }
  let(:started) { service.start(user: user, redirect_uri: callback_uri) }
  let(:query) { Rack::Utils.parse_query(URI.parse(started.authorization_url).query) }

  it "認可 URL: 行き先は疑似の同意画面（開発・テスト）。スコープは youtube の 1 種のみ・offline・consent・PKCE の S256・login_hint" do
    expect(started.authorization_url).to start_with("https://app.example.test/api/dev/google/connect?")
    expect(query).to include(
      "response_type" => "code", "scope" => youtube_scope, "access_type" => "offline", "prompt" => "consent",
      "code_challenge_method" => "S256", "redirect_uri" => callback_uri, "login_hint" => "dev-user-1"
    )
    expect(query).not_to have_key("include_granted_scopes")
    expect(query).not_to have_key("nonce")
  end

  it "login_hint は、ログイン中のアカウントの Google の識別子（sub）。メールアドレスではない" do
    other = create(:user, google_sub: "dummy-other-sub-0002")

    other_query = Rack::Utils.parse_query(URI.parse(service.start(user: other, redirect_uri: callback_uri).authorization_url).query)

    expect(other_query.fetch("login_hint")).to eq("dummy-other-sub-0002")
    expect(other_query.fetch("login_hint")).not_to include("@")
  end

  it "state と PKCE の検証子は、呼び出しごとに新しい乱数（state は 43 文字・検証子は 86 文字の base64url）" do
    first = service.start(user: user, redirect_uri: callback_uri)
    second = service.start(user: user, redirect_uri: callback_uri)

    expect(first.state).to match(/\A[A-Za-z0-9_-]{43}\z/)
    expect(first.code_verifier).to match(/\A[A-Za-z0-9_-]{86}\z/)
    expect(second.state).not_to eq(first.state)
    expect(second.code_verifier).not_to eq(first.code_verifier)
  end

  it "認可 URL の state・code_challenge は、返した state・検証子と対応する（code_challenge は検証子の S256）" do
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(started.code_verifier), padding: false)

    expect(query.fetch("state")).to eq(started.state)
    expect(query.fetch("code_challenge")).to eq(challenge)
  end

  it "bl_oauth の形（state・nonce・検証子）を満たす。nonce は使わない値（ID トークンを使わない）で、認可 URL に載せない" do
    expect(started.nonce).to eq(YouTubeConnectService::UNUSED_NONCE)
    expect(started.authorization_url).not_to include(started.nonce)
    expect do
      OAuthStateCookie.new(secret: SecureRandom.hex(16)).seal(
        state: started.state, nonce: started.nonce, code_verifier: started.code_verifier, purpose: "connect", user_id: user.id, now: Time.current
      )
    end.not_to raise_error
  end

  it "何も保存しない（DB の行を作らない・変えない）" do
    expect { started }.not_to change { [ YoutubeConnection.count, UsageEvent.count, QuotaEntry.count ] }
  end

  it "YouTube も Google のトークンエンドポイントも呼ばない（認可 URL を作るだけ）" do
    allow(fake_oidc).to receive(:exchange_youtube_code)
    allow(fake_oidc).to receive(:revoke)

    started

    expect(fake_oidc).not_to have_received(:exchange_youtube_code)
    expect(fake_oidc).not_to have_received(:revoke)
  end

  it "返す値に、state・検証子を出さない（inspect・to_s）" do
    [ started.inspect, started.to_s ].each do |text|
      expect(text).not_to include(started.state)
      expect(text).not_to include(started.code_verifier)
    end
  end

  it "保存済みのアカウントだけ受け付ける（nil・保存前のアカウントは ArgumentError）" do
    expect { service.start(user: nil, redirect_uri: callback_uri) }.to raise_error(ArgumentError, /user/)
    expect { service.start(user: User.new(google_sub: "x"), redirect_uri: callback_uri) }.to raise_error(ArgumentError, /user/)
  end

  it "redirect_uri が空なら ArgumentError" do
    expect { service.start(user: user, redirect_uri: "") }.to raise_error(ArgumentError, /redirect_uri/)
  end

  describe "#broadcast_in_progress?（進行中の配信があれば、再接続を受け付けない。7.4）" do
    it "終了していない配信が無ければ false" do
      expect(service.broadcast_in_progress?(user)).to be(false)
    end

    %w[ reserved awaiting_media confirming live interrupted ].each do |state|
      it "状態 #{state} の配信があれば true" do
        create(:broadcast, user: user, state: state)

        expect(service.broadcast_in_progress?(user)).to be(true)
      end
    end

    it "終了した配信だけなら false" do
      create(:broadcast, :ended, user: user)

      expect(service.broadcast_in_progress?(user)).to be(false)
    end

    it "他のアカウントの配信は、数えない（所有権）" do
      create(:broadcast, user: create(:user))

      expect(service.broadcast_in_progress?(user)).to be(false)
    end

    it "保存済みのアカウントだけ受け付ける" do
      expect { service.broadcast_in_progress?(nil) }.to raise_error(ArgumentError, /user/)
    end
  end

  describe "構築" do
    it "必要な口を持たない部品は、ArgumentError（取り違えを、黙って通さない）" do
      expect { described_class.new(oidc: Object.new, token_vault: token_vault, youtube_gateway: fake_youtube, channel_names: channel_names) }
        .to raise_error(ArgumentError, /oidc/)
      expect { described_class.new(oidc: fake_oidc, token_vault: Object.new, youtube_gateway: fake_youtube, channel_names: channel_names) }
        .to raise_error(ArgumentError, /token_vault/)
      expect { described_class.new(oidc: fake_oidc, token_vault: token_vault, youtube_gateway: Object.new, channel_names: channel_names) }
        .to raise_error(ArgumentError, /youtube_gateway/)
      expect { described_class.new(oidc: fake_oidc, token_vault: token_vault, youtube_gateway: fake_youtube, channel_names: Object.new) }
        .to raise_error(ArgumentError, /channel_names/)
    end

    it "inspect に、部品（トークン・鍵を持つもの）を出さない" do
      expect(service.inspect).to eq("#<YouTubeConnectService>")
    end
  end
end
