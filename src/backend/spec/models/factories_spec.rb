require "rails_helper"
require "support/model_support"
require "support/expected_schema"

# ファクトリ（spec/factories）。後続の issue のスペックが使う。すべてのモデルにあり、有効なレコードを作ることを保証する。
RSpec.describe "ファクトリ" do
  it "15 テーブルのすべてのモデルに、ファクトリがある" do
    expected = ExpectedSchema::TABLES.keys.map { |table| table.singularize.to_sym }

    expect(FactoryBot.factories.map(&:name)).to match_array(expected)
  end

  FactoryBot.factories.map(&:name).sort.each do |name|
    describe name.to_s do
      it "build したレコードは有効で、create できる" do
        record = build(name)

        expect(record).to be_valid, record.errors.full_messages.join(", ")
        expect { record.save! }.not_to raise_error
        expect(record).to be_persisted
      end
    end
  end

  describe "broadcast のトレイト（状態ごとの、有効なレコード）" do
    %i[ provisioned awaiting_media confirming live interrupted ended ended_unsettled ].each do |trait|
      it ":#{trait} は、有効で、保存できる" do
        broadcast = create(:broadcast, trait)

        expect(broadcast).to be_persisted
      end
    end

    it "状態のトレイトは、状態の符号と一致する" do
      expect(create(:broadcast, :awaiting_media).state).to eq("awaiting_media")
      expect(create(:broadcast, :confirming).state).to eq("confirming")
      expect(create(:broadcast, :live).state).to eq("live")
      expect(create(:broadcast, :interrupted).state).to eq("interrupted")
      expect(create(:broadcast, :ended).state).to eq("ended")
    end

    it "YouTube の資源を持つトレイトは、タイトルを持たない（識別子の保存と同時に消える）" do
      expect(create(:broadcast, :awaiting_media).pending_title).to be_nil
      expect(create(:broadcast, :ended_unsettled)).to have_attributes(pending_title: nil, settlement_state: "pending")
    end

    it "既定は、受理直後（reserved）で、タイトルを持つ" do
      expect(create(:broadcast)).to have_attributes(state: "reserved", pending_title: "dummy-title", prep_reserved_units: 340, settle_reserved_units: 210)
    end
  end

  describe "他のトレイト" do
    it "youtube_connection: live_not_enabled・revoked・with_stream" do
      expect(create(:youtube_connection, :live_not_enabled).state).to eq("live_not_enabled")
      expect(create(:youtube_connection, :revoked).state).to eq("revoked")
      expect(create(:youtube_connection, :with_stream)).to have_attributes(youtube_stream_id: be_present, stream_verified_at: be_present)
    end

    it "relay_ticket: used は、使用済み" do
      expect(create(:relay_ticket, :used).used_at).not_to be_nil
    end

    it "usage_event: detached は、アカウントとの紐づけが無い" do
      expect(create(:usage_event, :detached).user_id).to be_nil
    end
  end

  it "ファクトリのダミー値は、明らかなダミー（dummy- で始まる）で、本物らしい値を含まない" do
    expect(create(:user).google_sub).to start_with("dummy-")
    expect(create(:session).token_digest).to start_with("dummy-")
    expect(create(:youtube_connection).refresh_token_ciphertext).to start_with("dummy-")
    expect(create(:relay_ticket).token_digest).to start_with("dummy-")
    expect(create(:deletion_hold).sub_digest).to start_with("dummy-")
    expect(create(:broadcast).pending_title).to start_with("dummy-")
  end
end
