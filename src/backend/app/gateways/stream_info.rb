# 配信用ストリームの接続情報（issue #10。requirements.md 10.1・6.1・28.1）。YouTubeGateway#ensure_stream が返す。
#
#   stream_id   YouTube のストリームの識別子。呼び出し側（#13）が、接続情報と配信レコードへ保存する
#   ingest_url  取り込み先（rtmpsIngestionAddress）。IngestDestination で検証済み（RTMPS・YouTube の取り込み口・443）。配信キーを含まない
#   stream_key  配信キー（streamName）。秘密。保存しない。中継へ内部通信で渡し、中継はメモリにのみ保持する（10.1）
#   created     今回の呼び出しで作成したストリームか（保存した識別子が無い・無効だったとき true）
#
# 配信キーを、inspect・to_s・pretty_inspect に出さない（ログ・例外に紛れ込まないように）。to_h を持たない（ハッシュにして流す経路を作らない）。
# 凍結されている。
class StreamInfo
  attr_reader :stream_id, :ingest_url, :stream_key, :created

  def initialize(stream_id:, ingest_url:, stream_key:, created:)
    @stream_id = text!(stream_id, "stream_id")
    @ingest_url = text!(ingest_url, "ingest_url")
    @stream_key = text!(stream_key, "stream_key")
    raise ArgumentError, "created must be true or false" unless [ true, false ].include?(created)

    @created = created
    freeze
  end

  def created?
    created
  end

  def inspect
    "#<#{self.class.name} stream_id=#{stream_id} ingest_url=#{ingest_url} stream_key=[FILTERED] created=#{created}>"
  end

  def to_s
    inspect
  end

  private

  def text!(value, name)
    raise ArgumentError, "#{name} must be a non-empty String" unless value.is_a?(String) && !value.empty?

    value.dup.freeze
  end
end
