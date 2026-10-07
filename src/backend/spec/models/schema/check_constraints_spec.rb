require "rails_helper"
require "support/model_support"

# requirements.md 20.2・20.4・21 章。CHECK 制約と NOT NULL 制約の検査。
#   1. 列挙の CHECK 制約の符号が、契約（src/contracts/enums.json）と一致する（カタログを読んで、集合として比べる）
#   2. 契約の符号を、DB がすべて受け付け、符号でない値を拒否する（実際に保存して確かめる）
#   3. 件数・量の列が負にならない。月の文字列の形。タイトルの寿命（保存したら、識別子の保存か終了で消える）
#   4. NOT NULL
# 検証（validates）を通さずに保存する（モデルの検証が先に拒否して、DB の制約を検査し損ねないため）。
RSpec.describe "CHECK 制約・NOT NULL 制約（requirements.md 20.2・20.4・21 章）" do
  # 列挙の列。origin は、符号の出どころ。values は、符号の一覧（契約を、例の実行時に読む）。build は、その列に値を入れたレコード。
  enumerated_columns = [
    { table: "broadcasts", column: "state", nullable: false, origin: "契約の列挙 broadcast_state（20.4・25.1）",
      values: -> { ContractEnums.values("broadcast_state") }, build: ->(value) { build(:broadcast, state: value) } },
    { table: "broadcasts", column: "end_reason", nullable: true, origin: "契約の列挙 end_reason（20.4）",
      values: -> { ContractEnums.values("end_reason") }, build: ->(value) { build(:broadcast, end_reason: value) } },
    { table: "broadcasts", column: "settlement_state", nullable: false, origin: "契約の列挙 settlement_state（20.4・25.2）",
      values: -> { ContractEnums.values("settlement_state") }, build: ->(value) { build(:broadcast, settlement_state: value) } },
    { table: "broadcasts", column: "profile", nullable: true, origin: "契約の列挙 profile（20.4・11.7）",
      values: -> { ContractEnums.values("profile") }, build: ->(value) { build(:broadcast, profile: value) } },
    { table: "broadcasts", column: "privacy_status", nullable: false, origin: "契約 http-api.md の privacy_status（公開・限定公開・非公開）",
      values: -> { ContractEnums.privacy_statuses }, build: ->(value) { build(:broadcast, privacy_status: value) } },
    { table: "youtube_connections", column: "state", nullable: false,
      origin: "契約の列挙 youtube_connection_state から、not_connected を除いたもの（行が無い場合は未接続。21 章の ER 図・25.4）",
      values: -> { ContractEnums.values("youtube_connection_state") - [ "not_connected" ] }, build: ->(value) { build(:youtube_connection, state: value) } },
    { table: "broadcast_events", column: "event_type", nullable: false, origin: "契約の列挙 broadcast_event_type（20.4）",
      values: -> { ContractEnums.values("broadcast_event_type") }, build: ->(value) { build(:broadcast_event, event_type: value) } },
    { table: "usage_events", column: "event_type", nullable: false, origin: "契約の列挙 usage_event_type（20.4・18 章）",
      values: -> { ContractEnums.values("usage_event_type") }, build: ->(value) { build(:usage_event, event_type: value) } },
    { table: "quota_entries", column: "bucket", nullable: false, origin: "21 章の ER 図（prep / settle / common）",
      values: -> { %w[ prep settle common ] }, build: ->(value) { build(:quota_entry, bucket: value) } },
    { table: "quota_entries", column: "result", nullable: false, origin: "21 章の ER 図（ok / error の符号）",
      values: -> { %w[ ok error ] }, build: ->(value) { build(:quota_entry, result: value) } }
  ]

  describe "列挙の列の CHECK 制約" do
    enumerated_columns.each do |entry|
      table = entry.fetch(:table)
      column = entry.fetch(:column)

      describe "#{table}.#{column}" do
        it "CHECK 制約 chk_#{table}_#{column} の符号は、#{entry.fetch(:origin)} と一致する" do
          expect(SchemaInspector.check_literals(table, "chk_#{table}_#{column}")).to match_array(entry.fetch(:values).call)
        end

        it "符号をすべて受け付ける" do
          aggregate_failures do
            entry.fetch(:values).call.each do |value|
              expect_db_accepts { save_without_validation!(instance_exec(value, &entry.fetch(:build))) }
            end
          end
        end

        it "符号でない値（空・未知・大文字・前後の空白）を拒否する" do
          sample = entry.fetch(:values).call.first
          invalid = [ "", " ", "unknown", sample.upcase, "#{sample} ", " #{sample}", "#{sample}_" ]

          aggregate_failures do
            invalid.each do |value|
              expect_db_violation(ActiveRecord::CheckViolation) { save_without_validation!(instance_exec(value, &entry.fetch(:build))) }
            end
          end
        end

        if entry.fetch(:nullable)
          it "NULL を受け付ける（NULL 可の列）" do
            expect_db_accepts { save_without_validation!(instance_exec(nil, &entry.fetch(:build))) }
          end
        else
          it "NULL を拒否する（NOT NULL の列）" do
            expect_db_violation(ActiveRecord::NotNullViolation) { save_without_validation!(instance_exec(nil, &entry.fetch(:build))) }
          end
        end
      end
    end

    it "youtube_connections.state は、not_connected を保存しない（行が無い場合が、未接続。21 章の ER 図）" do
      expect_db_violation(ActiveRecord::CheckViolation) { save_without_validation!(build(:youtube_connection, state: "not_connected")) }
    end

    it "列挙の CHECK 制約は、10 列（契約の列挙 8 列と、台帳の 2 列）" do
      expect(enumerated_columns.size).to eq(10)
    end
  end

  describe "件数・量の列は、負にならない" do
    non_negative = {
      "daily_usages" => { columns: %w[ consumed_count attempt_count extra_grants ], build: ->(attrs) { build(:daily_usage, **attrs) } },
      "broadcasts" => {
        columns: %w[ settlement_attempts prep_reserved_units settle_reserved_units resume_count sent_bytes publisher_epoch ],
        build: ->(attrs) { build(:broadcast, **attrs) }
      },
      "relay_tickets" => { columns: %w[ epoch ], build: ->(attrs) { build(:relay_ticket, **attrs) } },
      "quota_days" => { columns: %w[ used_units reserved_units common_used_units ], build: ->(attrs) { build(:quota_day, **attrs) } },
      "quota_entries" => { columns: %w[ units ], build: ->(attrs) { build(:quota_entry, **attrs) } },
      "transfer_months" => { columns: %w[ sent_bytes ], build: ->(attrs) { build(:transfer_month, **attrs) } }
    }

    non_negative.each do |table, definition|
      definition.fetch(:columns).each do |column|
        it "#{table}.#{column}: 負の値を拒否し、0 と正の値を受け付ける" do
          builder = definition.fetch(:build)

          expect_db_violation(ActiveRecord::CheckViolation) { save_without_validation!(instance_exec({ column.to_sym => -1 }, &builder)) }
          expect_db_accepts { save_without_validation!(instance_exec({ column.to_sym => 0 }, &builder)) }
          expect_db_accepts { save_without_validation!(instance_exec({ column.to_sym => 550 }, &builder)) }
        end
      end
    end

    it "予約中（quota_days.reserved_units）が負にならない（20.2・8.4）。使用済みも同じ" do
      day = create(:quota_day, used_units: 100, reserved_units: 550)

      expect_db_violation(ActiveRecord::CheckViolation) { day.update_columns(reserved_units: -1) }
      expect_db_violation(ActiveRecord::CheckViolation) { day.update_columns(used_units: -1) }
      expect_db_accepts { day.update_columns(reserved_units: 0) }
    end

    it "bigint の列（sent_bytes）は、2 の 31 乗を超える値も保持できる" do
      broadcast = create(:broadcast, sent_bytes: 5 * 1024**3)
      month = create(:transfer_month, sent_bytes: 10 * 1024**3)

      expect(broadcast.reload.sent_bytes).to eq(5 * 1024**3)
      expect(month.reload.sent_bytes).to eq(10 * 1024**3)
    end
  end

  describe "transfer_months.month は、YYYY-MM の形（暦月の文字列）" do
    %w[ 2026-10 2026-01 2026-12 1999-09 ].each do |month|
      it "#{month} を受け付ける" do
        expect_db_accepts { save_without_validation!(build(:transfer_month, month: month)) }
      end
    end

    [ "2026-1", "2026-13", "2026-00", "202610", "2026/10", "26-10", "2026-10 ", " 2026-10", "2026-100", "", "year-mo" ].each do |month|
      it "#{month.inspect} を拒否する" do
        expect_db_violation(ActiveRecord::CheckViolation) { save_without_validation!(build(:transfer_month, month: month)) }
      end
    end
  end

  describe "broadcasts.pending_title の寿命（10.1・20.3・28.2。タイトルは、YouTube の配信識別子の保存時、または終了時の、早い方で消す）" do
    it "識別子を保存する前の、終了していない配信は、タイトルを持てる" do
      expect_db_accepts { save_without_validation!(build(:broadcast, state: "reserved", pending_title: "dummy-title")) }
    end

    it "YouTube の配信識別子を持つ配信は、タイトルを持てない" do
      broadcast = create(:broadcast, pending_title: "dummy-title")

      expect_db_violation(ActiveRecord::CheckViolation) { broadcast.update_columns(youtube_broadcast_id: "dummy-youtube-broadcast") }
    end

    it "終了した配信は、タイトルを持てない" do
      broadcast = create(:broadcast, pending_title: "dummy-title")

      expect_db_violation(ActiveRecord::CheckViolation) { broadcast.update_columns(state: "ended") }
    end

    it "タイトルを消すのと同じ更新なら、識別子を保存でき、終了もできる" do
      saved = create(:broadcast, pending_title: "dummy-title")
      finished = create(:broadcast, pending_title: "dummy-title")

      expect_db_accepts { saved.update_columns(youtube_broadcast_id: "dummy-youtube-broadcast", pending_title: nil) }
      expect_db_accepts { finished.update_columns(state: "ended", end_reason: "user_stop", ended_at: Time.current, pending_title: nil) }
    end

    it "識別子の保存後・終了後に、タイトルを書き戻す更新を拒否する" do
      broadcast = create(:broadcast, :ended)

      expect_db_violation(ActiveRecord::CheckViolation) { broadcast.update_columns(pending_title: "dummy-title") }
    end
  end

  describe "NOT NULL" do
    # [ ファクトリ, NULL を入れる列 ]。主キー・既定値のある列・Rails が自動で入れる時刻（created_at・updated_at）は除く
    not_null_columns = [
      [ :user, :google_sub ], [ :user, :last_login_at ],
      [ :session, :token_digest ], [ :session, :last_used_at ], [ :session, :expires_at ],
      [ :youtube_connection, :state ], [ :youtube_connection, :refresh_token_ciphertext ],
      [ :youtube_connection, :connected_at ], [ :youtube_connection, :last_verified_at ],
      [ :broadcast, :state ], [ :broadcast, :settlement_state ], [ :broadcast, :usage_date ], [ :broadcast, :privacy_status ],
      [ :broadcast, :made_for_kids ], [ :broadcast, :accepted_at ], [ :broadcast, :bound ], [ :broadcast, :attempt_counted ],
      [ :broadcast, :allowance_consumed ], [ :broadcast, :sent_bytes ], [ :broadcast, :publisher_epoch ],
      [ :daily_usage, :usage_date ], [ :daily_usage, :consumed_count ], [ :daily_usage, :attempt_count ], [ :daily_usage, :extra_grants ],
      [ :relay_ticket, :token_digest ], [ :relay_ticket, :epoch ], [ :relay_ticket, :expires_at ],
      [ :health_sample, :sampled_at ],
      [ :broadcast_event, :occurred_at ], [ :broadcast_event, :event_type ],
      [ :usage_event, :occurred_at ], [ :usage_event, :event_type ],
      [ :quota_day, :used_units ], [ :quota_day, :reserved_units ], [ :quota_day, :common_used_units ], [ :quota_day, :exhausted ],
      [ :quota_entry, :method ], [ :quota_entry, :units ], [ :quota_entry, :result ], [ :quota_entry, :bucket ], [ :quota_entry, :called_at ],
      [ :transfer_month, :sent_bytes ],
      [ :deletion_hold, :hold_usage_date ],
      [ :system_setting, :value ],
      [ :admin_action, :action ], [ :admin_action, :occurred_at ]
    ]

    not_null_columns.each do |factory, column|
      it "#{factory}.#{column} が NULL の行を拒否する" do
        expect_db_violation(ActiveRecord::NotNullViolation) { save_without_validation!(build(factory, column => nil)) }
      end
    end

    it "NULL 可の列は、NULL のまま保存できる（利用者に属するテーブルの user_id では、usage_events だけ）" do
      expect_db_accepts { save_without_validation!(build(:usage_event, :detached)) }
      expect_db_accepts { save_without_validation!(build(:quota_entry, broadcast: nil)) }
    end
  end
end
