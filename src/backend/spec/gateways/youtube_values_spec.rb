require "rails_helper"
require "pp"

# 窓口が返す値（issue #10）。StreamInfo（取り込み先と配信キー）・StreamHealth（ストリームの健全性）・ProbeResult（接続時の確認の結果）・
# UnstartedBroadcast（応答喪失時の引き継ぎ用の、未開始の配信）。
# 秘密（配信キー・チャンネル名・タイトル）を持つものは、inspect・to_s・pretty_inspect に出さない（ログ・例外に紛れ込まないように）。
RSpec.describe "YouTube の窓口が返す値" do
  describe StreamInfo do
    let(:info) do
      described_class.new(stream_id: "dummy-stream-id-0001", ingest_url: "rtmps://a.rtmps.youtube.com:443/live2", stream_key: "dummy-stream-key-must-not-appear", created: true)
    end

    it "ストリームの識別子・取り込み先・配信キー・今回作成したかを持つ" do
      expect(info).to have_attributes(
        stream_id: "dummy-stream-id-0001", ingest_url: "rtmps://a.rtmps.youtube.com:443/live2", stream_key: "dummy-stream-key-must-not-appear", created: true
      )
      expect(info).to be_created
    end

    it "inspect・to_s・pretty_inspect に、配信キーを出さない（識別子と取り込み先は出す）" do
      [ info.inspect, info.to_s, info.pretty_inspect ].each do |text|
        expect(text).not_to include("dummy-stream-key-must-not-appear")
        expect(text).to include("FILTERED")
        expect(text).to include("dummy-stream-id-0001")
      end
    end

    it "凍結されている。配信キーは複製して凍結する（呼び出し側の文字列の変更が、値に及ばない）" do
      key = +"dummy-stream-key"
      value = described_class.new(stream_id: "s", ingest_url: "rtmps://a.rtmps.youtube.com:443/live2", stream_key: key, created: false)
      key << "-mutated"

      expect(value).to be_frozen
      expect(value.stream_key).to eq("dummy-stream-key")
      expect(value.stream_key).to be_frozen
      expect(value).not_to be_created
    end

    it "to_h を持たない（ハッシュにして、ログへ流す経路を作らない）" do
      expect(info).not_to respond_to(:to_h)
    end

    it "引数の検査: 識別子・取り込み先・配信キーは空でない文字列、created は真偽値" do
      valid = { stream_id: "s", ingest_url: "rtmps://a.rtmps.youtube.com:443/live2", stream_key: "k", created: true }

      [ :stream_id, :ingest_url, :stream_key ].each do |name|
        expect { described_class.new(**valid, name => "") }.to raise_error(ArgumentError, /#{name}/)
        expect { described_class.new(**valid, name => nil) }.to raise_error(ArgumentError, /#{name}/)
      end
      expect { described_class.new(**valid, created: "yes") }.to raise_error(ArgumentError, /created/)
    end
  end

  describe StreamHealth do
    # [healthStatus.status, error の configurationIssues の reason, 警告か]
    [
      [ "good", [], false ],
      [ "ok", [], false ],
      [ "bad", [], true ],
      [ "noData", [], false ],
      [ "good", [ "gopSizeLong" ], true ],
      [ "ok", [ "bitrateLow", "audioBitrateLow" ], true ],
      [ "noData", [ "videoCodec" ], true ],
      [ "bad", [ "gopSizeLong" ], true ]
    ].each do |status, reasons, warning|
      it "状態 #{status}・エラーの設定の問題 #{reasons.inspect} -> 警告 #{warning}（bad または severity: error のときだけ。noData は情報が無いだけ）" do
        health = described_class.new(status: status, error_types: reasons)

        expect(health.warning?).to be(warning)
        expect(health.status).to eq(status)
        expect(health.error_types).to eq(reasons)
      end
    end

    it "未知の状態は ArgumentError（黙って good にしない）。符号の形でない reason は unrecognized に置き換える" do
      expect { described_class.new(status: "great", error_types: []) }.to raise_error(ArgumentError, /status/)
      expect { described_class.new(status: nil, error_types: []) }.to raise_error(ArgumentError, /status/)
      expect { described_class.new(status: "good", error_types: "x") }.to raise_error(ArgumentError, /error_types/)
      expect(described_class.new(status: "good", error_types: [ "has space", 1 ]).error_types).to eq([ "unrecognized", "unrecognized" ])
    end

    it "凍結されている" do
      health = described_class.new(status: "bad", error_types: [ "gopSizeLong" ])

      expect(health).to be_frozen
      expect(health.error_types).to be_frozen
    end
  end

  describe ProbeResult do
    it "結果は契約の connect_result のうち、connected・live_not_enabled・no_channel" do
      expect(described_class::OUTCOMES).to eq([ Contract::ConnectResult::CONNECTED, Contract::ConnectResult::LIVE_NOT_ENABLED, Contract::ConnectResult::NO_CHANNEL ])
    end

    it "チャンネルがあるとき（connected・live_not_enabled）は、チャンネル名を持つ。チャンネルが無いとき（no_channel）は持たない" do
      connected = described_class.new(outcome: "connected", channel_title: "dummy-channel-title")
      not_enabled = described_class.new(outcome: "live_not_enabled", channel_title: "dummy-channel-title")
      no_channel = described_class.new(outcome: "no_channel", channel_title: nil)

      expect([ connected.channel_title, not_enabled.channel_title, no_channel.channel_title ]).to eq([ "dummy-channel-title", "dummy-channel-title", nil ])
      expect([ connected.connected?, not_enabled.live_not_enabled?, no_channel.no_channel? ]).to all(be(true))
      expect([ connected.live_not_enabled?, connected.no_channel?, no_channel.connected? ]).to all(be(false))
    end

    it "チャンネルが無いのにチャンネル名がある・チャンネルがあるのに名前が無い、は ArgumentError" do
      expect { described_class.new(outcome: "no_channel", channel_title: "x") }.to raise_error(ArgumentError, /channel_title/)
      expect { described_class.new(outcome: "connected", channel_title: nil) }.to raise_error(ArgumentError, /channel_title/)
      expect { described_class.new(outcome: "unverifiable", channel_title: nil) }.to raise_error(ArgumentError, /outcome/)
      expect { described_class.new(outcome: :connected, channel_title: "x") }.to raise_error(ArgumentError, /outcome/)
    end

    it "チャンネル名（永続化しない）を、inspect・to_s・pretty_inspect に出さない" do
      result = described_class.new(outcome: "connected", channel_title: "dummy-channel-title-must-not-appear")

      [ result.inspect, result.to_s, result.pretty_inspect ].each do |text|
        expect(text).not_to include("dummy-channel-title-must-not-appear")
        expect(text).to include("connected")
      end
      expect(result).to be_frozen
    end
  end

  describe UnstartedBroadcast do
    let(:start) { Time.utc(2026, 10, 8, 5, 1, 0) }
    let(:broadcast) { described_class.new(youtube_broadcast_id: "dummybc0001", title: "dummy-title-must-not-appear", scheduled_start_time: start) }

    it "配信の識別子・タイトル・開始予定時刻を持つ" do
      expect(broadcast).to have_attributes(youtube_broadcast_id: "dummybc0001", title: "dummy-title-must-not-appear", scheduled_start_time: start)
    end

    it "タイトルを、inspect・to_s・pretty_inspect に出さない" do
      [ broadcast.inspect, broadcast.to_s, broadcast.pretty_inspect ].each do |text|
        expect(text).not_to include("dummy-title-must-not-appear")
        expect(text).to include("dummybc0001")
      end
    end

    it "matches?: タイトルが完全に一致し、開始予定時刻が同じ（秒単位）なら true（応答喪失時の引き継ぎ。10.1）" do
      expect(broadcast.matches?(title: "dummy-title-must-not-appear", scheduled_start_time: start)).to be(true)
      expect(broadcast.matches?(title: "dummy-title-must-not-appear", scheduled_start_time: start + 0.4)).to be(true)
      expect(broadcast.matches?(title: "dummy-title-must-not-appear", scheduled_start_time: start.getlocal("+09:00"))).to be(true)
    end

    it "matches?: タイトルが違う・1 秒でも時刻が違う・タイトルの大文字小文字や空白が違う、は false" do
      expect(broadcast.matches?(title: "Dummy-title-must-not-appear", scheduled_start_time: start)).to be(false)
      expect(broadcast.matches?(title: "dummy-title-must-not-appear ", scheduled_start_time: start)).to be(false)
      expect(broadcast.matches?(title: "other", scheduled_start_time: start)).to be(false)
      expect(broadcast.matches?(title: "dummy-title-must-not-appear", scheduled_start_time: start + 1)).to be(false)
      expect(broadcast.matches?(title: "dummy-title-must-not-appear", scheduled_start_time: start - 1)).to be(false)
    end

    it "タイトルまたは開始予定時刻が応答に無い配信は、何とも一致しない" do
      incomplete = described_class.new(youtube_broadcast_id: "dummybc0002", title: nil, scheduled_start_time: nil)

      expect(incomplete.matches?(title: "x", scheduled_start_time: start)).to be(false)
    end

    it "引数の検査: 識別子は空でない文字列、時刻は Time または nil" do
      expect { described_class.new(youtube_broadcast_id: "", title: "t", scheduled_start_time: start) }.to raise_error(ArgumentError, /youtube_broadcast_id/)
      expect { described_class.new(youtube_broadcast_id: "b", title: "t", scheduled_start_time: "2026-10-08") }.to raise_error(ArgumentError, /scheduled_start_time/)
      expect { described_class.new(youtube_broadcast_id: "b", title: 1, scheduled_start_time: start) }.to raise_error(ArgumentError, /title/)
      expect(broadcast).to be_frozen
    end
  end
end
