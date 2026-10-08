# YouTube の接続状態（requirements.md 7.2・7.3・20.1・25.4）。アカウントにつき 1 件。
# 行が無い場合が「未接続」。したがって、行の state は、契約の列挙 youtube_connection_state から not_connected を除いたもの。
#
# クラスの名前は YoutubeConnection（Zeitwerk の規則で、ファイル youtube_connection.rb の定数は、この綴り）。
# 24.2 のクラス図の YouTubeConnection は、このモデルを指す。
#
# 状態の遷移（25.4。issue #10）は、このモデルのメソッドで行う（窓口 YouTubeGateway は、状態を変えない。変えるかどうかは、
# 例外の disposition を見て、呼び出し側が決める）。25.4 の矢印は、3 つの状態のあいだの 6 通りのすべて。
#   mark_connected!         ライブ未有効 -> 接続済み（再確認でライブ有効）、認可失効 -> 接続済み（再接続・ライブ有効）
#   mark_live_not_enabled!  接続済み -> ライブ未有効（準備時にライブ未有効・制限中）、認可失効 -> ライブ未有効（再接続・ライブ未有効）
#   mark_revoked!           接続済み・ライブ未有効 -> 認可失効（トークンの更新が恒久的に失敗・権限の不足）
#   discard_stream!         配信用ストリームの識別子の破棄（ストリームの取り替え。10.5）
# 遷移は、アカウントで絞り込んだ 1 つの UPDATE 文（遷移先と異なるときだけ更新）。メモリ上の値が古くても、他の更新を上書きしない。
# 更新したら true、何も変えなかったら（すでにその状態・行が無い）false。false のとき、メモリ上の値は更新しない。
# 行の作成（接続の成立。TokenVault#store）と削除（接続の解除。TokenVault#revoke）は、ここでは行わない。
class YoutubeConnection < ApplicationRecord
  include OwnerScope

  STORED_STATES = (Contract::YoutubeConnectionState::ALL - [ Contract::YoutubeConnectionState::NOT_CONNECTED ]).freeze

  belongs_to :user

  validates :state, inclusion: { in: STORED_STATES }
  validates :refresh_token_ciphertext, presence: true
  validates :connected_at, presence: true
  validates :last_verified_at, presence: true

  def mark_connected!
    transition_to!(Contract::YoutubeConnectionState::CONNECTED)
  end

  def mark_live_not_enabled!
    transition_to!(Contract::YoutubeConnectionState::LIVE_NOT_ENABLED)
  end

  def mark_revoked!
    transition_to!(Contract::YoutubeConnectionState::REVOKED)
  end

  # 保存している配信用ストリームの識別子と、その最終確認の時刻を破棄する（次回の準備で新しいストリームを作成する）。
  # 破棄したら true、識別子が無ければ false（冪等）
  def discard_stream!
    require_persisted!

    discarded = owned_row.where.not(youtube_stream_id: nil).update_all(youtube_stream_id: nil, stream_verified_at: nil) == 1
    if discarded
      assign_attributes(youtube_stream_id: nil, stream_verified_at: nil)
      clear_attribute_changes(%w[ youtube_stream_id stream_verified_at ])
      Rails.logger.info("youtube_connection stream discarded user_id=#{user_id}")
    end
    discarded
  end

  private

  def transition_to!(target)
    require_persisted!

    changed = owned_row.where.not(state: target).update_all(state: target) == 1
    if changed
      self.state = target
      clear_attribute_changes([ "state" ])
      Rails.logger.info("youtube_connection state changed user_id=#{user_id} to=#{target}")
    end
    changed
  end

  # この接続の行だけを指す Relation（アカウントで絞り込む）
  def owned_row
    self.class.owned_by(user_id).where(id: id)
  end

  def require_persisted!
    raise ArgumentError, "connection must be persisted" unless persisted?
  end
end
