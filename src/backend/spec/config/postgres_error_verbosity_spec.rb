require "rails_helper"
require "support/model_support"

# PostgreSQL のエラーメッセージに、行の値を入れない（requirements.md 6.1・7.3・10.1・28.2）。
#
# 既定の error verbosity では、PostgreSQL のエラーに DETAIL 行が付き、ActiveRecord の例外のメッセージに、値が入る。
#   CHECK 違反    Failing row contains (…)      行のすべての列の値（配信のタイトル・更新トークンの暗号文など）
#   一意違反      Key (google_sub)=(…) already exists
#   外部キー違反  Key (user_id)=(…) is not present in table "users"
# 例外のメッセージは、ログや応答へ出うる。そこで、接続ごとに、libpq の error verbosity を TERSE（severity と主メッセージだけ）にする
# （config/initializers/postgres_error_verbosity.rb）。例外の種類（SQLSTATE から決まる）と、制約の名前（主メッセージ）は残り、
# 行の値だけが消える。
RSpec.describe "PostgreSQL のエラーメッセージ（libpq の error verbosity = TERSE）" do
  # 違反を起こして、例外を返す。違反した文は、セーブポイントで包み、スペックのトランザクションを壊さない
  def violation_of(&trigger)
    ActiveRecord::Base.transaction(requires_new: true) { instance_exec(&trigger) }
    nil
  rescue ActiveRecord::StatementInvalid => e
    e
  end

  # [ 説明, 例外の種類, 制約の名前（メッセージに残る）, メッセージに現れてはいけない値, 違反の起こし方 ]
  cases = [
    [ "CHECK 違反（配信のタイトルを持つ行）", ActiveRecord::CheckViolation, "chk_broadcasts_state", "dummy-secret-title-0001",
      -> { save_without_validation!(build(:broadcast, state: "bogus", pending_title: "dummy-secret-title-0001")) } ],
    [ "CHECK 違反（更新トークンの暗号文を持つ行）", ActiveRecord::CheckViolation, "chk_youtube_connections_state", "dummy-secret-ciphertext-0002",
      -> { save_without_validation!(build(:youtube_connection, state: "bogus", refresh_token_ciphertext: "dummy-secret-ciphertext-0002")) } ],
    [ "CHECK 違反（タイトルの寿命。識別子の保存後にタイトルを持つ行）", ActiveRecord::CheckViolation, "chk_broadcasts_pending_title_lifecycle", "dummy-secret-title-0003",
      -> { create(:broadcast, pending_title: "dummy-secret-title-0003").update_columns(youtube_broadcast_id: "dummy-youtube-broadcast-0003") } ],
    [ "一意違反（Google の利用者識別子）", ActiveRecord::RecordNotUnique, "idx_users_google_sub", "dummy-secret-google-sub-0004",
      -> {
        create(:user, google_sub: "dummy-secret-google-sub-0004")
        save_without_validation!(build(:user, google_sub: "dummy-secret-google-sub-0004"))
      } ],
    [ "一意違反（セッションの要約値）", ActiveRecord::RecordNotUnique, "idx_sessions_token_digest", "dummy-secret-session-digest-0005",
      -> {
        create(:session, token_digest: "dummy-secret-session-digest-0005")
        save_without_validation!(build(:session, token_digest: "dummy-secret-session-digest-0005"))
      } ],
    [ "一意違反（接続チケットの要約値）", ActiveRecord::RecordNotUnique, "idx_relay_tickets_token_digest", "dummy-secret-ticket-digest-0006",
      -> {
        create(:relay_ticket, token_digest: "dummy-secret-ticket-digest-0006")
        save_without_validation!(build(:relay_ticket, token_digest: "dummy-secret-ticket-digest-0006"))
      } ],
    [ "一意違反（再登録の保留の要約値。主キー）", ActiveRecord::RecordNotUnique, "deletion_holds_pkey", "dummy-secret-sub-digest-0007",
      -> {
        create(:deletion_hold, sub_digest: "dummy-secret-sub-digest-0007")
        save_without_validation!(build(:deletion_hold, sub_digest: "dummy-secret-sub-digest-0007"))
      } ],
    [ "NOT NULL 違反（タイトルを持つ行）", ActiveRecord::NotNullViolation, "privacy_status", "dummy-secret-title-0008",
      -> { save_without_validation!(build(:broadcast, privacy_status: nil, pending_title: "dummy-secret-title-0008")) } ],
    [ "外部キー違反（タイトルと、存在しないアカウントの識別子を持つ行）", ActiveRecord::InvalidForeignKey, "fk_broadcasts_user_id", "dummy-secret-title-0009",
      -> {
        broadcast = build(:broadcast, user: nil, daily_usage: create(:daily_usage), pending_title: "dummy-secret-title-0009")
        broadcast.user_id = "00000000-0000-4000-8000-000000000009"
        save_without_validation!(broadcast)
      } ]
  ]

  cases.each do |label, error_class, constraint, secret, trigger|
    describe label do
      let(:error) { violation_of(&trigger) }

      it "例外の種類は、#{error_class}（SQLSTATE から決まる。メッセージの形に依存しない）" do
        expect(error).to be_a(error_class)
      end

      it "メッセージに、行の値（#{secret}）が現れない" do
        expect(error.message).not_to include(secret)
        expect(error.message).not_to include("Failing row contains")
        expect(error.message).not_to include("DETAIL")
      end

      it "メッセージに、制約（または列）の名前（#{constraint}）が残る" do
        expect(error.message).to include(constraint)
      end
    end
  end

  it "外部キー違反のメッセージに、存在しないアカウントの識別子（Key (user_id)=(…)）も現れない" do
    error = violation_of do
      broadcast = build(:broadcast, user: nil, daily_usage: create(:daily_usage))
      broadcast.user_id = "00000000-0000-4000-8000-00000000000a"
      save_without_validation!(broadcast)
    end

    expect(error).to be_a(ActiveRecord::InvalidForeignKey)
    expect(error.message).not_to include("00000000-0000-4000-8000-00000000000a")
  end

  it "制約の名前と SQLSTATE は、PG::Result のフィールドからも読める（メッセージの文字列を解析しなくてよい）" do
    error = violation_of do
      create(:user, google_sub: "dummy-secret-google-sub-0012")
      save_without_validation!(build(:user, google_sub: "dummy-secret-google-sub-0012"))
    end

    expect(error.cause.result.error_field(PG::PG_DIAG_CONSTRAINT_NAME)).to eq("idx_users_google_sub")
    expect(error.cause.result.error_field(PG::PG_DIAG_SQLSTATE)).to eq("23505")
  end

  describe "接続ごとの設定" do
    # 新しい接続（プールから借りた、別の接続）を使う。テストの接続を、再接続・リセットしない（スペックのトランザクションが、失われないように）。
    # 確認は、error verbosity を DEFAULT にして、元の値（TERSE のはず）を読む。確認のあとの TERSE は、設定した側（初期化子）だけが作る。
    def previous_verbosity_after_reset_to_default(adapter)
      adapter.raw_connection.set_error_verbosity(PG::PQERRORS_DEFAULT)
    end

    let(:adapter) { ActiveRecord::Base.connection_pool.checkout }

    # 確認で DEFAULT にした接続を、プールへ戻さない（ほかのスペックが、DEFAULT の接続を使わないように）
    after { adapter.throw_away! }

    it "新しい接続は、TERSE になっている" do
      expect(previous_verbosity_after_reset_to_default(adapter)).to eq(PG::PQERRORS_TERSE)
    end

    it "reconnect! のあとも、TERSE になっている" do
      previous_verbosity_after_reset_to_default(adapter)

      adapter.reconnect!

      expect(previous_verbosity_after_reset_to_default(adapter)).to eq(PG::PQERRORS_TERSE)
    end

    it "reset! のあとも、TERSE になっている" do
      previous_verbosity_after_reset_to_default(adapter)

      adapter.reset!

      expect(previous_verbosity_after_reset_to_default(adapter)).to eq(PG::PQERRORS_TERSE)
    end

    it "別のスレッドの接続でも、違反のメッセージに値が現れない（接続ごとの設定）" do
      message = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          captured = nil
          ActiveRecord::Base.transaction do
            create(:user, google_sub: "dummy-secret-google-sub-0010")
            captured = violation_of { save_without_validation!(build(:user, google_sub: "dummy-secret-google-sub-0010")) }&.message
            raise ActiveRecord::Rollback
          end
          captured
        end
      end.value

      expect(message).to include("idx_users_google_sub")
      expect(message).not_to include("dummy-secret-google-sub-0010")
    end
  end

  describe "検出力の確認" do
    it "error verbosity を DEFAULT に戻すと、メッセージに行の値が現れる（このスペックが、設定の欠落を検出できる）" do
      raw_connection = ActiveRecord::Base.connection.raw_connection
      # 元の値へ戻す（TERSE を決め打ちで設定しない。設定が無い環境で、あとのスペックの接続を、TERSE にしてしまわないため）
      original = raw_connection.set_error_verbosity(PG::PQERRORS_DEFAULT)

      error = violation_of { save_without_validation!(build(:broadcast, state: "bogus", pending_title: "dummy-secret-title-0011")) }

      expect(error.message).to include("dummy-secret-title-0011")
    ensure
      raw_connection&.set_error_verbosity(original) if original
    end
  end
end
