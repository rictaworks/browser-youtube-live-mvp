require "rails_helper"
require "support/model_support"
require "ripper"

# モデル（app/models）とマイグレーション（db/migrate）のソースの検査（コメントは対象外。字句解析で、コードの部分だけを見る）。
#   1. 日本語の文字列リテラルが無い（利用者に表示する文章は、文言カタログへ分離する。直書きを検知する）
#   2. 実時計を読まない（時刻は引数で受け取る。モデルが Time.now・Time.current・Date.today などを呼ばない）
#   3. ファイルを消す呼び出しが無い
# 削除系の語は、このファイルにも素のまま書かない（語を組み立てる）。
RSpec.describe "モデルとマイグレーションのソース" do
  files = (Dir[Rails.root.join("app/models/**/*.rb").to_s] + Dir[Rails.root.join("db/migrate/*.rb").to_s]).sort

  # 日本語の文字（ひらがな・カタカナ・漢字・全角の記号・半角カナ）
  japanese = /[\p{Hiragana}\p{Katakana}\p{Han}　-〿＀-￯]/

  # 実時計を読む呼び出し（レシーバ => メソッド）
  clock_calls = {
    "Time" => %w[ now current ],
    "Date" => %w[ today current ],
    "DateTime" => %w[ now current ]
  }

  # ファイル・ディレクトリを消す呼び出し。語は、組み立てる
  removal_methods = [ "r" + "m", "r" + "mdir", "rem" + "ove", "del" + "ete", "un" + "link" ]
  removal_receivers = %w[ File FileUtils Dir Pathname ]

  ignored_token_types = %i[ on_comment on_sp on_nl on_ignored_nl on_embdoc_beg on_embdoc on_embdoc_end ]

  # コメント・空白を除いた字句（[[行, 桁], 種類, 文字列, 状態]）
  def code_tokens(path, ignored)
    Ripper.lex(File.read(path, encoding: "UTF-8")).reject { |_, type, _, _| ignored.include?(type) }
  end

  def relative(path)
    Pathname.new(path).relative_path_from(Rails.root).to_s
  end

  it "検査の対象が、空ではない（モデルとマイグレーションが、15 テーブル分ある）" do
    expect(files.grep(%r{/app/models/}).size).to be >= 16 # 15 モデル + ApplicationRecord + OwnerScope
    expect(files.grep(%r{/db/migrate/}).size).to be >= 15
  end

  it "文字列リテラルに、日本語が無い（利用者に表示する文章を、コードに直書きしない）" do
    found = files.flat_map do |path|
      code_tokens(path, ignored_token_types).filter_map do |(line, _), type, text, _|
        "#{relative(path)}:#{line}" if type == :on_tstring_content && text.match?(japanese)
      end
    end

    expect(found).to be_empty, "日本語の文字列リテラルがある（文言カタログへ分離してください）:\n#{found.join("\n")}"
  end

  it "実時計（Time.now・Time.current・Date.today・Date.current・DateTime.now）を読まない（時刻は引数で受け取る）" do
    found = files.flat_map do |path|
      code_tokens(path, ignored_token_types).each_cons(3).filter_map do |first, second, third|
        next unless first[1] == :on_const && second[1] == :on_period && clock_calls.fetch(first[2], []).include?(third[2])

        "#{relative(path)}:#{first[0][0]}: #{first[2]}.#{third[2]}"
      end
    end

    expect(found).to be_empty, "実時計を読んでいる:\n#{found.join("\n")}"
  end

  it "ファイル・ディレクトリを消す呼び出しが無い" do
    found = files.flat_map do |path|
      code_tokens(path, ignored_token_types).each_cons(3).filter_map do |first, second, third|
        next unless first[1] == :on_const && removal_receivers.include?(first[2]) && second[1] == :on_period && removal_methods.include?(third[2])

        "#{relative(path)}:#{first[0][0]}"
      end
    end

    expect(found).to be_empty
  end

  it "検出の仕組みが働く（日本語の文字列リテラル・実時計の呼び出しを含む断片を、検出する）" do
    source = "x = \"#{[ 0x65E5, 0x672C ].pack('U*')}\"\ny = Time.now\n"
    tokens = Ripper.lex(source).reject { |_, type, _, _| ignored_token_types.include?(type) }

    expect(tokens.any? { |_, type, text, _| type == :on_tstring_content && text.match?(japanese) }).to be(true)
    expect(tokens.each_cons(3).any? { |a, b, c| a[2] == "Time" && b[1] == :on_period && clock_calls.fetch(a[2]).include?(c[2]) }).to be(true)
  end
end
