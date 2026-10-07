require "rails_helper"
require "support/model_support"
require "support/log_capture"
require "digest"

# サーバー側のセッション（issue #7。requirements.md 7.1・20.3・28.1。src/contracts/http-api.md 1.3）。
#   発行      乱数 32 バイトの URL 安全な文字列。要約値（SHA-256）だけを sessions.token_digest に保存する
#   検索      有効なセッションだけ（破棄済み・期限切れは無効）。読み取りだけで、書き込まない
#   最終利用の更新  last_used_at と expires_at（最終利用から 30 日）
#   破棄      sessions の行を消す
RSpec.describe SessionStore do
  let(:store) { described_class.new }
  let(:user) { create(:user) }
  let(:now) { Time.utc(2026, 10, 7, 4, 30, 0) }

  describe "#issue" do
    it "Issued（token と session）を返す" do
      issued = store.issue(user: user, now: now)

      expect(issued.token).to be_a(String)
      expect(issued.session).to be_a(Session).and be_persisted
      expect(issued.session.user).to eq(user)
    end

    it "token は、乱数 32 バイトの URL 安全な文字列（43 文字の base64url。パディングなし）" do
      token = store.issue(user: user, now: now).token

      expect(token).to match(/\A[A-Za-z0-9_-]{43}\z/)
      expect(Base64.urlsafe_decode64(token).bytesize).to eq(32)
    end

    it "発行のたびに、異なる token（乱数）" do
      tokens = Array.new(20) { store.issue(user: user, now: now).token }

      expect(tokens.uniq.size).to eq(20)
    end

    it "DB には、要約値（SHA-256 の 16 進）だけを保存し、token そのものは保存しない" do
      issued = store.issue(user: user, now: now)
      row = Session.find(issued.session.id)

      expect(row.token_digest).to eq(Digest::SHA256.hexdigest(issued.token))
      expect(row.token_digest).to match(/\A\h{64}\z/)
      expect(row.attributes.values.map(&:to_s)).not_to include(issued.token)
      expect(Session.connection.select_values("SELECT token_digest FROM sessions")).not_to include(issued.token)
    end

    it "last_used_at は発行の時刻、expires_at は 30 日後（最終利用から 30 日）" do
      session = store.issue(user: user, now: now).session

      expect(session.last_used_at).to eq(now)
      expect(session.created_at).to eq(now)
      expect(session.expires_at).to eq(now + 30.days)
    end

    it "有効期間は、契約の保持期間（retention.session_days_after_last_use）と同じ" do
      expect(described_class::LIFETIME).to eq(Contract::Limits::RETENTION.fetch("session_days_after_last_use").days)
    end

    it "アカウントが保存されていなければ、例外にする（アカウントの無いセッションを作らない）" do
      expect { store.issue(user: User.new, now: now) }.to raise_error(ArgumentError)
      expect { store.issue(user: nil, now: now) }.to raise_error(ArgumentError)
    end

    it "now が時刻でなければ、例外にする" do
      expect { store.issue(user: user, now: nil) }.to raise_error(ArgumentError)
      expect { store.issue(user: user, now: "2026-10-07") }.to raise_error(ArgumentError)
    end

    it "1 つのアカウントが、複数のセッションを持てる（複数の端末）" do
      first = store.issue(user: user, now: now)
      second = store.issue(user: user, now: now)

      expect(store.find(first.token, now: now)).to eq(first.session)
      expect(store.find(second.token, now: now)).to eq(second.session)
    end
  end

  describe "#find" do
    let!(:issued) { store.issue(user: user, now: now) }

    it "有効なセッションを返す（アカウントも引ける）" do
      found = store.find(issued.token, now: now + 1.minute)

      expect(found).to eq(issued.session)
      expect(found.user).to eq(user)
    end

    it "読み取りだけで、最終利用を更新しない" do
      store.find(issued.token, now: now + 10.days)

      expect(Session.find(issued.session.id).last_used_at).to eq(now)
      expect(Session.find(issued.session.id).expires_at).to eq(now + 30.days)
    end

    {
      "期限の 1 秒前" => [ 30.days - 1.second, true ],
      "期限の瞬間（expires_at と同じ）" => [ 30.days, false ],
      "期限の 1 秒後" => [ 30.days + 1.second, false ],
      "1 年後" => [ 365.days, false ],
      "発行の直後" => [ 0.seconds, true ]
    }.each do |label, (elapsed, valid)|
      it "#{label}は、#{valid ? '有効' : '無効（期限切れ）'}" do
        found = store.find(issued.token, now: now + elapsed)

        expect(found.nil?).to be(!valid)
      end
    end

    it "未知の token は nil" do
      expect(store.find(SecureRandom.urlsafe_base64(32), now: now)).to be_nil
    end

    it "破棄したセッションは nil" do
      store.revoke(issued.session)

      expect(store.find(issued.token, now: now)).to be_nil
    end

    {
      "nil" => nil,
      "空" => "",
      "短い" => "abc",
      "42 文字" => "a" * 42,
      "44 文字" => "a" * 44,
      "使えない文字（+ /）" => "#{'a' * 41}+/",
      "空白を含む" => "#{'a' * 42} ",
      "改行を含む" => "#{'a' * 42}\n",
      "SQL の断片" => "' OR '1'='1",
      "数値" => 123,
      "配列" => [ "a" * 43 ],
      "Hash" => { "a" => 1 }
    }.each do |label, token|
      it "形が違う token（#{label}）は、DB を引かずに nil" do
        found = :not_called
        statements = capture_sql { found = store.find(token, now: now) }

        expect(found).to be_nil
        expect(statements).to be_empty
      end
    end

    it "他のアカウントのセッションと取り違えない（要約値の一意索引で、1 件に決まる）" do
      other = store.issue(user: create(:user), now: now)

      expect(store.find(issued.token, now: now).user).to eq(user)
      expect(store.find(other.token, now: now).user).not_to eq(user)
    end
  end

  describe "#touch（最終利用の更新）" do
    let!(:issued) { store.issue(user: user, now: now) }

    it "last_used_at を now にし、expires_at を now の 30 日後にする" do
      later = now + 10.days

      store.touch(issued.session, now: later)

      row = Session.find(issued.session.id)
      expect(row.last_used_at).to eq(later)
      expect(row.expires_at).to eq(later + 30.days)
    end

    it "更新すれば、元の期限を過ぎても、有効（最終利用から 30 日）" do
      store.touch(issued.session, now: now + 29.days)

      expect(store.find(issued.token, now: now + 40.days)).to eq(issued.session)
      expect(store.find(issued.token, now: now + 60.days)).to be_nil
    end

    it "1 つの UPDATE 文で、2 つの列を同時に更新する（途中の状態を作らない）" do
      statements = capture_sql { store.touch(issued.session, now: now + 1.day) }

      updates = statements.grep(/\AUPDATE "sessions"/)
      expect(updates.size).to eq(1)
      expect(updates.first).to include("last_used_at").and include("expires_at")
    end

    it "セッションの他の列（token_digest・user_id）を変えない" do
      before = Session.find(issued.session.id).attributes.slice("token_digest", "user_id", "created_at")

      store.touch(issued.session, now: now + 1.day)

      expect(Session.find(issued.session.id).attributes.slice("token_digest", "user_id", "created_at")).to eq(before)
    end

    it "now が時刻でなければ、例外にする" do
      expect { store.touch(issued.session, now: nil) }.to raise_error(ArgumentError)
    end

    it "破棄済みのセッションに対しては、何も起こさず、例外にもしない" do
      store.revoke(issued.session)

      expect { store.touch(issued.session, now: now + 1.day) }.not_to raise_error
      expect(Session.exists?(issued.session.id)).to be(false)
    end
  end

  describe "#revoke（破棄）" do
    let!(:issued) { store.issue(user: user, now: now) }

    it "セッションの行を消し、以後は無効" do
      store.revoke(issued.session)

      expect(Session.exists?(issued.session.id)).to be(false)
      expect(store.find(issued.token, now: now)).to be_nil
    end

    it "同じセッションを 2 回破棄しても、例外にならない（冪等）" do
      store.revoke(issued.session)

      expect { store.revoke(issued.session) }.not_to raise_error
    end

    it "他のセッションには影響しない" do
      other = store.issue(user: user, now: now)

      store.revoke(issued.session)

      expect(store.find(other.token, now: now)).to eq(other.session)
    end
  end

  describe "#revoke_all（アカウントのすべてのセッションの破棄）" do
    it "指定したアカウントのセッションだけを、すべて破棄する（アカウント削除・ログアウトの全端末向け）" do
      mine = [ store.issue(user: user, now: now), store.issue(user: user, now: now) ]
      other = store.issue(user: create(:user), now: now)

      expect(store.revoke_all(user)).to eq(2)

      mine.each { |issued| expect(store.find(issued.token, now: now)).to be_nil }
      expect(store.find(other.token, now: now)).to eq(other.session)
    end
  end

  describe "ログへ出さない" do
    it "要約値・token を、ログへ出さない（SQL のバインド値は、filter_attributes で伏せる）" do
      issued = nil
      output = capture_logs do
        issued = store.issue(user: user, now: now)
        store.find(issued.token, now: now)
        store.touch(issued.session, now: now + 1.day)
        store.revoke(issued.session)
      end

      expect(output).not_to include(issued.token)
      expect(output).not_to include(Digest::SHA256.hexdigest(issued.token))
    end
  end
end
