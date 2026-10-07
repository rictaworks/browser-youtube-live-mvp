# YouTube の接続状態（requirements.md 7.2・7.3・20.1・25.4）。アカウントにつき 1 件。
# 行が無い場合が「未接続」。したがって、行の state は、契約の列挙 youtube_connection_state から not_connected を除いたもの。
#
# クラスの名前は YoutubeConnection（Zeitwerk の規則で、ファイル youtube_connection.rb の定数は、この綴り）。
# 24.2 のクラス図の YouTubeConnection は、このモデルを指す。
class YoutubeConnection < ApplicationRecord
  include OwnerScope

  STORED_STATES = (Contract::YoutubeConnectionState::ALL - [ Contract::YoutubeConnectionState::NOT_CONNECTED ]).freeze

  belongs_to :user

  validates :state, inclusion: { in: STORED_STATES }
  validates :refresh_token_ciphertext, presence: true
  validates :connected_at, presence: true
  validates :last_verified_at, presence: true
end
