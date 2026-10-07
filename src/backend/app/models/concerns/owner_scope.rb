# 利用者に属するモデルの、所有権の絞り込み（requirements.md 14 章・28.1）。
#
# 利用者に属するテーブルは、すべてアカウント識別子（user_id）を持つ。アプリケーションは、セッションのアカウントと一致しない
# レコードの参照・更新・削除を、一切行えない。このモジュールを含むモデルは、owned_by(user_or_id) を持つ。
#
#   Broadcast.owned_by(current_user).find(id)    他のアカウントのレコードなら ActiveRecord::RecordNotFound
#   Broadcast.owned_by(current_user).update_all  自分のレコードだけが対象
#
# 利用者のレコードを引くときは、必ず owned_by を経由する。後続の issue は、識別子で書き換えるときも、
#   Broadcast.owned_by(current_user).find(id).update(...)
# の形を使う（モデルの find・where を直接呼ぶのは、システム全体の処理（期限監視・内部通信・保持期間の適用）に限る）。
#
# owned_by の Relation 越しに、他のアカウントのレコードを書き換える・削除する道は、無い。
#   find・find_by・exists?・where・update_all・destroy_all・delete_all  Relation 自身が、絞り込みを守る
#   destroy(id)・delete(id)                                              同上（他のアカウントの識別子は、RecordNotFound・0 件）
#   update(id, 属性)・update!(id, 属性)・increment_counter・decrement_counter
#                                                                         Rails 8.1 の Relation が、絞り込みを無視して、クラスの
#                                                                         メソッド（klass.find・unscoped）を呼ぶ。OwnedRelation が絞り込む
#   upsert・upsert_all                                                    主キーの衝突で、他のアカウントの行を上書きできる。OwnedRelation が、
#                                                                         UnscopedOperationError にする（Model.upsert を、明示した user_id で呼ぶ）
# 対象外（呼び出し側が、他のアカウントを、明示的に指定する操作）:
#   - 関連経由（user.broadcasts.update(id, ...) など。関連の絞り込みは、owned_by とは別の仕組み）
#   - rewhere・unscope・merge で、絞り込みを書き換える（外部の入力を渡さない）
#   - create・insert_all に、他のアカウントの user_id を渡す（user_id は、セッションのアカウントから決める）
#   - reset_counters（counter_cache を使うモデルは、無い。使うときは、同じ絞り込みを足す）
#
# owned_by に、アカウントを特定できない値（nil・空・UUID でない文字列・保存前の User）を渡すと、絞り込まずに失敗する。
# 失敗させずに通すと、user_id が NULL のレコード（アカウントとの紐づけを外した測定イベント）や、全件へ広がるおそれがある。
module OwnerScope
  extend ActiveSupport::Concern

  # owned_by に渡された値から、アカウントを特定できない（呼び出し側の誤り。値そのものは、メッセージに含めない）
  class InvalidOwnerError < ArgumentError; end

  # owned_by の絞り込みを無視する操作（行そのものを渡して、主キーの衝突で上書きするもの）を、owned_by 越しに呼んだ
  class UnscopedOperationError < StandardError; end

  UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  # owned_by が返す Relation に足す（extending）。連結（where・order・merge など）しても、外れない。
  # ActiveRecord の Relation は、識別子を受け取る書き換えのうち、次のものを、絞り込みなしで、クラスへ委譲する。
  module OwnedRelation
    # Relation#update(id, 属性) は、klass.update(id, 属性) を呼び、klass.find(id) が絞り込みを使わない。
    # scoping の中で呼ぶと、find が、この Relation の絞り込みの中で行われる（他のアカウントの識別子は RecordNotFound）。
    # 全件の形（update(属性)）は、Relation 自身が絞り込みを守るので、そのまま。
    def update(id = :all, attributes)
      return super if id == :all

      scoping { model.update(id, attributes) }
    end

    def update!(id = :all, attributes)
      return super if id == :all

      scoping { model.update!(id, attributes) }
    end

    # クラスの update_counters(id, ...) は、unscoped で、主キーだけを条件にする。この Relation の絞り込みの中で、行を更新する。
    # 他のアカウントの識別子は、0 件（Relation#update_counters と同じ。例外にしない）。
    def increment_counter(counter_name, id, by: 1, touch: nil)
      where(model.primary_key => id).update_counters(counter_name => by, touch: touch)
    end

    def decrement_counter(counter_name, id, by: 1, touch: nil)
      increment_counter(counter_name, id, by: -by, touch: touch)
    end

    # 行そのもの（user_id を含む）を渡して、主キーの衝突で、既存の行を上書きする。owned_by では、絞り込めない。
    def upsert(*, **)
      raise UnscopedOperationError, unscoped_message("upsert")
    end

    def upsert_all(*, **)
      raise UnscopedOperationError, unscoped_message("upsert_all")
    end

    private

    def unscoped_message(operation)
      "#{operation} ignores the owned_by scope and can overwrite another account's row; " \
        "call #{model.name}.#{operation} directly with an explicit user_id"
    end
  end

  included do
    # 作成後に、別のアカウントへ付け替えられない（ActiveRecord::ReadonlyAttributeError）
    attr_readonly :user_id

    scope :owned_by, ->(user_or_id) { where(user_id: OwnerScope.owner_id!(user_or_id)).extending(OwnerScope::OwnedRelation) }
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
