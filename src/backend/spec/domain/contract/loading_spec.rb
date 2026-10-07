require "spec_helper"
require "ripper"
require_relative "support/contracts_loader"

# app/domain/contract が、Zeitwerk の規則（app/domain が autoload のルート。ファイルのパスと定数名の対応）で読み込めること。
# あわせて、Domain Core の規則（入出力の型・実時計を参照しない）と、画面に出す文言を含まないこと。
RSpec.describe "契約の定数モジュールの読み込み" do
  enum_names = ContractSpecSupport.load_json("enums.json").fetch("enums").keys
  expected_files = (enum_names + %w[ value_set limits http_rejections ]).sort

  before(:all) { ContractSpecSupport.load_contract_namespace! }

  let(:source_files) { Dir.glob(File.join(ContractSpecSupport.contract_dir, "**", "*.rb")).sort }

  it "app/domain/contract のファイルは、24 の列挙と、value_set・limits・http_rejections だけ" do
    basenames = source_files.map { |path| File.basename(path, ".rb") }

    expect(basenames).to eq(expected_files)
    expect(enum_names.size).to eq(24)
  end

  it "どのファイルも、パスに対応する定数（Contract::<名前>）を定義している（Zeitwerk の規則）" do
    expected_files.each do |basename|
      constant = ContractSpecSupport.module_name_for(basename)

      expect(Contract.const_defined?(constant, false)).to be(true), "Contract::#{constant} が定義されていません（#{basename}.rb）"
      expect(Contract.const_get(constant, false)).to be_a(Module)
    end
  end

  it "Contract の名前空間は、ファイルに対応する定数だけを持つ" do
    expected_constants = expected_files.map { |basename| ContractSpecSupport.module_name_for(basename).to_sym }

    expect(Contract.constants(false).sort).to eq(expected_constants.sort)
  end

  it "規則の確認: end_reason.rb は Contract::EndReason（EndReasons や Endreason ではない）" do
    expect(Contract.const_defined?(:EndReason, false)).to be(true)
    expect(Contract.const_defined?(:EndReasons, false)).to be(false)
    expect(Contract.const_defined?(:Endreason, false)).to be(false)
  end

  describe "Domain Core の規則" do
    forbidden = {
      "Rails・ActiveRecord・ActionController・ApplicationRecord・ENV（入出力・環境の型）" =>
        /\b(Rails|ActiveRecord|ActiveSupport|ActionController|ApplicationRecord|ENV)\b/,
      "実時計（Time.now・Date.today・DateTime.now）" => /\b(Time\.now|Date\.today|DateTime\.now)\b/
    }

    forbidden.each do |label, pattern|
      it "#{label} を参照しない" do
        source_files.each do |path|
          code = Ripper.lex(File.read(path)).reject { |(_, type, _)| type == :on_comment }.map { |(_, _, token)| token }.join

          expect(code).not_to match(pattern), "#{File.basename(path)} が #{label} を参照しています"
        end
      end
    end

    it "グローバル変数を使わない" do
      source_files.each do |path|
        tokens = Ripper.lex(File.read(path)).select { |(_, type, _)| type == :on_gvar }

        expect(tokens).to be_empty, "#{File.basename(path)} がグローバル変数を使っています"
      end
    end
  end

  describe "画面に出す文言を含まない（機械可読の符号だけ）" do
    it "文字列リテラルは、すべて ASCII（日本語はコメントだけ）" do
      source_files.each do |path|
        literals = Ripper.lex(File.read(path)).select { |(_, type, _)| type == :on_tstring_content }.map { |(_, _, token)| token }

        literals.each do |literal|
          expect(literal.ascii_only?).to be(true), "#{File.basename(path)} に ASCII 以外の文字列リテラルがあります: #{literal}"
        end
      end
    end

    it "シンボル・正規表現のリテラルも ASCII" do
      source_files.each do |path|
        tokens = Ripper.lex(File.read(path)).select { |(_, type, _)| %i[ on_ident on_const on_label on_regexp_beg ].include?(type) }

        tokens.each { |(_, _, token)| expect(token.ascii_only?).to be(true), "#{File.basename(path)}: #{token}" }
      end
    end

    it "文字列リテラルの値は、英小文字の snake_case（プロファイルは数字を含む）・16 進の色・ホスト名・コーデック文字列などの符号" do
      source_files.each do |path|
        literals = Ripper.lex(File.read(path)).select { |(_, type, _)| type == :on_tstring_content }.map { |(_, _, token)| token }

        literals.each do |literal|
          expect(literal).to match(/\A[A-Za-z0-9_.#:-]+\z/), "#{File.basename(path)}: 文章に見える文字列リテラル #{literal.inspect}"
        end
      end
    end
  end
end
