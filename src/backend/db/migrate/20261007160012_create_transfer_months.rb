# 暦月ごとの送信転送量の積算（requirements.md 8.3・20.1・21 章）。システム全体の表。主キーは、暦月の文字列（"2026-10"。JST の暦月）。
class CreateTransferMonths < ActiveRecord::Migration[8.1]
  def change
    create_table :transfer_months, id: :string, primary_key: :month do |t|
      t.bigint :sent_bytes, null: false, default: 0 # 送信転送量の積算

      t.check_constraint "sent_bytes >= 0", name: "chk_transfer_months_sent_bytes_non_negative"
      # 月の文字列の形（YYYY-MM）。形がずれると、同じ月の積算が分かれる（予算の判定が効かなくなる）
      t.check_constraint %q(month ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'), name: "chk_transfer_months_month_format"
    end
  end
end
