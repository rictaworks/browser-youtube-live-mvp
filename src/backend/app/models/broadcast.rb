# 配信レコード（requirements.md 9・10・13・14・20・25 章）。
# モデルは、業務の判定を持たない（受付の判定・状態の遷移・期限の評価・清算は、Domain Core とサービスが行う）。
#
# 制約は、DB が保証する。
#   - 終了していないレコードは、アカウントにつき 1 件まで（部分一意索引。違反は ActiveRecord::RecordNotUnique。検証には置かない）
#   - 状態・終了理由・清算状態・プロファイル・公開範囲は、決まった符号だけ（CHECK）
# このクラスが守るのは、タイトルの寿命（10.1・20.3・28.2）。
#   タイトル（pending_title）は、YouTube の配信識別子を保存した時点、または配信レコードを終了した時点の、早い方で消去する。
class Broadcast < ApplicationRecord
  include OwnerScope

  # 公開範囲（契約 http-api.md の privacy_status）。契約の列挙（enums.json）には無い
  PRIVACY_STATUSES = %w[ public unlisted private ].freeze

  belongs_to :user
  belongs_to :daily_usage
  has_many :relay_tickets
  has_many :health_samples
  has_many :broadcast_events
  has_many :quota_entries

  validates :state, inclusion: { in: Contract::BroadcastState::ALL }
  validates :end_reason, inclusion: { in: Contract::EndReason::ALL }, allow_nil: true
  validates :settlement_state, inclusion: { in: Contract::SettlementState::ALL }
  validates :profile, inclusion: { in: Contract::Profile::ALL }, allow_nil: true
  validates :privacy_status, inclusion: { in: PRIVACY_STATUSES }
  validates :made_for_kids, inclusion: { in: [ true, false ] }
  validates :usage_date, presence: true
  validates :quota_date, presence: true
  validates :accepted_at, presence: true
  validates :settlement_attempts, :prep_reserved_units, :settle_reserved_units, :resume_count, :publisher_epoch, :sent_bytes,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # 保存のたびに、タイトルの寿命を守る。識別子を持つ配信・終了した配信は、タイトルを持てない。
  # 同じ UPDATE 文の中でタイトルが消えるので、識別子の保存と終了の、どの経路でも、タイトルが残る瞬間が無い。
  before_save :clear_pending_title_when_expired

  # YouTube の配信識別子を保存する。同じ更新（1 つの UPDATE 文）で、タイトルを消去する（10.1）。
  def record_youtube_broadcast!(youtube_broadcast_id)
    raise ArgumentError, "youtube_broadcast_id must be present" if youtube_broadcast_id.blank?

    update!(youtube_broadcast_id: youtube_broadcast_id, pending_title: nil)
  end

  # タイトルを消去する。配信レコードの終了時に呼ぶ（保存のたびの消去が、終了の経路でも働くが、明示的に呼べるようにしてある）。
  def clear_pending_title!
    update!(pending_title: nil)
  end

  private

  def clear_pending_title_when_expired
    self.pending_title = nil if youtube_broadcast_id.present? || state == Contract::BroadcastState::ENDED
  end
end
