require "rails_helper"
require "support/model_support"

# アカウントの登録と、削除直後の再登録の保留 AccountRegistry（issue #8。requirements.md 7.1・7.4・28.2）。
#   find_or_register(google_sub:, now:)  :existing（既存）・:created（作成）・:held（削除から間もない。アカウントを作らない）
#   record_hold(google_sub:, now:)       削除時に #16 が呼ぶ。sub の要約値（HMAC-SHA256。鍵は SESSION_SECRET から導出）と、その利用日を記録する
#   release_expired(now:)                利用日の終わりを過ぎた保留を消去する（#15 の保持期間の適用が呼ぶ）
# 保留は、削除時点の利用日の終わり（次の JST 03:00）まで。メール・氏名・プロフィールは取得しない（保存するのは sub だけ）。
RSpec.describe AccountRegistry do
  let(:secret) { "dummy-secret-key-base-for-account-registry-0001" }
  let(:registry) { described_class.new(secret: secret) }
  let(:sub) { "dummy-google-sub-20001" }
  # JST 2026-10-07 13:00（利用日 2026-10-07）
  let(:deleted_at) { Time.utc(2026, 10, 7, 4, 0, 0) }
  let(:now) { Time.utc(2026, 10, 8, 3, 0, 0) }

  def jst(year, month, day, hour, minute = 0, second = 0)
    Time.new(year, month, day, hour, minute, second, "+09:00")
  end

  describe "#find_or_register" do
    it "未登録の sub: :created。アカウントを作る（sub・作成時刻・最終ログイン時刻だけ）" do
      result = registry.find_or_register(google_sub: sub, now: now)

      expect(result.outcome).to eq(:created)
      expect(result).to eq(:created) # 結果の符号とも、== で比較できる
      expect(result.created?).to be(true)
      expect(result.existing?).to be(false)
      expect(result.held?).to be(false)
      expect(result.user).to be_persisted
      expect(result.user.google_sub).to eq(sub)
      expect(result.user.created_at).to eq(now)
      expect(result.user.last_login_at).to eq(now)
      expect(User.count).to eq(1)
    end

    it "登録済みの sub: :existing。同じアカウントを返し、増やさない・書き換えない" do
      user = create(:user, google_sub: sub, last_login_at: now - 1.day)

      result = registry.find_or_register(google_sub: sub, now: now)

      expect(result.outcome).to eq(:existing)
      expect(result).to eq(:existing)
      expect(result.existing?).to be(true)
      expect(result.user.id).to eq(user.id)
      expect(User.count).to eq(1)
      expect(User.find(user.id).last_login_at).to eq(now - 1.day)
    end

    it "users の列は、id・google_sub・created_at・last_login_at だけ（メール・氏名・プロフィールを保存する場所が無い）" do
      expect(User.column_names).to match_array(%w[ id google_sub created_at last_login_at ])
    end

    it "作成後の値に、sub 以外の識別情報が無い（行の全属性を調べる）" do
      registry.find_or_register(google_sub: sub, now: now)

      attributes = User.first.attributes

      expect(attributes.keys).to match_array(%w[ id google_sub created_at last_login_at ])
      expect(attributes.except("id", "google_sub", "created_at", "last_login_at")).to be_empty
    end

    it "別の sub は別のアカウント" do
      first = registry.find_or_register(google_sub: sub, now: now)
      second = registry.find_or_register(google_sub: "dummy-google-sub-20002", now: now)

      expect(first.user.id).not_to eq(second.user.id)
      expect(User.count).to eq(2)
    end

    it "sub の大文字・小文字は区別する（Google の sub は大文字小文字を区別する ASCII）" do
      upper = registry.find_or_register(google_sub: "AbC123", now: now)
      lower = registry.find_or_register(google_sub: "abc123", now: now)

      expect(upper.user.id).not_to eq(lower.user.id)
    end

    it "2 回目の呼び出しは :existing（:created は 1 回だけ）" do
      outcomes = Array.new(3) { registry.find_or_register(google_sub: sub, now: now).outcome }

      expect(outcomes).to eq(%i[ created existing existing ])
    end

    it "いくつかの引数の誤りは ArgumentError（sub が空・文字列でない・長すぎる・表示できない文字、now が Time でない）" do
      [ nil, "", "  ", 123, [ "a" ], "a" * 256, "dummy sub", "dummy\nsub", "dummy-#{[ 0x3042 ].pack('U')}" ].each do |bad|
        expect { registry.find_or_register(google_sub: bad, now: now) }.to raise_error(ArgumentError, /google_sub/)
      end
      [ nil, "2026-10-08", 1_760_000_000, Date.new(2026, 10, 8) ].each do |bad|
        expect { registry.find_or_register(google_sub: sub, now: bad) }.to raise_error(ArgumentError, /now/)
      end
      expect(User.count).to eq(0)
    end

    it "sub が 255 文字までは通る" do
      expect(registry.find_or_register(google_sub: "a" * 255, now: now).outcome).to eq(:created)
    end
  end

  describe "再登録の保留" do
    it "削除（record_hold）の直後: :held。アカウントを作らない・user は nil" do
      registry.record_hold(google_sub: sub, now: deleted_at)

      result = registry.find_or_register(google_sub: sub, now: deleted_at + 1.minute)

      expect(result.outcome).to eq(:held)
      expect(result).to eq(:held)
      expect(result.held?).to be(true)
      expect(result.user).to be_nil
      expect(User.count).to eq(0)
    end

    it "結果は、符号（シンボル）と == で比較できる。ほかの符号・ほかの結果とは等しくない" do
      created = registry.find_or_register(google_sub: sub, now: now)
      existing = registry.find_or_register(google_sub: sub, now: now)

      expect(created == :created).to be(true)
      expect(created == :existing).to be(false)
      expect(created == :held).to be(false)
      expect(existing == :existing).to be(true)
      expect(created == existing).to be(false) # outcome が違う
      expect(created == "created").to be(false) # 文字列とは比較しない
    end

    it "保留は、削除時点の利用日の終わりまで: 削除の翌日の JST 02:59:59 は保留、JST 03:00:00 は登録できる" do
      registry.record_hold(google_sub: sub, now: deleted_at) # 2026-10-07 13:00 JST（利用日 2026-10-07）

      expect(registry.find_or_register(google_sub: sub, now: jst(2026, 10, 8, 2, 59, 59)).outcome).to eq(:held)
      expect(User.count).to eq(0)
      expect(registry.find_or_register(google_sub: sub, now: jst(2026, 10, 8, 3, 0, 0)).outcome).to eq(:created)
      expect(User.count).to eq(1)
    end

    it "削除の翌日の JST 02:59（分の単位）は保留、03:00 は可" do
      registry.record_hold(google_sub: sub, now: jst(2026, 10, 7, 13, 0))

      expect(registry.find_or_register(google_sub: sub, now: jst(2026, 10, 8, 2, 59)).outcome).to eq(:held)
      expect(registry.find_or_register(google_sub: sub, now: jst(2026, 10, 8, 3, 0)).outcome).to eq(:created)
    end

    it "削除が JST 03:00 より前（00:30）なら、前の利用日の終わり（同じ日の JST 03:00）まで" do
      registry.record_hold(google_sub: sub, now: jst(2026, 10, 8, 0, 30)) # 利用日 2026-10-07

      expect(registry.find_or_register(google_sub: sub, now: jst(2026, 10, 8, 2, 59, 59)).outcome).to eq(:held)
      expect(registry.find_or_register(google_sub: sub, now: jst(2026, 10, 8, 3, 0, 0)).outcome).to eq(:created)
    end

    it "削除が JST 02:59:59 でも、その利用日の終わり（JST 03:00:00）まで" do
      registry.record_hold(google_sub: sub, now: jst(2026, 10, 8, 2, 59, 59))

      expect(registry.find_or_register(google_sub: sub, now: jst(2026, 10, 8, 2, 59, 59)).outcome).to eq(:held)
      expect(registry.find_or_register(google_sub: sub, now: jst(2026, 10, 8, 3, 0, 0)).outcome).to eq(:created)
    end

    it "削除が JST 03:00:00 なら、新しい利用日なので、翌日の JST 03:00 まで" do
      registry.record_hold(google_sub: sub, now: jst(2026, 10, 8, 3, 0, 0))

      expect(registry.find_or_register(google_sub: sub, now: jst(2026, 10, 9, 2, 59, 59)).outcome).to eq(:held)
      expect(registry.find_or_register(google_sub: sub, now: jst(2026, 10, 9, 3, 0, 0)).outcome).to eq(:created)
    end

    it "保留の判定は、実時計ではなく引数の now" do
      registry.record_hold(google_sub: sub, now: deleted_at)

      expect(registry.find_or_register(google_sub: sub, now: deleted_at + 1.hour).outcome).to eq(:held)
      expect(registry.find_or_register(google_sub: sub, now: deleted_at + 3.days).outcome).to eq(:created)
    end

    it "別の sub は保留されない" do
      registry.record_hold(google_sub: sub, now: deleted_at)

      expect(registry.find_or_register(google_sub: "dummy-google-sub-20002", now: deleted_at + 1.minute).outcome).to eq(:created)
    end

    it "既存のアカウントがあれば、古い保留の行が残っていても :existing（保留で締め出さない）" do
      user = create(:user, google_sub: sub)
      DeletionHold.create!(sub_digest: registry.digest(sub), hold_usage_date: Date.new(2026, 10, 8))

      result = registry.find_or_register(google_sub: sub, now: jst(2026, 10, 8, 12, 0))

      expect(result.outcome).to eq(:existing)
      expect(result.user.id).to eq(user.id)
    end

    it "保留の最中のログインは、保留を延長しない（保留の行を書き換えない）" do
      registry.record_hold(google_sub: sub, now: deleted_at)
      before = DeletionHold.all.map(&:attributes)

      3.times { registry.find_or_register(google_sub: sub, now: deleted_at + 1.hour) }

      expect(DeletionHold.all.map(&:attributes)).to eq(before)
    end
  end

  describe "#record_hold" do
    it "sub の要約値（HMAC-SHA256 の 16 進 64 文字）と、削除時点の利用日だけを記録する" do
      date = registry.record_hold(google_sub: sub, now: deleted_at)

      hold = DeletionHold.sole
      expect(date).to eq(Date.new(2026, 10, 7))
      expect(hold.attributes.keys).to match_array(%w[ sub_digest hold_usage_date ])
      expect(hold.sub_digest).to match(/\A\h{64}\z/)
      expect(hold.hold_usage_date).to eq(Date.new(2026, 10, 7))
    end

    it "要約値は、SESSION_SECRET から導出した鍵の HMAC-SHA256（sub から復元できない一方向の値）" do
      key = DerivedKeys.new(secret: secret).derive(described_class::KEY_PURPOSE)
      expected = OpenSSL::HMAC.hexdigest("SHA256", key, sub)

      expect(registry.digest(sub)).to eq(expected)
      registry.record_hold(google_sub: sub, now: deleted_at)
      expect(DeletionHold.sole.sub_digest).to eq(expected)
    end

    it "要約値は、sub を含まない。DB のどの列にも sub が現れない" do
      registry.record_hold(google_sub: sub, now: deleted_at)

      dump = DeletionHold.all.map { |hold| hold.attributes.values.map(&:to_s) }.flatten.join(" ")
      expect(dump).not_to include(sub)
      expect(registry.digest(sub)).not_to include(sub)
    end

    it "同じ sub・同じ鍵なら同じ要約値。sub が違えば違う。鍵（SESSION_SECRET）が違えば違う" do
      other = described_class.new(secret: "dummy-another-secret-key-base-0002")

      expect(registry.digest(sub)).to eq(registry.digest(sub))
      expect(registry.digest(sub)).not_to eq(registry.digest("dummy-google-sub-20002"))
      expect(registry.digest(sub)).not_to eq(other.digest(sub))
    end

    it "要約値の鍵は、CSRF トークンの鍵・bl_oauth の暗号鍵とは別（用途の分離）" do
      derived = DerivedKeys.new(secret: secret)

      expect(derived.derive(described_class::KEY_PURPOSE)).not_to eq(derived.derive(CsrfToken::PURPOSE))
      expect(derived.derive(described_class::KEY_PURPOSE)).not_to eq(derived.derive(OAuthStateCookie::KEY_PURPOSE))
    end

    it "同じ sub を同じ日に 2 回記録しても、1 行" do
      2.times { registry.record_hold(google_sub: sub, now: deleted_at) }

      expect(DeletionHold.count).to eq(1)
    end

    it "あとの利用日に記録し直すと、保留の日付が新しくなる（古い行が残っていても）" do
      registry.record_hold(google_sub: sub, now: deleted_at)
      registry.record_hold(google_sub: sub, now: deleted_at + 3.days)

      expect(DeletionHold.sole.hold_usage_date).to eq(Date.new(2026, 10, 10))
    end

    it "利用日は UsageCalendar で決める（JST 03:00 の区切り）" do
      expect(registry.record_hold(google_sub: sub, now: jst(2026, 10, 8, 2, 59, 59))).to eq(Date.new(2026, 10, 7))
      expect(registry.record_hold(google_sub: "dummy-google-sub-20002", now: jst(2026, 10, 8, 3, 0, 0))).to eq(Date.new(2026, 10, 8))
    end

    it "引数の誤りは ArgumentError" do
      expect { registry.record_hold(google_sub: "", now: deleted_at) }.to raise_error(ArgumentError, /google_sub/)
      expect { registry.record_hold(google_sub: sub, now: "2026-10-07") }.to raise_error(ArgumentError, /now/)
      expect(DeletionHold.count).to eq(0)
    end
  end

  describe "#release_expired" do
    def hold(sub_name, date)
      DeletionHold.create!(sub_digest: registry.digest(sub_name), hold_usage_date: date)
    end

    it "利用日の終わりを過ぎた保留を消去し、消去した件数を返す" do
      hold("dummy-sub-a", Date.new(2026, 10, 6))
      hold("dummy-sub-b", Date.new(2026, 10, 7))
      hold("dummy-sub-c", Date.new(2026, 10, 8))

      count = registry.release_expired(now: jst(2026, 10, 8, 12, 0)) # 利用日 2026-10-08

      expect(count).to eq(2)
      expect(DeletionHold.pluck(:hold_usage_date)).to eq([ Date.new(2026, 10, 8) ])
    end

    it "境界: 利用日の終わりの 1 秒前（JST 02:59:59）はまだ消さない、JST 03:00:00 で消す" do
      hold("dummy-sub-a", Date.new(2026, 10, 7))

      expect(registry.release_expired(now: jst(2026, 10, 8, 2, 59, 59))).to eq(0)
      expect(DeletionHold.count).to eq(1)
      expect(registry.release_expired(now: jst(2026, 10, 8, 3, 0, 0))).to eq(1)
      expect(DeletionHold.count).to eq(0)
    end

    it "消去する保留が無ければ 0" do
      expect(registry.release_expired(now: now)).to eq(0)
    end

    it "アカウントには触れない" do
      create(:user)
      hold("dummy-sub-a", Date.new(2026, 10, 1))

      registry.release_expired(now: now)

      expect(User.count).to eq(1)
    end

    it "消去のあとは、同じ sub を登録できる" do
      registry.record_hold(google_sub: sub, now: deleted_at)
      registry.release_expired(now: jst(2026, 10, 8, 3, 0, 0))

      expect(registry.find_or_register(google_sub: sub, now: jst(2026, 10, 8, 3, 0, 1)).outcome).to eq(:created)
    end

    it "now が Time でなければ ArgumentError" do
      expect { registry.release_expired(now: "2026-10-08") }.to raise_error(ArgumentError, /now/)
    end
  end

  describe "鍵" do
    it "既定の鍵は、アプリケーションの秘密値（SESSION_SECRET = secret_key_base）" do
      default = described_class.new

      expect(default.digest(sub)).to eq(described_class.new(secret: Rails.application.secret_key_base).digest(sub))
    end

    it "秘密値が空では構築できない（ArgumentError）" do
      [ nil, "", "  " ].each do |bad|
        expect { described_class.new(secret: bad) }.to raise_error(ArgumentError, /secret/)
      end
    end

    it "inspect に、鍵・要約値を出さない" do
      expect(registry.inspect).not_to include(secret)
      expect(registry.inspect).not_to include(registry.digest(sub))
    end
  end

  describe "同時の最初のログイン" do
    self.use_transactional_tests = false

    after do
      User.where(google_sub: "dummy-google-sub-concurrent").delete_all
    end

    it "同じ sub が同時に登録されても、アカウントは 1 つ。:created は 1 回だけ、もう一方は :existing" do
      results = run_concurrently(2) { described_class.new(secret: secret).find_or_register(google_sub: "dummy-google-sub-concurrent", now: now) }

      expect(results.map(&:first)).to eq(%i[ ok ok ])
      expect(results.map { |_, registration| registration.outcome }).to match_array(%i[ created existing ])
      expect(User.where(google_sub: "dummy-google-sub-concurrent").count).to eq(1)
      expect(results.map { |_, registration| registration.user.id }.uniq.size).to eq(1)
    end
  end

  describe "外側のトランザクションの中でも使える" do
    it "同時の登録で一意制約に当たっても、外側のトランザクションが壊れない（セーブポイントで包んでいる）" do
      existing = create(:user, google_sub: sub)
      # 「存在しない」と判定した直後に、同時の要求が同じ sub を登録した、という競合を再現する（最初の検索だけ nil）
      allow(User).to receive(:find_by).and_call_original
      allow(User).to receive(:find_by).with(google_sub: sub).and_return(nil)

      result = ActiveRecord::Base.transaction { registry.find_or_register(google_sub: sub, now: now) }

      expect(result.outcome).to eq(:existing)
      expect(result.user.id).to eq(existing.id)
      expect(User.count).to eq(1)
    end
  end
end
