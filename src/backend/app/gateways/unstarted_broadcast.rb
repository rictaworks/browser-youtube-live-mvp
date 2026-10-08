# 未開始の配信（issue #10。requirements.md 10.1）。YouTubeGateway#list_unstarted_broadcasts が返す。
# 配信の作成要求の応答を受け取れなかったとき、当該チャンネルの未開始の配信を一覧取得し、タイトルと開始予定時刻が一致するものを引き継ぐ。
#
#   youtube_broadcast_id  YouTube の配信の識別子
#   title                 タイトル。照合のためにメモリに置くだけ。保存しない・出さない
#   scheduled_start_time  開始予定時刻（Time）
# タイトル・開始予定時刻が応答に無い配信は、何とも一致しない。
#
# タイトルを、inspect・to_s・pretty_inspect に出さない。凍結されている。
class UnstartedBroadcast
  attr_reader :youtube_broadcast_id, :title, :scheduled_start_time

  def initialize(youtube_broadcast_id:, title:, scheduled_start_time:)
    raise ArgumentError, "youtube_broadcast_id must be a non-empty String" unless youtube_broadcast_id.is_a?(String) && !youtube_broadcast_id.empty?
    raise ArgumentError, "title must be a String or nil" unless title.nil? || title.is_a?(String)
    raise ArgumentError, "scheduled_start_time must be a Time or nil" unless scheduled_start_time.nil? || scheduled_start_time.is_a?(Time)

    @youtube_broadcast_id = youtube_broadcast_id.dup.freeze
    @title = title&.dup&.freeze
    @scheduled_start_time = scheduled_start_time
    freeze
  end

  # タイトルが完全に一致し、開始予定時刻が同じ秒なら true（作成の要求は、秒単位の時刻で送る）
  def matches?(title:, scheduled_start_time:)
    return false if @title.nil? || @scheduled_start_time.nil?

    @title == title && @scheduled_start_time.to_i == scheduled_start_time.to_i
  end

  def inspect
    "#<#{self.class.name} youtube_broadcast_id=#{youtube_broadcast_id} title=[FILTERED] scheduled_start_time=#{scheduled_start_time&.iso8601}>"
  end

  def to_s
    inspect
  end
end
