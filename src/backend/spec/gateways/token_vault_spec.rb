require "rails_helper"
require "support/model_support"
require "support/log_capture"

# 更新トークンの暗号化保存と、アクセストークンのメモリ上の再利用（issue #10。requirements.md 7.3・10.6・7.4・28.1）。
#   store         更新トークンを AES-256-GCM（ActiveSupport::MessageEncryptor。鍵は TOKEN_ENCRYPTION_KEY）で暗号化して保存する
#   access_token  必要時に更新トークンから取得し、有効期限内に限りメモリ上で再利用する（永続化しない。期限の 60 秒前に更新）。
#                 恒久的に失敗（invalid_grant・取り消し）したら TokenRevoked を投げ、接続状態を revoked にする。
#                 一時的な失敗（ネットワーク・5xx）は TokenTemporarilyUnavailable（状態を変えない）
#   revoke        Google の失効エンドポイントへ送り、成否にかかわらず、保存したトークンを削除する。結果を返す
# 平文・暗号文・鍵を、ログ・例外・inspect に出さない。通信は GoogleTokenClient（ここでは、検証済みの doubles で差し替える）。
RSpec.describe TokenVault do
  include LogCapture

  let(:key) { "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }
  let(:other_key) { "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210" }
  let(:token_client) { instance_double(GoogleTokenClient) }
  let(:cache) { TokenVault::AccessTokenCache.new }
  let(:vault) { described_class.new(key: key, token_client: token_client, cache: cache) }
  let(:now) { Time.utc(2026, 10, 8, 3, 0, 0) }
  let(:user) { create(:user) }
  let(:refresh_token) { "1//dummy-refresh-token-must-not-appear" }
  let(:revoked_error) { YouTubeErrors::TokenRevoked.new(call_kind: :token_refresh, status: 400, reason: "invalid_grant") }
  let(:unavailable_error) { YouTubeErrors::TokenTemporarilyUnavailable.new(call_kind: :token_refresh, status: 503) }

  def tokens(access_token, expires_in: 3600)
    GoogleTokenClient::Tokens.new(access_token: access_token, expires_in: expires_in)
  end

  def stored_ciphertext(record)
    YoutubeConnection.find(record.id).refresh_token_ciphertext
  end

  def stored_state(record)
    YoutubeConnection.find(record.id).state
  end

  def connect(owner = user, token: refresh_token, at: now, with: vault)
    with.store(user_id: owner.id, refresh_token: token, now: at)
  end

  describe "鍵（TOKEN_ENCRYPTION_KEY）" do
    it "64 文字の 16 進数（32 バイト。大文字・小文字どちらも）を受け付ける" do
      expect { described_class.new(key: key, token_client: token_client, cache: cache) }.not_to raise_error
      expect { described_class.new(key: key.upcase, token_client: token_client, cache: cache) }.not_to raise_error
    end

    it "大文字・小文字の違いは、同じ鍵（同じ暗号文を復号できる）" do
      connect
      allow(token_client).to receive(:refresh).and_return(tokens("ya29.dummy-1"))

      upper = described_class.new(key: key.upcase, token_client: token_client, cache: TokenVault::AccessTokenCache.new)

      expect(upper.access_token(user_id: user.id, now: now)).to eq("ya29.dummy-1")
    end

    {
      "未設定（nil）" => nil,
      "空文字列" => "",
      "空白だけ" => "   ",
      "文字列でない（数値）" => 12_345,
      "63 文字" => "a" * 63,
      "65 文字" => "a" * 65,
      "16 進数でない文字（g）" => "g" * 64,
      "32 バイトの生の文字列（16 進数の 64 文字ではない）" => "k" * 32,
      "前後に空白" => " #{'a' * 64} ",
      "改行つき" => "#{'a' * 64}\n"
    }.each do |label, value|
      it "#{label} は InvalidKey（本番でなくても。鍵の値は、メッセージに出さない）" do
        expect { described_class.new(key: value, token_client: token_client, cache: cache) }.to raise_error(TokenVault::InvalidKey) { |error|
          expect(error.message).to start_with("TOKEN_ENCRYPTION_KEY")
          expect(error.message).not_to include(value.to_s) unless value.to_s.strip.empty?
        }
      end
    end
  end

  describe "#store（暗号化して保存）" do
    it "接続が無ければ、接続を作る（接続済み。接続の時刻・確認の時刻は now）。保存した接続を返す" do
      record = vault.store(user_id: user.id, refresh_token: refresh_token, now: now)

      expect(record).to be_a(YoutubeConnection)
      expect(record).to be_persisted
      expect(YoutubeConnection.find(record.id)).to have_attributes(
        user_id: user.id, state: "connected", connected_at: now, last_verified_at: now, youtube_stream_id: nil
      )
    end

    it "保存するのは暗号文だけ。平文を含まない。AES-256-GCM（認証つき）の形式（暗号文 -- IV -- 認証タグ）" do
      record = connect

      ciphertext = stored_ciphertext(record)
      expect(ciphertext).not_to include(refresh_token)
      expect(ciphertext).not_to include("dummy-refresh-token")
      expect(ciphertext.split("--").size).to eq(3)
    end

    it "同じ更新トークンでも、保存のたびに暗号文が変わる（IV が毎回違う）" do
      first = stored_ciphertext(connect)
      second = stored_ciphertext(connect)

      expect(second).not_to eq(first)
    end

    it "暗号文の往復: 保存した更新トークンが、そのまま Google への更新の要求に使われる" do
      connect
      expect(token_client).to receive(:refresh).with(refresh_token: refresh_token).and_return(tokens("ya29.dummy-1"))

      vault.access_token(user_id: user.id, now: now)
    end

    it "鍵が違えば、復号できない（Undecryptable。Google を呼ばない。接続の状態は変えない）" do
      connect
      other = described_class.new(key: other_key, token_client: token_client, cache: TokenVault::AccessTokenCache.new)
      expect(token_client).not_to receive(:refresh)

      expect { other.access_token(user_id: user.id, now: now) }.to raise_error(TokenVault::Undecryptable)
      expect(YoutubeConnection.find_by!(user_id: user.id).state).to eq("connected")
    end

    it "暗号文は、アカウントに結びつく（他のアカウントの行へ写しても、復号できない）" do
      other_user = create(:user)
      connect(user)
      connect(other_user, token: "1//dummy-other-refresh-token")
      YoutubeConnection.where(user_id: other_user.id).update_all(refresh_token_ciphertext: stored_ciphertext(YoutubeConnection.find_by!(user_id: user.id)))
      expect(token_client).not_to receive(:refresh)

      expect { vault.access_token(user_id: other_user.id, now: now) }.to raise_error(TokenVault::Undecryptable)
    end

    it "暗号文が改ざん・破損していれば、復号できない（Undecryptable）" do
      record = connect
      original = stored_ciphertext(record)
      tampered_values = [ original.sub(/\A./) { |c| c == "A" ? "B" : "A" }, original.reverse, "not-a-ciphertext", "a--b--c", original.split("--").first ]

      tampered_values.each do |tampered|
        YoutubeConnection.where(id: record.id).update_all(refresh_token_ciphertext: tampered)
        expect { vault.access_token(user_id: user.id, now: now) }.to raise_error(TokenVault::Undecryptable)
      end
    end

    it "接続がすでにあれば、暗号文だけを置き換える（状態・ストリームの識別子・時刻は変えない。接続の成立の扱いは #11）" do
      record = create(:youtube_connection, :with_stream, user: user, state: "live_not_enabled", refresh_token_ciphertext: "dummy-old-ciphertext")
      before = YoutubeConnection.find(record.id).attributes.except("refresh_token_ciphertext")

      returned = vault.store(user_id: user.id, refresh_token: refresh_token, now: now + 3600)

      expect(returned.id).to eq(record.id)
      expect(YoutubeConnection.find(record.id).attributes.except("refresh_token_ciphertext")).to eq(before)
      expect(stored_ciphertext(record)).not_to eq("dummy-old-ciphertext")
      expect(YoutubeConnection.where(user_id: user.id).count).to eq(1)
    end

    it "アカウントにつき接続は 1 件のまま（2 回保存しても増えない）" do
      connect
      connect

      expect(YoutubeConnection.where(user_id: user.id).count).to eq(1)
    end

    it "保存で、そのアカウントのメモリ上のアクセストークンを捨てる（古い更新トークンのトークンを使い続けない）" do
      connect
      allow(token_client).to receive(:refresh).and_return(tokens("ya29.dummy-1"), tokens("ya29.dummy-2"))
      vault.access_token(user_id: user.id, now: now)

      connect(user, token: "1//dummy-refresh-token-new")

      expect(vault.access_token(user_id: user.id, now: now)).to eq("ya29.dummy-2")
    end

    it "他のアカウントの接続を変えない" do
      other_user = create(:user)
      other = connect(other_user, token: "1//dummy-other")
      before = YoutubeConnection.find(other.id).attributes

      connect(user)

      expect(YoutubeConnection.find(other.id).attributes).to eq(before)
    end

    it "更新トークンの検査: 空・空白・改行・非 ASCII・長すぎる値は ArgumentError（値を、メッセージに出さない）" do
      [ nil, "", "  ", "has space", "line\nbreak", "tab\there", [ 0x65E5 ].pack("U"), "a" * 2049, 1, :token ].each do |value|
        expect { vault.store(user_id: user.id, refresh_token: value, now: now) }.to raise_error(ArgumentError, /refresh_token/) { |error|
          expect(error.message).not_to include("has space") if value.is_a?(String) && !value.empty?
        }
      end
      expect(YoutubeConnection.where(user_id: user.id)).to be_empty
    end

    it "アカウント識別子が UUID でなければ ArgumentError。存在しないアカウントは、検証の失敗（保存しない）" do
      expect { vault.store(user_id: "not-a-uuid", refresh_token: refresh_token, now: now) }.to raise_error(ArgumentError)
      expect { vault.store(user_id: SecureRandom.uuid, refresh_token: refresh_token, now: now) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(YoutubeConnection.count).to eq(0)
    end

    it "保存の SQL のログに、暗号文・平文を出さない（バインド値は、伏せ字になる）" do
      output = capture_logs { connect }

      expect(output).to include("INSERT INTO \"youtube_connections\"")
      expect(output).not_to include(refresh_token)
      expect(output).not_to include(stored_ciphertext(YoutubeConnection.find_by!(user_id: user.id)))
    end

    it "接続がすでにあるときの更新の SQL のログにも、暗号文・平文を出さない" do
      connect
      output = capture_logs { connect(user, token: "1//dummy-refresh-token-second") }

      expect(output).to include("UPDATE \"youtube_connections\"")
      expect(output).not_to include("dummy-refresh-token-second")
      expect(output).not_to include(stored_ciphertext(YoutubeConnection.find_by!(user_id: user.id)))
    end

    it "now を省くと、呼び出しの時点の時刻を使う" do
      record = vault.store(user_id: user.id, refresh_token: refresh_token)

      expect(YoutubeConnection.find(record.id).connected_at).to be_within(5.seconds).of(Time.current)
    end
  end

  describe "#access_token（メモリ上の再利用）" do
    before do
      connect
      allow(token_client).to receive(:refresh).and_return(tokens("ya29.dummy-1"), tokens("ya29.dummy-2"), tokens("ya29.dummy-3"))
    end

    it "初回は、更新トークンから取得して返す。有効期限内は、Google を呼ばずに再利用する" do
      expect(vault.access_token(user_id: user.id, now: now)).to eq("ya29.dummy-1")
      expect(vault.access_token(user_id: user.id, now: now + 10)).to eq("ya29.dummy-1")
      expect(vault.access_token(user_id: user.id, now: now + 3000)).to eq("ya29.dummy-1")

      expect(token_client).to have_received(:refresh).once
    end

    [ [ 3538, 1 ], [ 3539, 1 ], [ 3540, 2 ], [ 3541, 2 ], [ 3600, 2 ], [ 86_400, 2 ] ].each do |elapsed, expected_calls|
      it "有効期限（3600 秒）の 60 秒前（3540 秒）から更新する: #{elapsed} 秒後の 2 回目の取得で、Google の呼び出しは合計 #{expected_calls} 回" do
        vault.access_token(user_id: user.id, now: now)
        vault.access_token(user_id: user.id, now: now + elapsed)

        expect(token_client).to have_received(:refresh).exactly(expected_calls).times
      end
    end

    it "更新したあとのトークンは、更新した時刻から数え直す" do
      vault.access_token(user_id: user.id, now: now)
      vault.access_token(user_id: user.id, now: now + 3540)

      expect(vault.access_token(user_id: user.id, now: now + 3540 + 3538)).to eq("ya29.dummy-2")
      expect(token_client).to have_received(:refresh).twice
    end

    it "有効秒数が 60 秒以下のトークンは、毎回更新する（再利用できる時間が無い）" do
      allow(token_client).to receive(:refresh).and_return(tokens("ya29.dummy-1", expires_in: 60), tokens("ya29.dummy-2", expires_in: 60))

      first = vault.access_token(user_id: user.id, now: now)
      second = vault.access_token(user_id: user.id, now: now)

      expect([ first, second ]).to eq([ "ya29.dummy-1", "ya29.dummy-2" ])
    end

    it "アカウントごとに別のトークンを持つ" do
      other_user = create(:user)
      connect(other_user, token: "1//dummy-other")

      first = vault.access_token(user_id: user.id, now: now)
      second = vault.access_token(user_id: other_user.id, now: now)

      expect([ first, second ]).to eq([ "ya29.dummy-1", "ya29.dummy-2" ])
    end

    it "アクセストークンを DB に保存しない（接続の行は、アクセストークンを含まない）" do
      vault.access_token(user_id: user.id, now: now)

      row = YoutubeConnection.find_by!(user_id: user.id).attributes.values.map(&:to_s).join(" ")
      expect(row).not_to include("ya29.dummy-1")
    end

    it "now は Time。アカウント識別子は UUID（違反は ArgumentError で、Google を呼ばない）" do
      expect { vault.access_token(user_id: user.id, now: "now") }.to raise_error(ArgumentError, /now/)
      expect { vault.access_token(user_id: "not-a-uuid", now: now) }.to raise_error(ArgumentError)
      expect(token_client).not_to have_received(:refresh)
    end

    it "forget_access_token で、そのアカウントのメモリ上のトークンを捨てる（YouTube が拒否したトークンを使い続けない）" do
      vault.access_token(user_id: user.id, now: now)

      vault.forget_access_token(user_id: user.id)

      expect(vault.access_token(user_id: user.id, now: now)).to eq("ya29.dummy-2")
    end
  end

  describe "#access_token（接続の状態）" do
    it "接続が無い（未接続）なら NotConnected。Google を呼ばない" do
      expect(token_client).not_to receive(:refresh)

      expect { vault.access_token(user_id: user.id, now: now) }.to raise_error(TokenVault::NotConnected)
    end

    it "認可失効（revoked）の接続は、Google を呼ばずに TokenRevoked（再接続が要る）。状態は変えない" do
      create(:youtube_connection, :revoked, user: user)
      expect(token_client).not_to receive(:refresh)

      expect { vault.access_token(user_id: user.id, now: now) }.to raise_error(YouTubeErrors::TokenRevoked) { |error|
        expect(error).to have_attributes(call_kind: :token_refresh, reason: "connection_revoked")
      }
      expect(YoutubeConnection.find_by!(user_id: user.id).state).to eq("revoked")
    end

    it "ライブ未有効（live_not_enabled）の接続でも、トークンは使える" do
      connect
      YoutubeConnection.where(user_id: user.id).update_all(state: "live_not_enabled")
      allow(token_client).to receive(:refresh).and_return(tokens("ya29.dummy-1"))

      expect(vault.access_token(user_id: user.id, now: now)).to eq("ya29.dummy-1")
    end

    it "他のアカウントの接続は、使わない" do
      other_user = create(:user)
      connect(other_user, token: "1//dummy-other")

      expect { vault.access_token(user_id: user.id, now: now) }.to raise_error(TokenVault::NotConnected)
    end
  end

  describe "#access_token（更新の失敗）" do
    before { connect }

    it "恒久的な失敗（TokenRevoked）: 例外を投げ、接続状態を revoked にし、メモリ上のトークンを捨てる" do
      allow(token_client).to receive(:refresh).and_return(tokens("ya29.dummy-1"))
      vault.access_token(user_id: user.id, now: now)
      allow(token_client).to receive(:refresh).and_raise(revoked_error)

      expect { vault.access_token(user_id: user.id, now: now + 3600) }.to raise_error(YouTubeErrors::TokenRevoked)

      expect(YoutubeConnection.find_by!(user_id: user.id).state).to eq("revoked")
      expect(cache.size).to eq(0)
    end

    it "失効した接続は、その後の取得で Google を呼ばずに TokenRevoked（同じ失敗を繰り返し叩かない）" do
      allow(token_client).to receive(:refresh).and_raise(revoked_error)
      expect { vault.access_token(user_id: user.id, now: now) }.to raise_error(YouTubeErrors::TokenRevoked)

      expect { vault.access_token(user_id: user.id, now: now) }.to raise_error(YouTubeErrors::TokenRevoked)

      expect(token_client).to have_received(:refresh).once
    end

    it "ライブ未有効の接続も、恒久的な失敗で revoked になる（25.4）" do
      YoutubeConnection.where(user_id: user.id).update_all(state: "live_not_enabled")
      allow(token_client).to receive(:refresh).and_raise(revoked_error)

      expect { vault.access_token(user_id: user.id, now: now) }.to raise_error(YouTubeErrors::TokenRevoked)

      expect(YoutubeConnection.find_by!(user_id: user.id).state).to eq("revoked")
    end

    it "他のアカウントの接続は、失効させない" do
      other_user = create(:user)
      connect(other_user, token: "1//dummy-other")
      allow(token_client).to receive(:refresh).and_raise(revoked_error)

      expect { vault.access_token(user_id: user.id, now: now) }.to raise_error(YouTubeErrors::TokenRevoked)

      expect(YoutubeConnection.find_by!(user_id: other_user.id).state).to eq("connected")
    end

    it "一時的な失敗（TokenTemporarilyUnavailable）: 例外を投げるが、接続の状態を変えない。次の取得で再び試す" do
      allow(token_client).to receive(:refresh).and_raise(unavailable_error)
      expect { vault.access_token(user_id: user.id, now: now) }.to raise_error(YouTubeErrors::TokenTemporarilyUnavailable)
      expect(YoutubeConnection.find_by!(user_id: user.id).state).to eq("connected")

      allow(token_client).to receive(:refresh).and_return(tokens("ya29.dummy-1"))

      expect(vault.access_token(user_id: user.id, now: now + 1)).to eq("ya29.dummy-1")
    end

    it "想定外の応答（UnexpectedResponse）: 例外を投げるが、接続の状態を変えない（設定の誤りで、全利用者を失効させない）" do
      allow(token_client).to receive(:refresh).and_raise(YouTubeErrors::UnexpectedResponse.new(call_kind: :token_refresh, status: 401, reason: "invalid_client"))

      expect { vault.access_token(user_id: user.id, now: now) }.to raise_error(YouTubeErrors::UnexpectedResponse)

      expect(YoutubeConnection.find_by!(user_id: user.id).state).to eq("connected")
    end

    it "失敗は、ログに残す（アカウントの内部の識別子と、符号だけ）。トークン・暗号文・鍵を出さない" do
      allow(token_client).to receive(:refresh).and_raise(revoked_error)
      error = nil

      output = capture_logs do
        error = begin
          vault.access_token(user_id: user.id, now: now)
        rescue YouTubeErrors::TokenRevoked => e
          e
        end
      end

      expect(output).to include("user_id=#{user.id}")
      expect(output).to include("reason=invalid_grant")
      forbidden = [ refresh_token, stored_ciphertext(YoutubeConnection.find_by!(user_id: user.id)), key ]
      [ output, error.message, error.inspect ].each { |text| forbidden.each { |secret| expect(text).not_to include(secret) } }
    end

    it "復号できない暗号文は、接続を失効させない（鍵の設定の誤りで、全利用者を失効させない）。ログに暗号文を出さない" do
      YoutubeConnection.where(user_id: user.id).update_all(refresh_token_ciphertext: "not-a-ciphertext-dummy")
      error = nil

      output = capture_logs do
        error = begin
          vault.access_token(user_id: user.id, now: now)
        rescue TokenVault::Undecryptable => e
          e
        end
      end

      expect(YoutubeConnection.find_by!(user_id: user.id).state).to eq("connected")
      expect(output).to include("undecryptable")
      expect(output).not_to include("not-a-ciphertext-dummy")
      expect(error.message).not_to include("not-a-ciphertext-dummy")
    end
  end

  describe "#revoke（失効と削除）" do
    before { connect }

    it "Google の失効エンドポイントへ更新トークンを送り、保存したトークン（接続）を削除する。結果は :revoked" do
      expect(token_client).to receive(:revoke).with(token: refresh_token).and_return(:revoked)

      result = vault.revoke(user_id: user.id)

      expect(result).to have_attributes(outcome: :revoked, cause: nil)
      expect(result.confirmed?).to be(true)
      expect(YoutubeConnection.where(user_id: user.id)).to be_empty
    end

    it "すでに失効している（invalid_token）なら :already_invalid。削除する" do
      allow(token_client).to receive(:revoke).and_return(:already_invalid)

      result = vault.revoke(user_id: user.id)

      expect(result.outcome).to eq(:already_invalid)
      expect(result.confirmed?).to be(true)
      expect(YoutubeConnection.where(user_id: user.id)).to be_empty
    end

    it "失効の失敗（一時的）でも、保存したトークンを削除する。結果は :failed（cause: unavailable）を返す" do
      allow(token_client).to receive(:revoke).and_raise(unavailable_error)

      result = vault.revoke(user_id: user.id)

      expect(result).to have_attributes(outcome: :failed, cause: :unavailable)
      expect(result.confirmed?).to be(false)
      expect(YoutubeConnection.where(user_id: user.id)).to be_empty
    end

    it "失効の失敗（想定外の応答）でも削除する。結果は :failed（cause: rejected）" do
      allow(token_client).to receive(:revoke).and_raise(YouTubeErrors::UnexpectedResponse.new(call_kind: :token_revoke, status: 403))

      expect(vault.revoke(user_id: user.id)).to have_attributes(outcome: :failed, cause: :rejected)
      expect(YoutubeConnection.where(user_id: user.id)).to be_empty
    end

    it "暗号文が復号できなくても、削除する。Google は呼べない。結果は :failed（cause: undecryptable）" do
      YoutubeConnection.where(user_id: user.id).update_all(refresh_token_ciphertext: "not-a-ciphertext")
      expect(token_client).not_to receive(:revoke)

      expect(vault.revoke(user_id: user.id)).to have_attributes(outcome: :failed, cause: :undecryptable)
      expect(YoutubeConnection.where(user_id: user.id)).to be_empty
    end

    it "想定外の例外（実装の誤り）でも、保存したトークンは削除する。例外は、そのまま伝える" do
      allow(token_client).to receive(:revoke).and_raise(RuntimeError, "boom")

      expect { vault.revoke(user_id: user.id) }.to raise_error(RuntimeError, "boom")
      expect(YoutubeConnection.where(user_id: user.id)).to be_empty
    end

    it "認可失効（revoked）の接続でも、Google へ失効を送り、削除する" do
      YoutubeConnection.where(user_id: user.id).update_all(state: "revoked")
      expect(token_client).to receive(:revoke).with(token: refresh_token).and_return(:already_invalid)

      vault.revoke(user_id: user.id)

      expect(YoutubeConnection.where(user_id: user.id)).to be_empty
    end

    it "メモリ上のアクセストークンも破棄する" do
      allow(token_client).to receive(:refresh).and_return(tokens("ya29.dummy-1"))
      allow(token_client).to receive(:revoke).and_return(:revoked)
      vault.access_token(user_id: user.id, now: now)

      vault.revoke(user_id: user.id)

      expect(cache.size).to eq(0)
    end

    it "接続が無ければ :no_connection（Google を呼ばない）。何度呼んでも同じ（冪等）" do
      allow(token_client).to receive(:revoke).and_return(:revoked)
      vault.revoke(user_id: user.id)

      expect(vault.revoke(user_id: user.id)).to have_attributes(outcome: :no_connection, cause: nil)
      expect(token_client).to have_received(:revoke).once
    end

    it "他のアカウントの接続は、削除しない・失効させない" do
      other_user = create(:user)
      connect(other_user, token: "1//dummy-other")
      allow(token_client).to receive(:revoke).and_return(:revoked)

      vault.revoke(user_id: user.id)

      expect(YoutubeConnection.where(user_id: other_user.id).count).to eq(1)
      expect(token_client).to have_received(:revoke).with(token: refresh_token)
    end

    it "ログ・結果の inspect に、トークンを出さない" do
      allow(token_client).to receive(:revoke).and_raise(unavailable_error)
      result = nil

      output = capture_logs { result = vault.revoke(user_id: user.id) }

      [ output, result.inspect ].each { |text| expect(text).not_to include(refresh_token) }
    end
  end

  describe "#inspect" do
    it "鍵・キャッシュの内容を出さない" do
      expect(vault.inspect).to eq("#<TokenVault>")
      expect(vault.to_s).not_to include(key)
    end
  end

  describe "構築" do
    it "token_client は必須。cache は AccessTokenCache（違反は ArgumentError）" do
      expect { described_class.new(key: key, token_client: nil, cache: cache) }.to raise_error(ArgumentError, /token_client/)
      expect { described_class.new(key: key, token_client: token_client, cache: Object.new) }.to raise_error(ArgumentError, /cache/)
    end

    it "cache を省くと、新しいキャッシュを持つ（共有しない）" do
      first = described_class.new(key: key, token_client: token_client)
      second = described_class.new(key: key, token_client: token_client)
      connect(user, with: first)
      allow(token_client).to receive(:refresh).and_return(tokens("ya29.dummy-1"), tokens("ya29.dummy-2"))

      expect(first.access_token(user_id: user.id, now: now)).to eq("ya29.dummy-1")
      expect(second.access_token(user_id: user.id, now: now)).to eq("ya29.dummy-2")
    end
  end
end
