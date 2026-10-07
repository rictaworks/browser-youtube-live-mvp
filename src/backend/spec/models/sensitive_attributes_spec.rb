require "rails_helper"
require "support/model_support"
require "support/expected_schema"

# requirements.md 6.1・7.3・10.1・20.3・28.2。機密の列を、inspect とログに出さない（filter_attributes）。
#   refresh_token_ciphertext  暗号化した更新トークン
#   token_digest              セッション・接続チケットの要約値
#   pending_title             配信のタイトル
#   google_sub                Google の利用者識別子
#   sub_digest                削除したアカウントの Google 識別子の要約値
# テストの値は、明らかなダミー。値が出力に現れないことと、伏せ字（[FILTERED]）が出ることの両方を確かめる
# （何も出力されないために、現れていないのではないことの確認）。
RSpec.describe "機密の列の非出力（filter_attributes）" do
  sensitive_columns = %w[ refresh_token_ciphertext token_digest pending_title google_sub sub_digest ]

  # [ モデル, 機密の列, ダミー値, レコードの作り方 ]
  cases = [
    [ User, :google_sub, "dummy-secret-google-sub-0001", ->(value) { create(:user, google_sub: value) } ],
    [ Session, :token_digest, "dummy-secret-session-digest-0002", ->(value) { create(:session, token_digest: value) } ],
    [ YoutubeConnection, :refresh_token_ciphertext, "dummy-secret-ciphertext-0003", ->(value) { create(:youtube_connection, refresh_token_ciphertext: value) } ],
    [ Broadcast, :pending_title, "dummy-secret-title-0004", ->(value) { create(:broadcast, pending_title: value) } ],
    [ RelayTicket, :token_digest, "dummy-secret-ticket-digest-0005", ->(value) { create(:relay_ticket, token_digest: value) } ],
    [ DeletionHold, :sub_digest, "dummy-secret-sub-digest-0006", ->(value) { create(:deletion_hold, sub_digest: value) } ]
  ]

  def capture_active_record_log
    io = StringIO.new
    previous = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = Logger.new(io, level: Logger::DEBUG)
    yield
    io.string
  ensure
    ActiveRecord::Base.logger = previous
  end

  it "ApplicationRecord の filter_attributes に、5 つの列名が入っている（すべてのモデルが受け継ぐ）" do
    filtered = ApplicationRecord.filter_attributes.map(&:to_s)

    expect(filtered).to include(*sensitive_columns)
  end

  it "どのモデルも、ApplicationRecord の filter_attributes を受け継ぐ" do
    ExpectedSchema::TABLES.each_key do |table|
      model = table.classify.constantize
      expect(model.filter_attributes.map(&:to_s)).to include(*sensitive_columns), "#{model} の filter_attributes に機密の列が無い"
    end
  end

  cases.each do |model, column, value, builder|
    describe "#{model}.#{column}" do
      let!(:record) { instance_exec(value, &builder) }

      it "inspect に、値が現れず、伏せ字が出る" do
        text = record.inspect

        expect(text).not_to include(value)
        expect(text).to include("#{column}: [FILTERED]")
      end

      it "再読み込みしたレコードの inspect にも、値が現れない" do
        expect(model.find_by!(model.primary_key => record.id).inspect).not_to include(value)
      end

      it "レコードの一覧（Relation）の inspect にも、値が現れない" do
        expect(model.where(model.primary_key => record.id).inspect).not_to include(value)
      end

      it "SQL のログ（検索・作成・更新）に、値が現れず、伏せ字が出る" do
        log = capture_active_record_log do
          model.where(column => value).to_a
          record.update!(column => "#{value}-changed") if column != :pending_title
          instance_exec("#{value}-created", &builder)
        end

        expect(log).to include("SELECT")
        expect(log).not_to include(value)
        expect(log).to include("[FILTERED]")
      end
    end
  end

  it "機密でない列は、伏せない（inspect で識別子・状態を確認できる）" do
    user = create(:user)

    expect(user.inspect).to include(%(id: "#{user.id}"))
    expect(user.inspect).to include("last_login_at:")
    expect(create(:broadcast).inspect).to include('state: "reserved"')
  end
end
