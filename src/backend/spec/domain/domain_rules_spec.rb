require "spec_helper"
require "fileutils"
require "tmpdir"
require_relative "support/domain_rules"

# Domain Core の規則を検査する走査器（support/domain_rules.rb）そのものの検査。
# 走査器が、違反を見逃さず（赤を出す）、コメント・文字列の中の語を誤検知しない（緑を保つ）ことを、合成した小さなソースで確かめる。
# 実際の app/domain への適用は、domain_core_rules_spec.rb。
RSpec.describe "Domain Core の規則の走査器（DomainRules）" do
  def rules_in(source, contract: false)
    DomainRules.violations(source, contract: contract).map(&:rule).uniq.sort
  end

  describe "実時計（wall_clock）" do
    [
      "Time.now", "Time.now.to_i", "::Time.now", "Time . now", "DateTime.now", "Date.today", "Date.current", "Time.current",
      "Process.clock_gettime(Process::CLOCK_MONOTONIC)", "Time.zone.now", "Time.new", "Time.new()", "Time.new\nx = 1",
      "x = Time.now - 60", "[ Time.now ]", "foo(Time.now)"
    ].each do |source|
      it "違反: #{source.inspect}" do
        expect(rules_in(source)).to include(:wall_clock)
      end
    end

    [
      "Time.utc(2026, 10, 7)", "Time.new(2026, 10, 7, 3, 0, 0, \"+09:00\")", "Time.at(0)", "Date.new(2026, 10, 7)",
      "# Time.now は呼ばない", "x = \"Time.now\"", "message = 'Date.today'", "now = 1", "request.now", "Timer.now", "MyTime.now",
      "<<~TEXT\n  Time.now\nTEXT\n", "=begin\nTime.now\n=end\n"
    ].each do |source|
      it "違反ではない: #{source.inspect}" do
        expect(rules_in(source)).not_to include(:wall_clock)
      end
    end

    it "違反の行番号を返す（コメント・複数行の文字列を挟んでも、元の行番号）" do
      source = "# 1\nx = \"a\nb\"\n\nTime.now\n"
      violations = DomainRules.violations(source)

      expect(violations.map(&:line)).to eq([ 5 ])
    end
  end

  describe "入出力・環境の型（forbidden_constant）" do
    %w[
      Rails ActiveRecord ActiveSupport ActiveModel ActiveJob ActionController ActionDispatch ActionView
      ApplicationRecord ApplicationController Rack ENV File Dir IO Net Socket Logger Random SecureRandom
    ].each do |constant|
      it "違反: #{constant}" do
        expect(rules_in("x = #{constant}.foo")).to include(:forbidden_constant)
        expect(rules_in("class A < #{constant}::Base; end")).to include(:forbidden_constant)
      end
    end

    it "違反: ENV[...]・Rails.logger・Net::HTTP・File.read" do
      [ "ENV[\"X\"]", "Rails.logger.info(x)", "Net::HTTP.get(uri)", "File.read(path)", "Dir.glob(\"*\")" ].each do |source|
        expect(rules_in(source)).to include(:forbidden_constant)
      end
    end

    it "違反ではない: 似た名前・コメント・文字列の中" do
      [ "Environment.name", "FileName", "Directory", "Contract::Limits", "# Rails は使わない", "x = \"ENV\"", "RAILS_ENV = 1", "Randomizer" ].each do |source|
        expect(rules_in(source)).not_to include(:forbidden_constant)
      end
    end
  end

  describe "グローバル変数・クラス変数" do
    it "違反: $stdout・$counter・@@count" do
      expect(rules_in("$stdout.puts 1")).to include(:global_variable)
      expect(rules_in("$counter = 1")).to include(:global_variable)
      expect(rules_in("@@count = 1")).to include(:class_variable)
    end

    it "違反ではない: インスタンス変数・コメント・文字列" do
      expect(rules_in("@value = 1")).not_to include(:global_variable, :class_variable)
      expect(rules_in("# $stdout @@count")).to eq([])
      expect(rules_in("x = \"$stdout @@count\"")).to eq([])
    end
  end

  describe "出力・乱数・待機（forbidden_call）" do
    %w[puts print pp warn printf putc rand srand sleep].each do |call|
      it "違反: #{call}" do
        expect(rules_in("#{call} 1")).to include(:forbidden_call)
        expect(rules_in("x.#{call}(1)")).to include(:forbidden_call)
      end
    end

    it "違反ではない: 似た名前・コメント・文字列" do
      [ "randomize(1)", "sleeper", "warning", "printable", "# puts は使わない", "x = \"puts\"" ].each do |source|
        expect(rules_in(source)).not_to include(:forbidden_call)
      end
    end
  end

  describe "文字列リテラルの非 ASCII（non_ascii_literal）" do
    [
      "x = \"日本語\"", "x = '利用枠を消費しました'", "x = \"ab\u3042\"", "x = :\"あ\"", "x = %w[ a あ ]", "x = <<~TEXT\n  文章\nTEXT\n", "x = /あ/"
    ].each do |source|
      it "違反: #{source.inspect}" do
        expect(rules_in(source)).to include(:non_ascii_literal)
      end
    end

    it "違反ではない: ASCII の文字列・エスケープ表記の非 ASCII・コメントの日本語" do
      [
        "x = \"abc\"", "x = \"\\u3042\"", "x = /[\\u200B\\u3000]/", "# 日本語のコメント\nx = 1", "x = 1 # 利用枠", "=begin\n日本語\n=end\n"
      ].each do |source|
        expect(rules_in(source)).not_to include(:non_ascii_literal)
      end
    end
  end

  describe "識別子の非 ASCII（non_ascii_identifier）" do
    [ "利用枠 = 1", "def 判定; end", "x = 結果.call", "x = { 理由: 1 }" ].each do |source|
      it "違反: #{source.inspect}" do
        expect(rules_in(source)).to include(:non_ascii_identifier)
      end
    end
  end

  describe "読み込み（require_not_allowed）" do
    [ "require \"rails\"", "require 'active_support/all'", "require(\"json\")", "require_relative \"x\"", "load \"x.rb\"", "autoload :X, \"x\"" ].each do |source|
      it "違反: #{source}" do
        expect(rules_in(source)).to include(:require_not_allowed)
      end
    end

    [ "require \"date\"", "require 'time'", "require(\"tzinfo\")", "require \"date\"\nrequire \"tzinfo\"\n" ].each do |source|
      it "違反ではない: #{source.inspect}" do
        expect(rules_in(source)).not_to include(:require_not_allowed)
      end
    end

    it "require の引数でない文字列は、require として扱わない" do
      expect(rules_in("require \"date\"\nx = \"rails\"\n")).to eq([])
    end
  end

  describe "契約の固定値の直書き（contract_number_literal）" do
    [ "x = 500", "x = 550", "x = 340", "x = 210", "x = 9000", "x = 9_000", "x = 10_000", "x = 10000", "foo(550)", "a <= 9_000" ].each do |source|
      it "違反: #{source}" do
        expect(rules_in(source)).to include(:contract_number_literal)
      end
    end

    it "違反ではない: ほかの数値・似た数値・コメント・文字列" do
      [ "x = 5500", "x = 55", "x = 1550", "x = 501", "x = 3", "x = 60", "x = 100", "x = 2_147_483_647", "x = 0.5", "# 550", "x = \"550\"" ].each do |source|
        expect(rules_in(source)).not_to include(:contract_number_literal)
      end
    end

    it "契約の定数モジュール（contract: true）では、数値を許す" do
      expect(rules_in("X = 550", contract: true)).to eq([])
      expect(rules_in("X = 550", contract: false)).to include(:contract_number_literal)
    end
  end

  describe "清潔なコード" do
    it "典型的な Domain Core のコード（定数の参照・純粋な計算・コメントの日本語）は、違反なし" do
      source = <<~RUBY
        # frozen_string_literal: true

        require "date"

        # 日本語のコメント
        module Example
          LIMIT = Contract::Limits::QUOTA.fetch("common_units")

          class << self
            def total(day, units:)
              day.used_units + units
            end
          end
        end
      RUBY

      expect(DomainRules.violations(source)).to eq([])
    end

    it "空のソースは、違反なし" do
      expect(DomainRules.violations("")).to eq([])
    end
  end

  describe "ファイルの検査（契約の定数モジュールの扱い）" do
    it "app/domain/contract の下のパスは、契約の定数モジュールとして、数値の直書きを許す" do
      # 一時ディレクトリは、ブロックなしで作る（ブロック形式は、ブロックの終了時に、中身ごと削除する。後始末は OS に任せる）
      dir = Dir.mktmpdir("domain_rules_files")
      contract_dir = File.join(dir, "app", "domain", "contract")
      FileUtils.mkdir_p(contract_dir)
      File.write(File.join(contract_dir, "limits.rb"), "X = 550\n")
      File.write(File.join(dir, "app", "domain", "other.rb"), "X = 550\n")

      expect(DomainRules.violations_in_file(File.join(contract_dir, "limits.rb"))).to eq([])
      expect(DomainRules.violations_in_file(File.join(dir, "app", "domain", "other.rb")).map(&:rule)).to eq([ :contract_number_literal ])
    end
  end
end
