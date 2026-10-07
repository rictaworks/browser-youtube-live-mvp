# 接続チケット（requirements.md 11.9・14・20.1）。要約値（token_digest）だけを保存する。チケットそのものの列を持たない。
#
# 使用済みの印（used_at）は、1 度だけ立てられる（20.2）。UPDATE ... WHERE used_at IS NULL の条件付き更新で、原子的に確保する。
# 同時の 2 つの呼び出しのうち、片方だけが成功する。期限（expires_at）の判定は、モデルでは行わない（サービスが行う）。
class RelayTicket < ApplicationRecord
  include OwnerScope

  belongs_to :user
  belongs_to :broadcast

  validates :token_digest, presence: true
  validates :epoch, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :expires_at, presence: true

  scope :unused, -> { where(used_at: nil) }

  # 使用済みの印を、時刻 at で立てる。この呼び出しが立てたなら true。すでに立っていた（ほかの呼び出しが先に立てた）なら false。
  # 時刻は、引数で受け取る（実時計を読まない）。
  def mark_used(at)
    raise ArgumentError, "at must be a Time" unless at.is_a?(Time)

    claimed = self.class.unused.where(id: id).update_all(used_at: at) == 1
    if claimed
      self.used_at = at
      clear_attribute_changes([ :used_at ])
    end
    claimed
  end
end
