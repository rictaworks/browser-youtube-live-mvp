require "rails_helper"
require "support/model_support"
require "support/log_capture"

# YouTube 接続の状態の遷移（requirements.md 25.4・10.5・7.3。issue #10）。
#   mark_connected!         ライブ未有効 -> 接続済み（再確認でライブ有効）、認可失効 -> 接続済み（再接続・ライブ有効）
#   mark_live_not_enabled!  接続済み -> ライブ未有効（準備時にライブ未有効・制限中）、認可失効 -> ライブ未有効（再接続・ライブ未有効）
#   mark_revoked!           接続済み・ライブ未有効 -> 認可失効（トークンの更新が恒久的に失敗・権限の不足）
#   discard_stream!         配信用ストリームの識別子の破棄（ストリームの取り替え。10.5）
# 25.4 の矢印は、3 つの状態のあいだの 6 通りのすべて。同じ状態への遷移は、何も変えない（false）。
# 行が無い場合が「未接続」。行の作成（接続の成立）・削除（接続の解除）は、このモデルのメソッドではない。
# 遷移は、1 つの UPDATE 文（アカウントで絞り込み、遷移先と異なるときだけ更新）。古いメモリ上の値で、他の更新を上書きしない。
RSpec.describe YoutubeConnection do
  include LogCapture

  let(:user) { create(:user) }
  let(:connection) { create(:youtube_connection, user: user) }

  def stored_state(record)
    described_class.find(record.id).state
  end

  # 25.4 の矢印（遷移元, メソッド, 遷移先）。6 通りのすべて
  transitions = [
    %w[ connected mark_live_not_enabled! live_not_enabled ],
    %w[ connected mark_revoked! revoked ],
    %w[ live_not_enabled mark_connected! connected ],
    %w[ live_not_enabled mark_revoked! revoked ],
    %w[ revoked mark_connected! connected ],
    %w[ revoked mark_live_not_enabled! live_not_enabled ]
  ]

  describe "状態の遷移（25.4 の矢印）" do
    transitions.each do |from, method_name, to|
      it "#{from} -> #{to}（#{method_name}）: true を返し、DB とメモリ上の状態が変わる。メモリ上の値は、変更済みの印が付かない" do
        record = create(:youtube_connection, user: create(:user), state: from)

        expect(record.public_send(method_name)).to be(true)

        expect(stored_state(record)).to eq(to)
        expect(record.state).to eq(to)
        expect(record).not_to be_changed
      end
    end

    %w[ connected live_not_enabled revoked ].zip(%w[ mark_connected! mark_live_not_enabled! mark_revoked! ]).each do |state, method_name|
      it "#{state} への #{method_name} は、すでにその状態なので何も変えない（false）" do
        record = create(:youtube_connection, user: create(:user), state: state)

        expect(record.public_send(method_name)).to be(false)

        expect(stored_state(record)).to eq(state)
      end
    end

    it "遷移の矢印は 25.4 の 6 通りのすべてで、状態は 3 つ（未接続は行が無いこと）" do
      expect(transitions.size).to eq(6)
      expect(transitions.flat_map { |from, _, to| [ from, to ] }.uniq).to match_array(described_class::STORED_STATES)
      expect(transitions.map { |from, _, to| [ from, to ] }.uniq.size).to eq(6)
    end

    it "遷移は、状態以外の列（暗号化した更新トークン・ストリームの識別子・確認の時刻・接続の時刻）を変えない" do
      record = create(:youtube_connection, :with_stream, user: user, state: "connected")
      before = described_class.find(record.id).attributes.except("state")

      record.mark_revoked!

      expect(described_class.find(record.id).attributes.except("state")).to eq(before)
    end

    it "1 つの UPDATE 文で行う（読んでから書く、の 2 段にしない。古いメモリ上の値で、他の更新を上書きしない）" do
      record = create(:youtube_connection, user: user, state: "connected")

      statements = capture_sql { record.mark_revoked! }

      updates = statements.grep(/\AUPDATE/i)
      expect(updates.size).to eq(1)
      expect(statements.grep(/\ASELECT/i)).to be_empty
    end

    it "メモリ上の値が古くても（DB は、すでに別の状態）、DB の現在の状態を基準に判定する: すでに遷移先なら false" do
      stale = described_class.find(connection.id)
      described_class.find(connection.id).mark_revoked!

      expect(stale.mark_revoked!).to be(false)
      expect(stored_state(connection)).to eq("revoked")
    end

    it "メモリ上の値が古くて（connected）、DB は ライブ未有効 のとき、mark_revoked! は DB を revoked にする" do
      stale = described_class.find(connection.id)
      described_class.find(connection.id).mark_live_not_enabled!

      expect(stale.mark_revoked!).to be(true)
      expect(stored_state(connection)).to eq("revoked")
    end

    it "他のアカウントの接続は、変えない" do
      other = create(:youtube_connection, user: create(:user), state: "connected")

      connection.mark_revoked!

      expect(stored_state(other)).to eq("connected")
    end

    it "保存されていない接続は ArgumentError（黙って成功にしない）" do
      record = build(:youtube_connection, user: user)

      expect { record.mark_revoked! }.to raise_error(ArgumentError, /persisted/)
      expect { record.discard_stream! }.to raise_error(ArgumentError, /persisted/)
    end

    it "行が消えた（接続の解除と競合した）あとの遷移は、false（行を作り直さない）" do
      record = create(:youtube_connection, user: user)
      described_class.where(id: record.id).delete_all

      expect(record.mark_revoked!).to be(false)
      expect(described_class.where(id: record.id)).to be_empty
    end

    it "遷移をログに残す（アカウントの内部の識別子と遷移先だけ。トークンの暗号文を含めない）" do
      record = create(:youtube_connection, user: user, refresh_token_ciphertext: "dummy-ciphertext-must-not-appear")

      output = capture_logs { record.mark_revoked! }

      expect(output).to include("youtube_connection state changed user_id=#{user.id} to=revoked")
      expect(output).not_to include("dummy-ciphertext-must-not-appear")
    end

    it "遷移しなかったときは、ログに残さない" do
      record = create(:youtube_connection, user: user, state: "revoked")

      output = capture_logs { record.mark_revoked! }

      expect(output).not_to include("youtube_connection state changed")
    end
  end

  describe "#discard_stream!（ストリームの取り替え。10.5）" do
    it "配信用ストリームの識別子と、最終確認の時刻を破棄する。true を返す" do
      record = create(:youtube_connection, :with_stream, user: user)

      expect(record.discard_stream!).to be(true)

      stored = described_class.find(record.id)
      expect(stored.youtube_stream_id).to be_nil
      expect(stored.stream_verified_at).to be_nil
      expect(record.youtube_stream_id).to be_nil
      expect(record).not_to be_changed
    end

    it "識別子が無ければ、何も変えない（false。冪等）" do
      record = create(:youtube_connection, user: user)

      expect(record.discard_stream!).to be(false)
      expect(record.discard_stream!).to be(false)
    end

    it "状態・暗号化した更新トークン・接続の時刻は変えない" do
      record = create(:youtube_connection, :with_stream, user: user, state: "live_not_enabled")
      before = described_class.find(record.id).attributes.slice("state", "refresh_token_ciphertext", "connected_at", "last_verified_at")

      record.discard_stream!

      expect(described_class.find(record.id).attributes.slice("state", "refresh_token_ciphertext", "connected_at", "last_verified_at")).to eq(before)
    end

    it "1 つの UPDATE 文で、2 つの列を同時に更新する" do
      record = create(:youtube_connection, :with_stream, user: user)

      statements = capture_sql { record.discard_stream! }

      updates = statements.grep(/\AUPDATE/i)
      expect(updates.size).to eq(1)
      expect(updates.first).to include("youtube_stream_id").and include("stream_verified_at")
    end

    it "他のアカウントのストリームの識別子は、破棄しない" do
      other = create(:youtube_connection, :with_stream, user: create(:user))
      record = create(:youtube_connection, :with_stream, user: user)

      record.discard_stream!

      expect(described_class.find(other.id).youtube_stream_id).to be_present
    end
  end
end
