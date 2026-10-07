# frozen_string_literal: true

# ストリームの取り替え（requirements.md 15 章「ストリームの取り替え」・10.5 の表・20.3）。
#
#   StreamReplacementPolicy.discard?(trigger: StreamReplacementPolicy::YOUTUBE_CONNECTED)   # => true
#
# 配信用ストリームは、アカウントごとに 1 本を再利用する。以前の配信が YouTube 上で終端に達していない状態で、同じストリームへ
# 送出すると、以前の配信へ映像が流れる。そこで、次のトリガーが起きた時点で、保存している配信用ストリームの識別子を破棄し、
# 次回の準備で新しいストリームを作成する（取り替え）。清算できない配信を、以後の配信から切り離すためでもある。
#
#   YOUTUBE_CONNECTED             YouTube 接続の成立（再接続を含む）。10.5 の表・7.2
#   SETTLEMENT_ABANDONED          配信が「清算不能」になった時点。10.5 の表・25.2
#   UNSETTLED_IDENTIFIER_ERASED   未清算・清算不能の配信の YouTube 識別子を、保持期間により消去した時点。10.5 の表・20.3
#                                 （清算済みの配信の識別子の消去は、トリガーではない。呼び出し側が、清算状態で区別して指定する）
#   STREAM_ID_EXPIRED             最後の確認から 30 日を過ぎた識別子の消去。20.3（期限の算出は RetentionPolicy）
#
# それ以外のトリガーでは破棄しない。トリガーはシンボル（シンボルでなければ、黙って false にせず ArgumentError）。
class StreamReplacementPolicy
  YOUTUBE_CONNECTED = :youtube_connected
  SETTLEMENT_ABANDONED = :settlement_abandoned
  UNSETTLED_IDENTIFIER_ERASED = :unsettled_identifier_erased
  STREAM_ID_EXPIRED = :stream_id_expired

  # 識別子を破棄するトリガー
  DISCARD_TRIGGERS = [
    YOUTUBE_CONNECTED,
    SETTLEMENT_ABANDONED,
    UNSETTLED_IDENTIFIER_ERASED,
    STREAM_ID_EXPIRED
  ].freeze

  private_class_method :new

  class << self
    # 保存している配信用ストリームの識別子を、破棄するか。
    def discard?(trigger:)
      LifecycleChecks.kind!(trigger, Symbol, "trigger")

      DISCARD_TRIGGERS.include?(trigger)
    end
  end
end
