# YouTube の接続状態（requirements.md 7.2・7.3・20.1・21 章）。
# 行が無い場合が「未接続」なので、state は connected・live_not_enabled・revoked の 3 つ（契約の列挙 youtube_connection_state から not_connected を除く）。
class CreateYoutubeConnections < ActiveRecord::Migration[8.1]
  STATES = %w[ connected live_not_enabled revoked ].freeze

  def change
    create_table :youtube_connections, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :user_id, null: false # アカウント識別子。アカウントにつき 1 件（一意）
      t.string :state, null: false
      t.text :refresh_token_ciphertext, null: false # 暗号化した更新トークン。平文は保存しない（7.3）
      t.string :youtube_stream_id # 配信用ストリームの識別子。取り替え時に破棄（10.5）
      t.datetime :stream_verified_at # ストリームの最終確認
      t.datetime :connected_at, null: false
      t.datetime :last_verified_at, null: false

      t.check_constraint in_list("state", STATES), name: "chk_youtube_connections_state"
    end

    add_index :youtube_connections, :user_id, unique: true, name: "idx_youtube_connections_user_id" # 20.2
  end

  private

  # column::text IN (...)。列を text へ明示的に変換する書き方にする。
  # PostgreSQL は、この形の CHECK 制約を、structure.sql へ書き出し、読み込み直して、再び書き出しても、同じ文字列にする。
  # （列を変換せずに IN (...) と書くと、読み込み直したあとの書き出しが、別の（同じ意味の）文字列になり、
  #   structure.sql が、読み込んだ DB から作り直すたびに変わる）
  def in_list(column, values)
    "#{column}::text IN (#{values.map { |value| "'#{value}'" }.join(', ')})"
  end
end
