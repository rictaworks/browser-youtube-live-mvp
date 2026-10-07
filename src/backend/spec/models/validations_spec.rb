require "rails_helper"
require "support/model_support"

# 各モデルの検証（必須・列挙・非負・形）。DB の制約（spec/models/schema/）と二重に守る。
# 一意性の検証は置かない（一意制約の違反は、DB が RecordNotUnique で拒否する。部分一意の違反を、検証の失敗に変えない）。
# モデルは業務の判定を持たない。ここにあるのは、列の値が、DB に保存できる形であることの検証だけ。
RSpec.describe "モデルの検証" do
  describe "必須の項目（NOT NULL で既定値の無い列・必須の関連）" do
    # ファクトリ => [ 空にする項目 ]。関連（user・broadcast など）は、belongs_to の必須の検証（kind :required）、列は :blank
    required = {
      user: %i[ google_sub last_login_at ],
      session: %i[ user token_digest last_used_at expires_at ],
      youtube_connection: %i[ user state refresh_token_ciphertext connected_at last_verified_at ],
      broadcast: %i[ user daily_usage state settlement_state usage_date quota_date privacy_status accepted_at ],
      daily_usage: %i[ user usage_date ],
      relay_ticket: %i[ user broadcast token_digest epoch expires_at ],
      health_sample: %i[ user broadcast sampled_at ],
      broadcast_event: %i[ user broadcast occurred_at event_type ],
      usage_event: %i[ occurred_at event_type ],
      quota_day: %i[ quota_date ],
      quota_entry: %i[ quota_day method units result bucket called_at ],
      transfer_month: %i[ month ],
      deletion_hold: %i[ sub_digest hold_usage_date ],
      system_setting: %i[ key value ],
      admin_action: %i[ action occurred_at ]
    }

    required.each do |factory, attributes|
      attributes.each do |attribute|
        it "#{factory}: #{attribute} が空なら、検証に失敗する" do
          # broadcast の usage_date・quota_date は、daily_usage から導く。daily_usage を空にするときは、日付を明示する
          overrides = { attribute => nil }
          overrides.merge!(usage_date: Date.new(2026, 10, 7)) if factory == :broadcast && attribute == :daily_usage
          record = build(factory, **overrides)

          expect(record).not_to be_valid
          expect(record.errors[attribute]).to be_present
        end
      end
    end

    it "既定のファクトリのレコードは、すべて検証を通る（上の失敗が、空の項目だけに起因することの確認）" do
      required.each_key { |factory| expect(build(factory)).to be_valid, "#{factory} の既定のファクトリが無効" }
    end

    it "broadcast の made_for_kids は、true・false のどちらかを明示する（初回は未選択。利用者の明示的な選択を必須とする。9.1）" do
      expect(build(:broadcast, made_for_kids: nil)).not_to be_valid
      expect(build(:broadcast, made_for_kids: true)).to be_valid
      expect(build(:broadcast, made_for_kids: false)).to be_valid
    end

    it "usage_event は、アカウントが無くても有効（アカウントの削除時に、紐づけを外すため）" do
      expect(build(:usage_event, :detached)).to be_valid
    end

    it "quota_entry は、配信が無くても有効（配信に属さない呼び出し・アカウントの削除後）" do
      expect(build(:quota_entry, broadcast: nil)).to be_valid
    end
  end

  describe "列挙の符号" do
    # [ ファクトリ, 項目, 有効な符号の一覧, NULL を許すか ]
    enumerations = [
      [ :broadcast, :state, -> { Contract::BroadcastState::ALL }, false ],
      [ :broadcast, :end_reason, -> { Contract::EndReason::ALL }, true ],
      [ :broadcast, :settlement_state, -> { Contract::SettlementState::ALL }, false ],
      [ :broadcast, :profile, -> { Contract::Profile::ALL }, true ],
      [ :broadcast, :privacy_status, -> { Broadcast::PRIVACY_STATUSES }, false ],
      [ :youtube_connection, :state, -> { YoutubeConnection::STORED_STATES }, false ],
      [ :broadcast_event, :event_type, -> { Contract::BroadcastEventType::ALL }, false ],
      [ :usage_event, :event_type, -> { Contract::UsageEventType::ALL }, false ],
      [ :quota_entry, :bucket, -> { QuotaEntry::BUCKETS }, false ],
      [ :quota_entry, :result, -> { QuotaEntry::RESULTS }, false ],
      [ :system_setting, :key, -> { Contract::SettingKey::ALL }, false ]
    ]

    enumerations.each do |factory, attribute, values, nullable|
      it "#{factory}.#{attribute}: 符号をすべて受け付け、符号でない値を拒否する（NULL は#{nullable ? '許す' : '許さない'}）" do
        codes = instance_exec(&values)

        aggregate_failures do
          codes.each { |code| expect(build(factory, attribute => code)).to be_valid, "#{attribute}=#{code} が無効" }

          [ "unknown", codes.first.upcase, "#{codes.first} ", " #{codes.first}", "" ].each do |invalid|
            record = build(factory, attribute => invalid)
            expect(record).not_to be_valid, "#{attribute}=#{invalid.inspect} が有効"
            expect(record.errors[attribute]).to be_present
          end

          nil_record = build(factory, attribute => nil)
          if nullable
            expect(nil_record).to be_valid
          else
            expect(nil_record).not_to be_valid
            expect(nil_record.errors[attribute]).to be_present
          end
        end
      end
    end

    it "列挙の符号の定数は、契約の定数モジュール（Contract::…）と同じもの（モデルは、符号を独自に持たない）" do
      expect(YoutubeConnection::STORED_STATES).to eq(Contract::YoutubeConnectionState::ALL - [ Contract::YoutubeConnectionState::NOT_CONNECTED ])
      expect(Broadcast::PRIVACY_STATUSES).to eq(ContractEnums.privacy_statuses)
    end
  end

  describe "非負の整数（件数・量の列）" do
    # ファクトリ => [ 列 ]
    non_negative = {
      daily_usage: %i[ consumed_count attempt_count extra_grants ],
      broadcast: %i[ settlement_attempts prep_reserved_units settle_reserved_units resume_count sent_bytes publisher_epoch ],
      relay_ticket: %i[ epoch ],
      quota_day: %i[ used_units reserved_units common_used_units ],
      quota_entry: %i[ units ],
      transfer_month: %i[ sent_bytes ]
    }

    non_negative.each do |factory, columns|
      columns.each do |column|
        it "#{factory}.#{column}: 負の値・小数・数でない値を拒否し、0 と正の整数を受け付ける" do
          aggregate_failures do
            [ -1, 1.5, "abc" ].each do |invalid|
              record = build(factory, column => invalid)
              expect(record).not_to be_valid, "#{column}=#{invalid.inspect} が有効"
              expect(record.errors[column]).to be_present
            end
            [ 0, 1, 550 ].each { |valid| expect(build(factory, column => valid)).to be_valid, "#{column}=#{valid} が無効" }
          end
        end
      end
    end

    it "bigint の列（sent_bytes）は、2 の 31 乗を超える値を、受け付ける" do
      expect(build(:broadcast, sent_bytes: 5 * 1024**3)).to be_valid
      expect(build(:transfer_month, sent_bytes: 10 * 1024**3)).to be_valid
    end
  end

  describe "transfer_months.month の形（YYYY-MM）" do
    %w[ 2026-10 2026-01 2026-12 ].each do |month|
      it "#{month} は有効" do
        expect(build(:transfer_month, month: month)).to be_valid
      end
    end

    [ "2026-1", "2026-13", "2026-00", "202610", "2026/10", "2026-10 ", "" ].each do |month|
      it "#{month.inspect} は無効" do
        record = build(:transfer_month, month: month)

        expect(record).not_to be_valid
        expect(record.errors[:month]).to be_present
      end
    end
  end

  describe "一意性の検証を置かない" do
    it "同じ google_sub・要約値・キーの 2 件目は、検証を通り、保存で DB が RecordNotUnique にする（部分一意の違反を、検証の失敗に変えない）" do
      create(:user, google_sub: "dummy-sub-dup")
      duplicate = build(:user, google_sub: "dummy-sub-dup")
      user = create(:user)
      create(:broadcast, user: user)
      second = build(:broadcast, user: user)

      expect(duplicate).to be_valid
      expect(second).to be_valid
      expect_db_violation(ActiveRecord::RecordNotUnique) { duplicate.save! }
      expect_db_violation(ActiveRecord::RecordNotUnique) { second.save! }
    end
  end
end
