# 接続時の確認の結果（issue #10。requirements.md 7.2）。YouTubeGateway#probe_channel が返す。
#
#   outcome        契約の connect_result のうち、次の 3 つ（確認できた結果）
#                  connected         チャンネルがあり、ライブ配信が有効
#                  live_not_enabled  チャンネルはあるが、ライブ配信が有効でない（ライブ未有効・制限中）
#                  no_channel        チャンネルが無い
#                  確認不能（共通枠の枯渇・一時的な失敗）は、結果ではなく、窓口が型付きの例外（QuotaInsufficient・Transient など）を投げる
#   channel_title  チャンネル名。チャンネルがあるときだけ。アカウント画面の表示のために、最長 10 分、メモリにだけ保持する（永続化しない。28.2。#11）
#
# チャンネル名を、inspect・to_s・pretty_inspect に出さない。凍結されている。
class ProbeResult
  OUTCOMES = [ Contract::ConnectResult::CONNECTED, Contract::ConnectResult::LIVE_NOT_ENABLED, Contract::ConnectResult::NO_CHANNEL ].freeze

  attr_reader :outcome, :channel_title

  def initialize(outcome:, channel_title:)
    raise ArgumentError, "outcome must be one of #{OUTCOMES.inspect}" unless OUTCOMES.include?(outcome)

    if outcome == Contract::ConnectResult::NO_CHANNEL
      raise ArgumentError, "channel_title must be nil when there is no channel" unless channel_title.nil?
    else
      raise ArgumentError, "channel_title must be a String when the channel exists" unless channel_title.is_a?(String)
    end

    @outcome = outcome
    @channel_title = channel_title&.dup&.freeze
    freeze
  end

  def connected?
    outcome == Contract::ConnectResult::CONNECTED
  end

  def live_not_enabled?
    outcome == Contract::ConnectResult::LIVE_NOT_ENABLED
  end

  def no_channel?
    outcome == Contract::ConnectResult::NO_CHANNEL
  end

  def inspect
    "#<#{self.class.name} outcome=#{outcome} channel_title=#{channel_title.nil? ? 'nil' : '[FILTERED]'}>"
  end

  def to_s
    inspect
  end
end
