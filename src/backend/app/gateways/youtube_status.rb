# 正規化した配信の状態（issue #10。requirements.md 10.2・10.3・10.4・15 章）。
#
# YouTube の lifeCycleStatus の 8 値（complete・created・live・liveStarting・ready・revoked・testStarting・testing）と、
# 「存在しない」（NOT_FOUND）を持つ。値は、清算の規則（SettlementRules。#6）の入力と同じで、value を plan(youtube_status:) へそのまま渡せる。
#   live?             ライブ（10.2 のライブ確定）
#   terminal?         終端: 完了・取り消し（revoked）・存在しない。ライブ中にこの状態なら、配信を終了する（10.3。終了理由: YouTube 側で終了）。
#                     清算では、何もしない（清算済み。10.4）
#   transitioning?    遷移中（liveStarting・testStarting）。10.2 の確認では「まだライブでない」として待つ。
#                     確定タイムアウトの後にこの状態で残った配信は、公式の案内に従い削除する（SettlementRules）
class YouTubeStatus
  NOT_FOUND = SettlementRules::NOT_FOUND
  VALUES = (SettlementRules::LifeCycleStatus::ALL + [ NOT_FOUND ]).freeze
  TERMINAL_VALUES = [ SettlementRules::LifeCycleStatus::COMPLETE, SettlementRules::LifeCycleStatus::REVOKED, NOT_FOUND ].freeze
  TRANSITIONING_VALUES = [ SettlementRules::LifeCycleStatus::LIVE_STARTING, SettlementRules::LifeCycleStatus::TEST_STARTING ].freeze

  attr_reader :value

  # YouTube の応答の lifeCycleStatus（文字列。8 値のどれか）から作る。未知の値は ArgumentError（値をメッセージに出さない）
  def self.from_life_cycle_status(value)
    raise ArgumentError, "life_cycle_status must be one of the YouTube lifeCycleStatus values" unless SettlementRules::LifeCycleStatus::ALL.include?(value)

    new(value)
  end

  def self.not_found
    new(NOT_FOUND)
  end

  def initialize(value)
    raise ArgumentError, "value must be a YouTube lifeCycleStatus or NOT_FOUND" unless VALUES.include?(value)

    @value = value
    freeze
  end

  def live?
    value == SettlementRules::LifeCycleStatus::LIVE
  end

  def complete?
    value == SettlementRules::LifeCycleStatus::COMPLETE
  end

  def revoked?
    value == SettlementRules::LifeCycleStatus::REVOKED
  end

  def not_found?
    value == NOT_FOUND
  end

  def terminal?
    TERMINAL_VALUES.include?(value)
  end

  def transitioning?
    TRANSITIONING_VALUES.include?(value)
  end

  def ==(other)
    other.is_a?(YouTubeStatus) && value == other.value
  end
  alias eql? ==

  def hash
    [ self.class, value ].hash
  end

  def inspect
    "#<#{self.class.name} #{value}>"
  end

  def to_s
    inspect
  end
end
