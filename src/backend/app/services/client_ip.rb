require "ipaddr"

# 利用者の IP（issue #7。requirements.md 28.1・28.2。src/contracts/http-api.md 1.2）。
#
# BFF の確認（X-BFF-Secret）を通った要求の X-Forwarded-For の先頭だけから読む（VerifiedBffRequest が、保管された転送ヘッダから作る。
# 確認を通らない要求の転送ヘッダは、読めない。lib/forwarded_headers.rb）。IP は、頻度制限の計数にだけ使う。
# DB・測定イベント・配信レコード・ログへ記録しない（inspect にも出さない）。
#
# IP として読めない値（ヘッダが無い・IP でない）は、別の値で補わず、不明（UNKNOWN）にする。
# 同じ利用者を別の計数にしないよう、表記をそろえる（IPv6 の短い表記・IPv4 射影アドレスは IPv4）。
class ClientIp
  UNKNOWN = "unknown".freeze

  # IP の表記に使える文字（16 進数・コロン・ドット）と、長さ。ゾーン識別子（%）・CIDR（/）・角括弧・ポートを持つ値を、先に弾く
  CANDIDATE = /\A[0-9A-Fa-f:.]{2,45}\z/
  # HTTP のヘッダの値の前後の空白（OWS。空白とタブだけ。制御文字は、取り除かない）
  OWS = /\A[ \t]+|[ \t]+\z/

  # X-Forwarded-For の値（文字列。または nil）の先頭の IP。どんな入力でも、例外にせず、ClientIp を返す
  def self.parse(header)
    return new(UNKNOWN) unless header.is_a?(String) && header.valid_encoding?

    first = header.split(",", 2).first.to_s.gsub(OWS, "")
    return new(UNKNOWN) unless CANDIDATE.match?(first)

    new(IPAddr.new(first).native.to_s)
  rescue IPAddr::Error
    new(UNKNOWN)
  end

  private_class_method :new

  def initialize(value)
    @value = value.dup.freeze
    freeze
  end

  def known?
    @value != UNKNOWN
  end

  # 頻度制限の鍵に使う文字列（IP。不明なら UNKNOWN）
  def to_s
    @value
  end

  def ==(other)
    other.is_a?(self.class) && other.to_s == to_s
  end
  alias_method :eql?, :==

  def hash
    [ self.class, @value ].hash
  end

  # IP を、ログ・例外の報告へ出さない
  def inspect
    "#<#{self.class.name} [FILTERED]>"
  end
end
