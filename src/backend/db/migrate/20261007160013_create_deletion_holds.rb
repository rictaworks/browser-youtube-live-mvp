# 削除したアカウントの再登録の保留（requirements.md 7.4・20.1・20.3・21 章）。
# Google 識別子の要約値と期限（削除時点の利用日）だけを持つ。アカウント識別子は持たない（20.1：保持しない）。
class CreateDeletionHolds < ActiveRecord::Migration[8.1]
  def change
    create_table :deletion_holds, id: :string, primary_key: :sub_digest do |t| # Google 識別子の要約値
      t.date :hold_usage_date, null: false # この利用日の終わりまで再登録を保留
    end
  end
end
