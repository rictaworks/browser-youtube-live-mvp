require "rails_helper"
require "support/model_support"
require "services/support/ledger_support"

# 日次の利用枠と開始試行（requirements.md 8.1・8.2・14 章・27 章「整合性」・20.1 の daily_usages）。
# 規則（既定: 利用枠 1 回・開始試行 3 回）は設定値。利用日ごとの行（アカウント × 利用日で一意）に、消費と試行を数える。
#   remaining / attempts_remaining   読み取り（行を作らない。行が無ければ 0 件として扱う）
#   ensure_for!                      行の取得・作成（upsert）。受理（#12）が、行ロックを取るために使う
#   consume!                         利用枠の消費。確定待ちからライブへの遷移と、同一のトランザクションで呼ばれる前提
#   count_attempt!                   開始試行の計上。準備の開始と、同一のトランザクションで呼ばれる前提
#   grant_extra!                     追加の 1 回の付与（管理画面の手動リセット）
# 同時の呼び出しと、途中で失敗したときの取り消しは、daily_allowance_concurrency_spec.rb。
RSpec.describe DailyAllowance do
  include LedgerSupport

  # let! にする（SQL の記録のブロックの内側で、初めて作られて、users への INSERT まで数えないように）
  let!(:user) { create(:user) }
  let(:usage_date) { Date.new(2026, 10, 7) }
  let(:settings) { Settings.defaults }

  def usage_of(owner, date = usage_date)
    DailyUsage.owned_by(owner).find_by(usage_date: date)
  end

  describe ".remaining（利用枠の残り: 利用枠 + 追加の付与 - 消費。下限 0）" do
    it "行が無ければ 0 件として扱う（既定の利用枠 1 回が、そのまま残り）。行を作らない" do
      expect(described_class.remaining(user_id: user.id, usage_date: usage_date, settings: settings)).to eq(1)
      expect(DailyUsage.count).to eq(0)
    end

    {
      "消費 0・追加 0" => [ 0, 0, 1, 1 ],
      "消費 1・追加 0（消費済み）" => [ 1, 0, 1, 0 ],
      "消費 1・追加 1（手動リセットで追加の 1 回）" => [ 1, 1, 1, 1 ],
      "消費 2・追加 1（使い切り）" => [ 2, 1, 1, 0 ],
      "消費が利用枠を超えている（下限 0）" => [ 3, 0, 1, 0 ],
      "利用枠 5・消費 2" => [ 2, 0, 5, 3 ],
      "利用枠 5・消費 2・追加 2" => [ 2, 2, 5, 5 ],
      "利用枠 0（既定値の変更）・消費 0" => [ 0, 0, 0, 0 ],
      "利用枠 0・追加 1" => [ 0, 1, 0, 1 ]
    }.each do |label, (consumed, extra, allowance, expected)|
      it "#{label}: 残り #{expected}" do
        create(:daily_usage, user: user, usage_date: usage_date, consumed_count: consumed, extra_grants: extra)

        result = described_class.remaining(user_id: user.id, usage_date: usage_date, settings: settings.with(daily_allowance: allowance))

        expect(result).to eq(expected)
      end
    end

    it "別の利用日の消費は、数えない（利用日ごと）" do
      create(:daily_usage, user: user, usage_date: usage_date - 1, consumed_count: 1)

      expect(described_class.remaining(user_id: user.id, usage_date: usage_date, settings: settings)).to eq(1)
      expect(described_class.remaining(user_id: user.id, usage_date: usage_date - 1, settings: settings)).to eq(0)
    end

    it "別のアカウントの消費は、数えない（アカウントごと。他のアカウントの行へ到達しない）" do
      create(:daily_usage, user: create(:user), usage_date: usage_date, consumed_count: 1)

      expect(described_class.remaining(user_id: user.id, usage_date: usage_date, settings: settings)).to eq(1)
    end

    it "アカウントは、User でも、識別子の文字列でもよい" do
      create(:daily_usage, user: user, usage_date: usage_date, consumed_count: 1)

      expect(described_class.remaining(user_id: user, usage_date: usage_date, settings: settings)).to eq(0)
    end

    it "不正な引数は ArgumentError（アカウントを特定できない・利用日が Date でない・設定が Settings でない）" do
      expect { described_class.remaining(user_id: nil, usage_date: usage_date, settings: settings) }.to raise_error(ArgumentError)
      expect { described_class.remaining(user_id: "not-a-uuid", usage_date: usage_date, settings: settings) }.to raise_error(ArgumentError)
      expect { described_class.remaining(user_id: user.id, usage_date: "2026-10-07", settings: settings) }.to raise_error(ArgumentError)
      expect { described_class.remaining(user_id: user.id, usage_date: Time.utc(2026, 10, 7), settings: settings) }.to raise_error(ArgumentError)
      expect { described_class.remaining(user_id: user.id, usage_date: usage_date, settings: nil) }.to raise_error(ArgumentError)
      expect { described_class.remaining(user_id: user.id, usage_date: usage_date, settings: { daily_allowance: 1 }) }.to raise_error(ArgumentError)
    end
  end

  describe ".attempts_remaining（開始試行の残り: 上限 - 計上数。下限 0）" do
    it "行が無ければ 0 件として扱う（既定の上限 3 回が、そのまま残り）。行を作らない" do
      expect(described_class.attempts_remaining(user_id: user.id, usage_date: usage_date, settings: settings)).to eq(3)
      expect(DailyUsage.count).to eq(0)
    end

    {
      "計上 0" => [ 0, 3, 3 ],
      "計上 1" => [ 1, 3, 2 ],
      "計上 2（あと 1 回）" => [ 2, 3, 1 ],
      "計上 3（上限）" => [ 3, 3, 0 ],
      "計上が上限を超えている（下限 0）" => [ 5, 3, 0 ],
      "上限 5・計上 2" => [ 2, 5, 3 ],
      "上限 0・計上 0" => [ 0, 0, 0 ]
    }.each do |label, (count, limit, expected)|
      it "#{label}: 残り #{expected}" do
        create(:daily_usage, user: user, usage_date: usage_date, attempt_count: count)

        result = described_class.attempts_remaining(user_id: user.id, usage_date: usage_date, settings: settings.with(attempt_limit: limit))

        expect(result).to eq(expected)
      end
    end

    it "別の利用日・別のアカウントの計上は、数えない" do
      create(:daily_usage, user: user, usage_date: usage_date + 1, attempt_count: 3)
      create(:daily_usage, user: create(:user), usage_date: usage_date, attempt_count: 3)

      expect(described_class.attempts_remaining(user_id: user.id, usage_date: usage_date, settings: settings)).to eq(3)
    end

    it "不正な引数は ArgumentError" do
      expect { described_class.attempts_remaining(user_id: nil, usage_date: usage_date, settings: settings) }.to raise_error(ArgumentError)
      expect { described_class.attempts_remaining(user_id: user.id, usage_date: nil, settings: settings) }.to raise_error(ArgumentError)
      expect { described_class.attempts_remaining(user_id: user.id, usage_date: usage_date, settings: 3) }.to raise_error(ArgumentError)
    end
  end

  describe ".ensure_for!（利用日ごとの行の取得・作成）" do
    it "行が無ければ作る（消費 0・試行 0・追加 0）。アカウントと利用日の行を返す" do
      usage = described_class.ensure_for!(user_id: user.id, usage_date: usage_date)

      expect(usage).to be_a(DailyUsage)
      expect(usage).to have_attributes(user_id: user.id, usage_date: usage_date, consumed_count: 0, attempt_count: 0, extra_grants: 0)
      expect(usage).to be_persisted
      expect(DailyUsage.count).to eq(1)
    end

    it "行があれば、その行を返す（数を変えない・行を増やさない）" do
      existing = create(:daily_usage, user: user, usage_date: usage_date, consumed_count: 1, attempt_count: 2, extra_grants: 1)

      usage = described_class.ensure_for!(user_id: user.id, usage_date: usage_date)

      expect(usage.id).to eq(existing.id)
      expect(usage).to have_attributes(consumed_count: 1, attempt_count: 2, extra_grants: 1)
      expect(DailyUsage.count).to eq(1)
    end

    it "2 回呼んでも、行は 1 件（同じ行）" do
      first = described_class.ensure_for!(user_id: user.id, usage_date: usage_date)
      second = described_class.ensure_for!(user_id: user.id, usage_date: usage_date)

      expect(second.id).to eq(first.id)
      expect(DailyUsage.owned_by(user).count).to eq(1)
    end

    it "利用日が違えば別の行、アカウントが違えば別の行" do
      other = create(:user)

      ids = [
        described_class.ensure_for!(user_id: user.id, usage_date: usage_date).id,
        described_class.ensure_for!(user_id: user.id, usage_date: usage_date + 1).id,
        described_class.ensure_for!(user_id: other.id, usage_date: usage_date).id
      ]

      expect(ids.uniq.size).to eq(3)
    end

    it "行を FOR UPDATE で確保する（呼び出し側のトランザクションが終わるまで、同じアカウント・利用日の受理を直列にする）" do
      statements = capture_sql { described_class.ensure_for!(user_id: user.id, usage_date: usage_date) }

      inserts = statements.grep(/\AINSERT INTO "daily_usages"/)
      selects = statements.grep(/FROM "daily_usages".* FOR UPDATE/m)
      expect(inserts.size).to eq(1)
      expect(inserts.first).to include("ON CONFLICT").and include("DO NOTHING")
      expect(selects.size).to eq(1)
    end

    it "別のアカウントの行を返さない（アカウントで絞り込む）" do
      other = create(:user)
      other_usage = create(:daily_usage, user: other, usage_date: usage_date)

      usage = described_class.ensure_for!(user_id: user.id, usage_date: usage_date)

      expect(usage.id).not_to eq(other_usage.id)
      expect(usage.user_id).to eq(user.id)
    end

    it "不正な引数は ArgumentError（行を作らない）" do
      expect { described_class.ensure_for!(user_id: nil, usage_date: usage_date) }.to raise_error(ArgumentError)
      expect { described_class.ensure_for!(user_id: "x", usage_date: usage_date) }.to raise_error(ArgumentError)
      expect { described_class.ensure_for!(user_id: user.id, usage_date: nil) }.to raise_error(ArgumentError)
      expect { described_class.ensure_for!(user_id: user.id, usage_date: DateTime.new(2026, 10, 7)) }.to raise_error(ArgumentError)
      expect(DailyUsage.count).to eq(0)
    end

    it "外側のトランザクションに参加する（SAVEPOINT を作らない）" do
      statements = nil
      ActiveRecord::Base.transaction do
        User.exists?(user.id) # トランザクションは、最初の SQL で実体になる（遅延）。記録の前に、外側を実体にしておく
        statements = capture_every_sql { described_class.ensure_for!(user_id: user.id, usage_date: usage_date) }
      end

      expect(statements.grep(/SAVEPOINT/)).to be_empty
    end
  end

  describe ".consume!（利用枠の消費）" do
    let!(:usage) { create(:daily_usage, user: user, usage_date: usage_date) }
    # 状態は、消費に関係しない（遷移と同一のトランザクションで呼ばれる）。タイトル（pending_title）を持てる、受理直後の配信を使う
    let!(:broadcast) { create(:broadcast, user: user, daily_usage: usage, pending_title: "dummy-secret-title") }

    it "配信の利用日（daily_usage_id が指す行）の消費数を 1 増やし、配信の allowance_consumed を立てる。true を返す" do
      expect(described_class.consume!(broadcast, settings: settings)).to be(true)

      expect(usage.reload.consumed_count).to eq(1)
      expect(Broadcast.find(broadcast.id).allowance_consumed).to be(true)
    end

    it "メモリ上の配信にも、消費済みの印が付く（変更済みの印は付かない）" do
      described_class.consume!(broadcast, settings: settings)

      expect(broadcast.allowance_consumed).to be(true)
      expect(broadcast).not_to be_changed
    end

    it "二重の消費をしない: 同じ配信で 2 回呼んでも、消費は 1 回だけ（2 回目は false。例外にしない）" do
      expect(described_class.consume!(broadcast, settings: settings)).to be(true)
      expect(described_class.consume!(broadcast, settings: settings)).to be(false)
      expect(described_class.consume!(Broadcast.find(broadcast.id), settings: settings)).to be(false)

      expect(usage.reload.consumed_count).to eq(1)
    end

    it "古いメモリ上の配信（印が立っていない）で呼んでも、DB の行で判定し、二重に消費しない" do
      stale = Broadcast.find(broadcast.id)
      described_class.consume!(broadcast, settings: settings)

      expect(stale.allowance_consumed).to be(false)
      expect(described_class.consume!(stale, settings: settings)).to be(false)
      expect(stale.allowance_consumed).to be(true)
      expect(usage.reload.consumed_count).to eq(1)
    end

    it "消費先は、受理時の利用日（JST 03:00 をまたいでも変わらない）。別の利用日の行に触れない" do
      next_usage = create(:daily_usage, user: user, usage_date: usage_date + 1)

      described_class.consume!(broadcast, settings: settings)

      expect(usage.reload.consumed_count).to eq(1)
      expect(next_usage.reload.consumed_count).to eq(0)
    end

    it "追加の付与（手動リセット）があれば、利用枠を超えて消費できる" do
      usage.update!(consumed_count: 1, extra_grants: 1)

      expect(described_class.consume!(broadcast, settings: settings)).to be(true)

      expect(usage.reload.consumed_count).to eq(2)
    end

    it "設定の利用枠を増やせば、消費できる" do
      usage.update!(consumed_count: 1)

      expect(described_class.consume!(broadcast, settings: settings.with(daily_allowance: 2))).to be(true)

      expect(usage.reload.consumed_count).to eq(2)
    end

    describe "利用枠が無い（上限）場合は、例外（黙って成功させない）" do
      before { usage.update!(consumed_count: 1) }

      it "DailyAllowance::AllowanceExhausted。消費数も、配信の印も変えない" do
        expect { described_class.consume!(broadcast, settings: settings) }.to raise_error(DailyAllowance::AllowanceExhausted)

        expect(usage.reload.consumed_count).to eq(1)
        expect(Broadcast.find(broadcast.id).allowance_consumed).to be(false)
        expect(broadcast.allowance_consumed).to be(false)
      end

      it "例外を呼び出し側が受けたあとも、途中まで書いた変更が残らない（トランザクションの中でも、書き込みの前に判定する）" do
        ActiveRecord::Base.transaction do
          expect { described_class.consume!(broadcast, settings: settings) }.to raise_error(DailyAllowance::AllowanceExhausted)

          expect(usage.reload.consumed_count).to eq(1)
          expect(Broadcast.find(broadcast.id).allowance_consumed).to be(false)
        end
      end

      it "利用枠が 0 の設定でも、例外" do
        usage.update!(consumed_count: 0)

        expect { described_class.consume!(broadcast, settings: settings.with(daily_allowance: 0)) }
          .to raise_error(DailyAllowance::AllowanceExhausted)
      end

      it "例外のメッセージは、識別子と数だけ（配信のタイトルなどを含まない）" do
        expect { described_class.consume!(broadcast, settings: settings) }.to raise_error(DailyAllowance::AllowanceExhausted) { |error|
          expect(error.message).not_to include("dummy-secret-title")
          expect(error.message).to include(broadcast.id)
        }
      end

      it "すでに消費済みの配信（印が立っている）は、上限でも、例外にならない（冪等。false）" do
        broadcast.update_columns(allowance_consumed: true)

        expect(described_class.consume!(broadcast, settings: settings)).to be(false)
        expect(usage.reload.consumed_count).to eq(1)
      end
    end

    describe "設定を省いた呼び出し（毎回 DB から読む。SettingsStore.current）" do
      it "設定の利用枠 2（system_settings）なら、消費数 1 からでも消費できる" do
        usage.update!(consumed_count: 1)
        SettingsStore.update!(key: "daily_allowance", value: 2)

        expect(described_class.consume!(broadcast)).to be(true)

        expect(usage.reload.consumed_count).to eq(2)
      end

      it "設定の利用枠 0 なら、例外（読み取りは、キャッシュされない）" do
        SettingsStore.update!(key: "daily_allowance", value: 0)

        expect { described_class.consume!(broadcast) }.to raise_error(DailyAllowance::AllowanceExhausted)
      end

      it "行が無ければ、既定の利用枠 1 回で消費できる" do
        expect(described_class.consume!(broadcast)).to be(true)
      end

      it "設定が壊れていれば、既定値で続行せず、例外（SettingsStore::CorruptSetting）。何も変えない" do
        save_without_validation!(SystemSetting.new(key: "daily_allowance", value: "abc", updated_at: Time.current))

        expect { described_class.consume!(broadcast) }.to raise_error(SettingsStore::CorruptSetting)

        expect(usage.reload.consumed_count).to eq(0)
        expect(Broadcast.find(broadcast.id).allowance_consumed).to be(false)
      end
    end

    describe "所有権と引数" do
      it "別のアカウントの利用枠を指す配信は、その行へ到達できない（ActiveRecord::RecordNotFound）。何も変えない" do
        other_usage = create(:daily_usage, user: create(:user), usage_date: usage_date)
        stray = create(:broadcast, :ended, user: user, daily_usage: other_usage)

        expect { described_class.consume!(stray, settings: settings) }.to raise_error(ActiveRecord::RecordNotFound)

        expect(other_usage.reload.consumed_count).to eq(0)
        expect(Broadcast.find(stray.id).allowance_consumed).to be(false)
      end

      it "配信が、保存されていない・Broadcast でない・設定が Settings でない: ArgumentError" do
        expect { described_class.consume!(build(:broadcast, user: user, daily_usage: usage), settings: settings) }.to raise_error(ArgumentError)
        expect { described_class.consume!(nil, settings: settings) }.to raise_error(ArgumentError)
        expect { described_class.consume!(broadcast.id, settings: settings) }.to raise_error(ArgumentError)
        expect { described_class.consume!(broadcast, settings: { daily_allowance: 1 }) }.to raise_error(ArgumentError)
        expect(usage.reload.consumed_count).to eq(0)
      end
    end

    describe "原子性" do
      it "利用枠の行と、配信の行を、FOR UPDATE で確保してから、書く（利用枠の行が先。受理と同じ順序）" do
        statements = capture_sql { described_class.consume!(broadcast, settings: settings) }
        locks = statements.grep(/ FOR UPDATE/).map { |sql| sql[/FROM "(\w+)"/, 1] }

        expect(locks).to eq(%w[ daily_usages broadcasts ])
      end

      it "外側のトランザクションに参加する（SAVEPOINT を作らない）" do
        statements = nil
        ActiveRecord::Base.transaction do
          User.exists?(user.id)
          statements = capture_every_sql { described_class.consume!(broadcast, settings: settings) }
        end

        expect(statements.grep(/SAVEPOINT/)).to be_empty
      end

      it "外側のトランザクションを巻き戻すと、消費も印も取り消される" do
        ActiveRecord::Base.transaction(requires_new: true) do
          described_class.consume!(broadcast, settings: settings)
          raise ActiveRecord::Rollback
        end

        expect(usage.reload.consumed_count).to eq(0)
        expect(Broadcast.find(broadcast.id).allowance_consumed).to be(false)
      end
    end
  end

  describe ".count_attempt!（開始試行の計上）" do
    let!(:usage) { create(:daily_usage, user: user, usage_date: usage_date) }
    let!(:broadcast) { create(:broadcast, user: user, daily_usage: usage) }

    it "配信の利用日の開始試行を 1 増やし、配信の attempt_counted を立てる。true を返す" do
      expect(described_class.count_attempt!(broadcast, settings: settings)).to be(true)

      expect(usage.reload.attempt_count).to eq(1)
      expect(Broadcast.find(broadcast.id).attempt_counted).to be(true)
      expect(broadcast.attempt_counted).to be(true)
      expect(broadcast).not_to be_changed
    end

    it "利用枠の消費数には触れない" do
      described_class.count_attempt!(broadcast, settings: settings)

      expect(usage.reload).to have_attributes(consumed_count: 0, extra_grants: 0)
    end

    it "冪等: 同じ配信で 2 回呼んでも、計上は 1 回だけ（2 回目は false。例外にしない）" do
      expect(described_class.count_attempt!(broadcast, settings: settings)).to be(true)
      expect(described_class.count_attempt!(broadcast, settings: settings)).to be(false)
      expect(described_class.count_attempt!(Broadcast.find(broadcast.id), settings: settings)).to be(false)

      expect(usage.reload.attempt_count).to eq(1)
    end

    it "古いメモリ上の配信でも、DB の行で判定し、二重に計上しない" do
      stale = Broadcast.find(broadcast.id)
      described_class.count_attempt!(broadcast, settings: settings)

      expect(described_class.count_attempt!(stale, settings: settings)).to be(false)
      expect(usage.reload.attempt_count).to eq(1)
    end

    describe "上限（既定 3 回）" do
      {
        "計上 0（残り 3）" => [ 0, true ],
        "計上 1" => [ 1, true ],
        "計上 2（あと 1 回。上限の手前）" => [ 2, true ],
        "計上 3（上限に達している）" => [ 3, false ],
        "計上が上限を超えている" => [ 4, false ]
      }.each do |label, (count, allowed)|
        it "#{label}: #{allowed ? '計上できる' : 'AttemptLimitReached。何も変えない'}" do
          usage.update!(attempt_count: count)

          if allowed
            expect(described_class.count_attempt!(broadcast, settings: settings)).to be(true)
            expect(usage.reload.attempt_count).to eq(count + 1)
          else
            expect { described_class.count_attempt!(broadcast, settings: settings) }.to raise_error(DailyAllowance::AttemptLimitReached)
            expect(usage.reload.attempt_count).to eq(count)
            expect(Broadcast.find(broadcast.id).attempt_counted).to be(false)
          end
        end
      end

      it "上限でも、すでに計上済みの配信は、例外にならない（冪等。false）" do
        usage.update!(attempt_count: 3)
        broadcast.update_columns(attempt_counted: true)

        expect(described_class.count_attempt!(broadcast, settings: settings)).to be(false)
        expect(usage.reload.attempt_count).to eq(3)
      end

      it "設定の上限を、引数の設定から読む" do
        usage.update!(attempt_count: 3)

        expect(described_class.count_attempt!(broadcast, settings: settings.with(attempt_limit: 4))).to be(true)
        expect(usage.reload.attempt_count).to eq(4)
      end

      it "上限 0 の設定では、最初の計上から例外" do
        expect { described_class.count_attempt!(broadcast, settings: settings.with(attempt_limit: 0)) }
          .to raise_error(DailyAllowance::AttemptLimitReached)
      end

      it "例外を呼び出し側が受けたあとも、途中まで書いた変更が残らない" do
        usage.update!(attempt_count: 3)

        ActiveRecord::Base.transaction do
          expect { described_class.count_attempt!(broadcast, settings: settings) }.to raise_error(DailyAllowance::AttemptLimitReached)

          expect(usage.reload.attempt_count).to eq(3)
          expect(Broadcast.find(broadcast.id).attempt_counted).to be(false)
        end
      end

      it "管理画面の手動リセット（grant_extra!）のあとは、また計上できる" do
        usage.update!(attempt_count: 3)
        described_class.grant_extra!(user_id: user.id, usage_date: usage_date)

        expect(described_class.count_attempt!(broadcast, settings: settings)).to be(true)
        expect(usage.reload.attempt_count).to eq(1)
      end
    end

    describe "設定を省いた呼び出し（毎回 DB から読む。SettingsStore.current）" do
      it "設定の上限 4（system_settings）なら、計上 3 からでも計上できる" do
        usage.update!(attempt_count: 3)
        SettingsStore.update!(key: "attempt_limit", value: 4)

        expect(described_class.count_attempt!(broadcast)).to be(true)
      end

      it "設定の上限 0 なら、例外" do
        SettingsStore.update!(key: "attempt_limit", value: 0)

        expect { described_class.count_attempt!(broadcast) }.to raise_error(DailyAllowance::AttemptLimitReached)
      end
    end

    describe "所有権と引数" do
      it "別のアカウントの行を指す配信は、その行へ到達できない（ActiveRecord::RecordNotFound）。何も変えない" do
        other_usage = create(:daily_usage, user: create(:user), usage_date: usage_date)
        stray = create(:broadcast, :ended, user: user, daily_usage: other_usage)

        expect { described_class.count_attempt!(stray, settings: settings) }.to raise_error(ActiveRecord::RecordNotFound)

        expect(other_usage.reload.attempt_count).to eq(0)
      end

      it "配信が、保存されていない・Broadcast でない・設定が Settings でない: ArgumentError" do
        expect { described_class.count_attempt!(build(:broadcast, user: user, daily_usage: usage), settings: settings) }.to raise_error(ArgumentError)
        expect { described_class.count_attempt!(nil, settings: settings) }.to raise_error(ArgumentError)
        expect { described_class.count_attempt!(broadcast, settings: nil) }.to raise_error(ArgumentError)
      end
    end

    describe "原子性" do
      it "外側のトランザクションに参加する（SAVEPOINT を作らない）" do
        statements = nil
        ActiveRecord::Base.transaction do
          User.exists?(user.id) # トランザクションは、最初の SQL で実体になる（遅延）。記録の前に、外側を実体にしておく
          statements = capture_every_sql { described_class.count_attempt!(broadcast, settings: settings) }
        end

        expect(statements.grep(/SAVEPOINT/)).to be_empty
      end

      it "外側のトランザクションを巻き戻すと、計上も印も取り消される" do
        ActiveRecord::Base.transaction(requires_new: true) do
          described_class.count_attempt!(broadcast, settings: settings)
          raise ActiveRecord::Rollback
        end

        expect(usage.reload.attempt_count).to eq(0)
        expect(Broadcast.find(broadcast.id).attempt_counted).to be(false)
      end

      it "利用枠の行と、配信の行を、FOR UPDATE で確保してから、書く（利用枠の行が先。受理と同じ順序）" do
        statements = capture_sql { described_class.count_attempt!(broadcast, settings: settings) }
        locks = statements.grep(/ FOR UPDATE/).map { |sql| sql[/FROM "(\w+)"/, 1] }

        expect(locks).to eq(%w[ daily_usages broadcasts ])
      end
    end
  end

  describe ".grant_extra!（追加の 1 回の付与。開始試行の計数を 0 に戻す）" do
    it "行が無ければ作る（追加 1・試行 0・消費 0）。更新後の行を返す" do
      usage = described_class.grant_extra!(user_id: user.id, usage_date: usage_date)

      expect(usage).to be_a(DailyUsage)
      expect(usage).to have_attributes(user_id: user.id, usage_date: usage_date, extra_grants: 1, attempt_count: 0, consumed_count: 0)
      expect(DailyUsage.count).to eq(1)
    end

    it "行があれば、追加を 1 増やし、開始試行を 0 に戻す。消費数は変えない" do
      existing = create(:daily_usage, user: user, usage_date: usage_date, consumed_count: 1, attempt_count: 3, extra_grants: 0)

      usage = described_class.grant_extra!(user_id: user.id, usage_date: usage_date)

      expect(usage.id).to eq(existing.id)
      expect(usage.reload).to have_attributes(extra_grants: 1, attempt_count: 0, consumed_count: 1)
      expect(DailyUsage.count).to eq(1)
    end

    it "繰り返すと、追加が積み上がる（試行は 0 のまま）" do
      3.times { described_class.grant_extra!(user_id: user.id, usage_date: usage_date) }

      expect(usage_of(user)).to have_attributes(extra_grants: 3, attempt_count: 0)
    end

    it "付与のあと、残りが 1 増える（利用枠を消費済みでも、もう 1 回）" do
      create(:daily_usage, user: user, usage_date: usage_date, consumed_count: 1)
      expect(described_class.remaining(user_id: user.id, usage_date: usage_date, settings: settings)).to eq(0)

      described_class.grant_extra!(user_id: user.id, usage_date: usage_date)

      expect(described_class.remaining(user_id: user.id, usage_date: usage_date, settings: settings)).to eq(1)
      expect(described_class.attempts_remaining(user_id: user.id, usage_date: usage_date, settings: settings)).to eq(3)
    end

    it "指定した利用日・アカウントだけを変える（別の利用日・別のアカウントの行に触れない）" do
      other = create(:user)
      other_date_usage = create(:daily_usage, user: user, usage_date: usage_date + 1, attempt_count: 2)
      other_user_usage = create(:daily_usage, user: other, usage_date: usage_date, attempt_count: 2)

      described_class.grant_extra!(user_id: user.id, usage_date: usage_date)

      expect(other_date_usage.reload).to have_attributes(extra_grants: 0, attempt_count: 2)
      expect(other_user_usage.reload).to have_attributes(extra_grants: 0, attempt_count: 2)
    end

    it "1 つの upsert 文で行う（アカウントと利用日の一意制約と競合しない。読んでから書く 2 段にしない）" do
      statements = capture_sql { described_class.grant_extra!(user_id: user.id, usage_date: usage_date) }
      writes = statements.grep(/\A(INSERT|UPDATE) /)

      expect(writes.size).to eq(1)
      expect(writes.first).to match(/\AINSERT INTO "daily_usages".*ON CONFLICT \("user_id",\s*"usage_date"\) DO UPDATE/m)
    end

    it "不正な引数は ArgumentError（行を作らない）" do
      expect { described_class.grant_extra!(user_id: nil, usage_date: usage_date) }.to raise_error(ArgumentError)
      expect { described_class.grant_extra!(user_id: user.id, usage_date: "2026-10-07") }.to raise_error(ArgumentError)
      expect(DailyUsage.count).to eq(0)
    end
  end
end
