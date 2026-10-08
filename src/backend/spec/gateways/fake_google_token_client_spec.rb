require "rails_helper"

# 疑似の Google のトークンエンドポイント（issue #10）。開発・テストのみ。GoogleTokenClient と同じ使い方（refresh・revoke）で、
# 外部サービスを呼ばない。本番では構築できない（FakeServices.verify_environment!）。失敗の注入ができる（次の呼び出しだけ）。
RSpec.describe FakeGoogleTokenClient do
  let(:client) { described_class.new(environment: AppEnvironment.new("test")) }
  let(:refresh_token) { "1//dummy-refresh-token-0001" }

  describe "構築" do
    it "development・test では構築できる。production では FakeServices::NotAllowedError" do
      expect { described_class.new(environment: AppEnvironment.new("development")) }.not_to raise_error
      expect { described_class.new(environment: AppEnvironment.new("test")) }.not_to raise_error
      expect { described_class.new(environment: AppEnvironment.new("production")) }.to raise_error(FakeServices::NotAllowedError, /production/)
    end

    it "環境を省くと、現在の環境（テストでは疑似を許す）" do
      expect { described_class.new }.not_to raise_error
    end
  end

  describe "#refresh" do
    it "決定的なアクセストークン（fake-access-token-N。N は呼び出しごとに 1 ずつ増える）と有効秒数を返す" do
      first = client.refresh(refresh_token: refresh_token)
      second = client.refresh(refresh_token: refresh_token)

      expect(first.access_token).to eq("fake-access-token-1")
      expect(second.access_token).to eq("fake-access-token-2")
      expect(first.expires_in).to eq(3600)
    end

    it "GoogleTokenClient::Tokens を返す（本物と同じ型。inspect はトークンを出さない）" do
      tokens = client.refresh(refresh_token: refresh_token)

      expect(tokens).to be_a(GoogleTokenClient::Tokens)
      expect(tokens.inspect).not_to include("fake-access-token-1")
    end

    it "更新トークンが文字列でない・空は ArgumentError（本物と同じ検査）" do
      [ nil, "", "  ", 1 ].each do |value|
        expect { client.refresh(refresh_token: value) }.to raise_error(ArgumentError, /refresh_token/)
      end
    end

    it "同時に呼んでも、番号が重ならない（スレッドセーフ）" do
      tokens = Array.new(8) { Thread.new { client.refresh(refresh_token: refresh_token).access_token } }.map(&:value)

      expect(tokens.uniq.size).to eq(8)
    end
  end

  describe "#fail_next（失敗の注入。次の呼び出しだけ）" do
    it "token_revoked: 次の refresh が TokenRevoked。その次は成功する" do
      client.fail_next(:token_revoked)

      expect { client.refresh(refresh_token: refresh_token) }.to raise_error(YouTubeErrors::TokenRevoked) { |error|
        expect(error).to have_attributes(call_kind: :token_refresh, reason: "invalid_grant")
      }
      expect(client.refresh(refresh_token: refresh_token).access_token).to eq("fake-access-token-1")
    end

    it "token_unavailable: 次の refresh が TokenTemporarilyUnavailable" do
      client.fail_next(:token_unavailable)

      expect { client.refresh(refresh_token: refresh_token) }.to raise_error(YouTubeErrors::TokenTemporarilyUnavailable)
      expect { client.refresh(refresh_token: refresh_token) }.not_to raise_error
    end

    it "unexpected: 次の refresh が UnexpectedResponse" do
      client.fail_next(:unexpected)

      expect { client.refresh(refresh_token: refresh_token) }.to raise_error(YouTubeErrors::UnexpectedResponse)
    end

    it "times で回数を指定できる（注入は、呼び出しの順に 1 回ずつ消費する）" do
      client.fail_next(:token_unavailable, times: 2)

      2.times { expect { client.refresh(refresh_token: refresh_token) }.to raise_error(YouTubeErrors::TokenTemporarilyUnavailable) }
      expect { client.refresh(refresh_token: refresh_token) }.not_to raise_error
    end

    it "注入した失敗では、アクセストークンの番号を進めない（失敗は、トークンを発行しない）" do
      client.fail_next(:token_unavailable)
      expect { client.refresh(refresh_token: refresh_token) }.to raise_error(YouTubeErrors::TokenTemporarilyUnavailable)

      expect(client.refresh(refresh_token: refresh_token).access_token).to eq("fake-access-token-1")
    end

    it "revoke_unavailable: 次の revoke が TokenTemporarilyUnavailable。refresh には影響しない" do
      client.fail_next(:revoke_unavailable)

      expect { client.refresh(refresh_token: refresh_token) }.not_to raise_error
      expect { client.revoke(token: refresh_token) }.to raise_error(YouTubeErrors::TokenTemporarilyUnavailable)
      expect(client.revoke(token: refresh_token)).to eq(:revoked)
    end

    it "未知の種類・不正な回数は ArgumentError（黙って無視しない）" do
      expect { client.fail_next(:other) }.to raise_error(ArgumentError, /kind/)
      expect { client.fail_next(:token_revoked, times: 0) }.to raise_error(ArgumentError, /times/)
      expect { client.fail_next(:token_revoked, times: "1") }.to raise_error(ArgumentError, /times/)
    end

    it "reset! で、注入と番号を初期状態へ戻す" do
      client.refresh(refresh_token: refresh_token)
      client.fail_next(:token_revoked)
      client.reset!

      expect(client.refresh(refresh_token: refresh_token).access_token).to eq("fake-access-token-1")
    end
  end

  describe "#revoke" do
    it "常に :revoked（疑似の Google は、どのトークンも失効させる）。トークンが文字列でない・空は ArgumentError" do
      expect(client.revoke(token: refresh_token)).to eq(:revoked)
      expect { client.revoke(token: "") }.to raise_error(ArgumentError, /token/)
    end
  end

  it "inspect に、番号・注入の内容を出さない" do
    expect(client.inspect).to eq("#<FakeGoogleTokenClient>")
  end
end
