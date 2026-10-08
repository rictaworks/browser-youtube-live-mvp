require "rails_helper"
require "ripper"

# 本番の SSL の設定（config/environments/production.rb）の静的な検査（issue #8。#7 のレビューの提案 P5。requirements.md 7.1・28.1）。
# Railway は TLS を終端する。次の 2 つが true でないと、セッションの Cookie の Secure が成立しない。
#   assume_ssl  すべての要求を SSL として扱う（Rails は、SSL でない要求には、Secure の Cookie を書かない）
#   force_ssl   http の要求を https へ移し、HSTS を付け、Cookie に Secure を付ける
# ファイルを字句解析して、コメントや文字列ではなく、コードの代入を見る。実際に本番を起動する確認は、test/pr<番号>/ の本番の起動の検査。
RSpec.describe "本番の SSL の設定（config/environments/production.rb）" do
  let(:path) { Rails.root.join("config/environments/production.rb") }
  let(:tokens) do
    Ripper.lex(path.read(encoding: "UTF-8")).reject { |_, type, _, _| %i[ on_comment on_sp on_nl on_ignored_nl ].include?(type) }
  end

  # config.<name> = <value> の代入の、値の語（代入ごとに 1 つ）
  def assignments_of(name)
    tokens.each_cons(5).filter_map do |config, period, setting, equals, value|
      next unless config[2] == "config" && period[1] == :on_period && setting[2] == name && equals[2] == "=" && equals[1] == :on_op

      value[2]
    end
  end

  it "検査の対象のファイルがある" do
    expect(path).to exist
  end

  it "config.assume_ssl = true（コードの代入として 1 回以上。false への代入が無い）" do
    values = assignments_of("assume_ssl")

    expect(values).not_to be_empty, "config.assume_ssl の代入が見つからない（コメントアウトされている）"
    expect(values).to all(eq("true"))
  end

  it "config.force_ssl = true（コードの代入として 1 回以上。false への代入が無い）" do
    values = assignments_of("force_ssl")

    expect(values).not_to be_empty, "config.force_ssl の代入が見つからない（コメントアウトされている）"
    expect(values).to all(eq("true"))
  end

  it "最後の代入が true（あとから false に上書きされていない）" do
    expect(assignments_of("assume_ssl").last).to eq("true")
    expect(assignments_of("force_ssl").last).to eq("true")
  end

  it "検出の仕組みが働く（コメントアウトされた代入・false への代入を、true と見なさない）" do
    commented = Ripper.lex("# config.force_ssl = true\n").reject { |_, type, _, _| %i[ on_comment on_sp on_nl on_ignored_nl ].include?(type) }
    disabled = Ripper.lex("config.force_ssl = false\n").reject { |_, type, _, _| %i[ on_comment on_sp on_nl on_ignored_nl ].include?(type) }

    expect(commented).to be_empty
    expect(disabled.map { |token| token[2] }).to eq([ "config", ".", "force_ssl", "=", "false" ])
  end

  it "本番の起動に要る環境変数の検査（RequiredEnvironment）に、SESSION_SECRET・BFF_SHARED_SECRET がある（Cookie と CSRF の鍵・BFF の確認）" do
    expect(RequiredEnvironment::NAMES).to include("SESSION_SECRET", "BFF_SHARED_SECRET", "GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET", "RECAPTCHA_SECRET_KEY")
  end
end
