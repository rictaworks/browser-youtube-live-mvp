# 利用者に属するモデルの、所有権の絞り込み（requirements.md 14 章・28.1）。
#
# 利用者に属するテーブルは、すべてアカウント識別子（user_id）を持つ。アプリケーションは、セッションのアカウントと一致しない
# レコードの参照・更新・削除を、一切行えない。このモジュールを含むモデルは、owned_by(user_or_id) を持つ。
#
#   Broadcast.owned_by(current_user).find(id)    他のアカウントのレコードなら ActiveRecord::RecordNotFound
#   Broadcast.owned_by(current_user).update_all  自分のレコードだけが対象
#
# 利用者のレコードを引くときは、必ず owned_by を経由する。モデルの find・where を直接呼ぶのは、システム全体の処理
# （期限監視・内部通信・保持期間の適用）に限る。
#
# owned_by に、アカウントを特定できない値（nil・空・UUID でない文字列・保存前の User）を渡すと、絞り込まずに失敗する。
# 失敗させずに通すと、user_id が NULL のレコード（アカウントとの紐づけを外した測定イベント）や、全件へ広がるおそれがある。
module OwnerScope
  extend ActiveSupport::Concern

  # owned_by に渡された値から、アカウントを特定できない（呼び出し側の誤り。値そのものは、メッセージに含めない）
  class InvalidOwnerError < ArgumentError; end

  UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  included do
    # 作成後に、別のアカウントへ付け替えられない（ActiveRecord::ReadonlyAttributeError）
    attr_readonly :user_id

    scope :owned_by, ->(user_or_id) { where(user_id: OwnerScope.owner_id!(user_or_id)) }
  end

  # owned_by の引数（User、または UUID の文字列）から、アカウント識別子（小文字の UUID の文字列）を取り出す。
  def self.owner_id!(user_or_id)
    id = user_or_id.is_a?(User) ? user_or_id.id : user_or_id

    unless id.is_a?(String) && UUID_FORMAT.match?(id)
      raise InvalidOwnerError, "owned_by requires a User with an id or an account id (UUID string), got #{user_or_id.class}"
    end

    id.downcase
  end
end
