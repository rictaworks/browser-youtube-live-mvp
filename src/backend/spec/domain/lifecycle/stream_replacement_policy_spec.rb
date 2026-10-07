require "spec_helper"
require_relative "../support/domain_loader"

# ストリームの取り替え（requirements.md 15 章「ストリームの取り替え」・10.5 の表・20.3）。
# StreamReplacementPolicy.discard?(trigger:)。保存している配信用ストリームの識別子を、いつ破棄するか。
# 破棄すると、次回の準備で新しいストリームを作成する。以前の配信が YouTube 上で終端に達していない状態で、
# 同じストリームへ送出すると、以前の配信へ映像が流れる。取り替えは、清算できない配信を、以後の配信から切り離す。
RSpec.describe "ストリームの取り替え（StreamReplacementPolicy）" do
  describe ".discard?（トリガーごとに、識別子を破棄するか）" do
    {
      youtube_connected: "YouTube 接続の成立（再接続を含む）。10.5 の表・7.2",
      settlement_abandoned: "配信が「清算不能」になった時点。10.5 の表・25.2",
      unsettled_identifier_erased: "未清算・清算不能の配信の YouTube 識別子を、保持期間により消去した時点。10.5 の表・20.3",
      stream_id_expired: "最後の確認から 30 日を過ぎた識別子の消去。20.3"
    }.each do |trigger, label|
      it "#{trigger}（#{label}）→ 破棄する" do
        expect(StreamReplacementPolicy.discard?(trigger: trigger)).to be(true)
      end
    end

    {
      broadcast_ended: "配信の終了（終了と同時に未清算になるが、取り替えない。次回の準備の最初の段で、清算を確認する）",
      settlement_succeeded: "清算済みになった",
      settlement_retry_failed: "清算の再試行に失敗した（まだ回数が尽きていない。未清算のまま）",
      settled_identifier_erased: "清算済みの配信の YouTube 識別子を、保持期間により消去した（未清算・清算不能ではない）",
      preparation_started: "準備の開始",
      stream_verified: "準備のたびの、ストリームの確認",
      broadcast_accepted: "受付の受理",
      live_confirmed: "ライブの確定",
      disconnected: "接続の解除（接続ごと、保存したストリームの識別子が消えるため、取り替えの対象ではない）",
      unknown_trigger: "表に無いトリガー"
    }.each do |trigger, label|
      it "#{trigger}（#{label}）→ 破棄しない" do
        expect(StreamReplacementPolicy.discard?(trigger: trigger)).to be(false)
      end
    end

    it "破棄するトリガーは、10.5 の表の 3 つと、20.3 の保持期間の 1 つだけ" do
      expect(StreamReplacementPolicy::DISCARD_TRIGGERS).to match_array(
        %i[youtube_connected settlement_abandoned unsettled_identifier_erased stream_id_expired]
      )
      expect(StreamReplacementPolicy::DISCARD_TRIGGERS).to be_frozen
    end

    it "トリガーの定数は、シンボルの値を持つ（呼び出し側が、定数で指定すれば、綴りの誤りが NameError になる）" do
      expect(StreamReplacementPolicy::YOUTUBE_CONNECTED).to eq(:youtube_connected)
      expect(StreamReplacementPolicy::SETTLEMENT_ABANDONED).to eq(:settlement_abandoned)
      expect(StreamReplacementPolicy::UNSETTLED_IDENTIFIER_ERASED).to eq(:unsettled_identifier_erased)
      expect(StreamReplacementPolicy::STREAM_ID_EXPIRED).to eq(:stream_id_expired)
    end

    [ "youtube_connected", nil, 1 ].each do |trigger|
      it "トリガーがシンボルでなければ（#{trigger.inspect}）、黙って false にせず ArgumentError" do
        expect { StreamReplacementPolicy.discard?(trigger: trigger) }
          .to raise_error(ArgumentError, "trigger must be a Symbol, got #{trigger.class}")
      end
    end

    it "同じ入力に、同じ出力を返す。インスタンスを作らない" do
      expect(StreamReplacementPolicy.discard?(trigger: :youtube_connected)).to eq(StreamReplacementPolicy.discard?(trigger: :youtube_connected))
      expect { StreamReplacementPolicy.new }.to raise_error(NoMethodError)
    end
  end
end
