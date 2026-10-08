require "rails_helper"
require "ripper"

# 開発・本番の設定が、SQL のコメントのタグ（query_log_tags_enabled）を有効にしていないこと（issue #8）。
# 有効にすると、Rails は prepared statements を無効にし（ActiveRecord.disable_prepared_statements = true）、SQL の文に値が直接入る。
# ログの SQL に、Google の利用者識別子（sub）・配信のタイトル・暗号化したトークンが、そのまま出る（CLAUDE.md の不変条件）。
# prepared statements では、機密の列（ApplicationRecord::SENSITIVE_ATTRIBUTES）の値は、filter_attributes で [FILTERED] になる。
# テストの環境は、もともと prepared statements なので、開発の設定だけが食い違うと、ログの機密のスペックでは見つからない。
# 設定のファイルを字句解析して、コードの代入を静的に見る。
RSpec.describe "SQL のログ（prepared statements）" do
  def assignments_of(file, name)
    tokens = Ripper.lex(Rails.root.join(file).read(encoding: "UTF-8")).reject { |_, type, _, _| %i[ on_comment on_sp on_nl on_ignored_nl ].include?(type) }
    tokens.each_cons(7).filter_map do |parts|
      texts = parts.map { |part| part[2] }
      texts[6] if texts[0] == "config" && texts[1] == "." && texts[2] == "active_record" && texts[3] == "." && texts[4] == name && texts[5] == "="
    end
  end

  %w[ config/environments/development.rb config/environments/production.rb config/environments/test.rb ].each do |file|
    it "#{file} は、query_log_tags_enabled を true にしていない（SQL の値がログに直接出る）" do
      expect(assignments_of(file, "query_log_tags_enabled")).not_to include("true")
    end
  end

  it "開発の設定は、query_log_tags_enabled = false を明示している（rails new の既定の true へ戻らない）" do
    expect(assignments_of("config/environments/development.rb", "query_log_tags_enabled")).to eq([ "false" ])
  end

  it "このテストの環境は、prepared statements が有効（機密の列の値は filter_attributes で伏せ字になる）" do
    expect(ActiveRecord::Base.connection.prepared_statements).to be(true)
    expect(ActiveRecord.disable_prepared_statements).to be_falsey
  end

  it "機密の列は、filter_attributes に入っている（google_sub・token_digest・sub_digest・pending_title・refresh_token_ciphertext）" do
    expect(ActiveRecord::Base.filter_attributes.map(&:to_s)).to include("google_sub", "token_digest", "sub_digest", "pending_title", "refresh_token_ciphertext")
  end

  it "SQL のログに、機密の列の値が出ない（prepared statements のとき）" do
    log = StringIO.new
    sink = ::Logger.new(log, level: ::Logger::DEBUG)
    Rails.logger.broadcast_to(sink)
    begin
      User.find_by(google_sub: "dummy-google-sub-sql-log-must-not-appear")
      User.create!(google_sub: "dummy-google-sub-sql-log-must-not-appear-2", last_login_at: Time.current)
    ensure
      Rails.logger.stop_broadcasting_to(sink)
    end

    expect(log.string).to include("users")
    expect(log.string).not_to include("dummy-google-sub-sql-log-must-not-appear")
  end

  it "検出の仕組みが働く（コメントアウトされた代入を見ない・true への代入を見つける）" do
    tokens = ->(source) { Ripper.lex(source).reject { |_, type, _, _| %i[ on_comment on_sp on_nl on_ignored_nl ].include?(type) }.map { |part| part[2] } }

    expect(tokens.call("# config.active_record.query_log_tags_enabled = true\n")).to be_empty
    expect(tokens.call("config.active_record.query_log_tags_enabled = true\n")).to eq(%w[ config . active_record . query_log_tags_enabled = true ])
  end
end
