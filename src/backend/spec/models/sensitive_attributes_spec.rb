require "rails_helper"
require "support/model_support"
require "support/expected_schema"

# requirements.md 6.1・7.3・10.1・20.3・28.2。機密の列を、inspect・ログ・例外のメッセージに出さない。
#   refresh_token_ciphertext  暗号化した更新トークン
#   token_digest              セッション・接続チケットの要約値
#   pending_title             配信のタイトル
#   google_sub                Google の利用者識別子
#   sub_digest                削除したアカウントの Google 識別子の要約値
# inspect とログは、filter_attributes（伏せ字 [FILTERED]）で伏せる。例外のメッセージは、filter_attributes では伏せられない。
# PostgreSQL の既定のエラーには、DETAIL 行（CHECK 違反の Failing row contains (…)・一意違反の Key (列)=(値)）が付き、
# ActiveRecord の例外のメッセージに入る。そこで、接続の error verbosity を TERSE にして、値を、メッセージへ出さない
# （config/initializers/postgres_error_verbosity.rb。詳しい検査は spec/config/postgres_error_verbosity_spec.rb）。
# テストの値は、明らかなダミー。値が出力に現れないことと、伏せ字（[FILTERED]）が出ることの両方を確かめる
# （何も出力されないために、現れていないのではないことの確認）。
RSpec.describe "機密の列の非出力（filter_attributes・例外のメッセージ）" do
  sensitive_columns = %w[ refresh_token_ciphertext token_digest pending_title google_sub sub_digest ]

  # [ モデル, 機密の列, ダミー値, レコードの作り方, 制約違反の起こし方（その値を持つ行で）, 例外のメッセージに残る制約の名前 ]
  cases = [
    [ User, :google_sub, "dummy-secret-google-sub-0001", ->(value) { create(:user, google_sub: value) },
      ->(value) { save_without_validation!(build(:user, google_sub: value)) }, "idx_users_google_sub" ],
    [ Session, :token_digest, "dummy-secret-session-digest-0002", ->(value) { create(:session, token_digest: value) },
      ->(value) { save_without_validation!(build(:session, token_digest: value)) }, "idx_sessions_token_digest" ],
    [ YoutubeConnection, :refresh_token_ciphertext, "dummy-secret-ciphertext-0003", ->(value) { create(:youtube_connection, refresh_token_ciphertext: value) },
      ->(value) { save_without_validation!(build(:youtube_connection, state: "bogus", refresh_token_ciphertext: value)) }, "chk_youtube_connections_state" ],
    [ Broadcast, :pending_title, "dummy-secret-title-0004", ->(value) { create(:broadcast, pending_title: value) },
      ->(value) { save_without_validation!(build(:broadcast, state: "bogus", pending_title: value)) }, "chk_broadcasts_state" ],
    [ RelayTicket, :token_digest, "dummy-secret-ticket-digest-0005", ->(value) { create(:relay_ticket, token_digest: value) },
      ->(value) { save_without_validation!(build(:relay_ticket, token_digest: value)) }, "idx_relay_tickets_token_digest" ],
    [ DeletionHold, :sub_digest, "dummy-secret-sub-digest-0006", ->(value) { create(:deletion_hold, sub_digest: value) },
      ->(value) { save_without_validation!(build(:deletion_hold, sub_digest: value)) }, "deletion_holds_pkey" ]
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

  cases.each do |model, column, value, builder, violation, constraint|
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

      it "制約違反（CHECK・一意）の例外のメッセージに、値が現れず、制約の名前が残る" do
        error = begin
          ActiveRecord::Base.transaction(requires_new: true) { instance_exec(value, &violation) }
          nil
        rescue ActiveRecord::StatementInvalid => e
          e
        end

        expect(error).not_to be_nil, "制約違反が起きない"
        expect(error.message).not_to include(value)
        expect(error.message).to include(constraint)
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
