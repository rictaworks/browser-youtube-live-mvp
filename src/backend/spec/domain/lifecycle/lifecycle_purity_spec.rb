require "spec_helper"
require_relative "../support/domain_loader"
require_relative "support/domain_source_scanner"

# 配信の生命周期の Domain Core（issue #6 のファイル）の規則（requirements.md 2.5・15 章・27 章。CLAUDE.md）。
#   * 入出力の型（ActiveRecord・ActionController・Rails・ENV）と、実時計（Time.now など）を参照しない。時刻・設定値・現況は引数で受け取る
#   * 他の issue の Domain Core（#5）に依存しない
#   * 期限・間隔・回数の数値、状態・終了理由・清算状態などの符号は、契約（Contract）から取り、直書きしない
#   * 画面に出す文言を持たない（文字列リテラルは ASCII だけ。日本語はコメントだけ）
#   * グローバル変数を使わない
# 検査は、Ripper で、コメントを除いたコードの字句に対して行う（コメントの説明文は、検査の対象にしない）。
RSpec.describe "配信の生命周期の Domain Core の規則（lifecycle_purity）" do
  files = DomainSourceScanner::LIFECYCLE_FILES

  def scanner
    DomainSourceScanner
  end

  def path_of(name)
    File.join(DomainLoader.domain_dir, "#{name}.rb")
  end

  describe "対象のファイル" do
    it "11 個。Zeitwerk の規則（ファイル名 = 定数名）で、読み込める" do
      expect(files.size).to eq(11)
      files.each do |name|
        expect(File.exist?(path_of(name))).to be(true), "#{name}.rb がありません"
        constant = name.split("_").map(&:capitalize).join

        expect(Object.const_defined?(constant)).to be(true), "#{constant} が、定義されていません（#{name}.rb）"
      end
    end

    it "どのファイルにも、frozen_string_literal のマジックコメントがある" do
      files.each do |name|
        expect(File.read(path_of(name)).lines.first(3).join).to include("# frozen_string_literal: true"), "#{name}.rb"
      end
    end
  end

  describe "実際のファイル" do
    files.each do |name|
      it "#{name}.rb: 規則の違反が無い" do
        expect(scanner.violations(path_of(name))).to eq([])
      end
    end

    it "retention_policy.rb は、UsageCalendar（#5）を参照しない。利用日は、引数で受け取る" do
      source = File.read(path_of("retention_policy"))
      code = scanner.code_of(source)

      expect(code).not_to include("UsageCalendar")
      expect(source).to include("hold_usage_date")
    end
  end

  describe "検査器の動作（違反を、見逃さない）" do
    # [見出し, ファイルの内容, 違反の種別]
    {
      "Time.now" => [ "x = Time.now\n", :real_clock ],
      "Time.current" => [ "x = Time.current\n", :real_clock ],
      "Date.today" => [ "x = Date.today\n", :real_clock ],
      "DateTime.now" => [ "x = DateTime.now\n", :real_clock ],
      "Process.clock_gettime" => [ "x = Process.clock_gettime(Process::CLOCK_MONOTONIC)\n", :real_clock ],
      "Rails" => [ "Rails.logger.info(1)\n", :forbidden_constant ],
      "ENV" => [ "x = ENV.fetch(\"A\")\n", :forbidden_constant ],
      "ActiveRecord" => [ "class A < ActiveRecord::Base; end\n", :forbidden_constant ],
      "ActionController" => [ "class A < ActionController::Base; end\n", :forbidden_constant ],
      "ApplicationRecord" => [ "class A < ApplicationRecord; end\n", :forbidden_constant ],
      "File" => [ "File.read(\"a\")\n", :forbidden_constant ],
      "SecureRandom" => [ "SecureRandom.hex\n", :forbidden_constant ],
      "#5 の Domain Core（UsageCalendar）" => [ "UsageCalendar.usage_date(now)\n", :other_issue_constant ],
      "#5 の Domain Core（Settings）" => [ "Settings.defaults\n", :other_issue_constant ],
      "グローバル変数" => [ "$counter = 1\n", :global_variable ],
      "クラス変数" => [ "class A; @@count = 0; end\n", :class_variable ],
      "整数の直書き（90）" => [ "x = 90\n", :integer_literal ],
      "整数の直書き（86_400）" => [ "x = 86_400\n", :integer_literal ],
      "小数の直書き（0.5）" => [ "x = 0.5\n", :float_literal ],
      "日本語の文字列" => [ "x = \"配信を開始します\"\n", :non_ascii_literal ],
      "契約の値の直書き（user_stop）" => [ "x = \"user_stop\"\n", :contract_value_literal ],
      "契約の値の直書き（pending）" => [ "x = 'pending'\n", :contract_value_literal ],
      "契約の値の直書き（resumed）" => [ "x = \"resumed\"\n", :contract_value_literal ],
      "契約の値の直書き（reserved）" => [ "x = \"reserved\"\n", :contract_value_literal ],
      "別のファイルの読み込み（require_relative）" => [ "require_relative \"x\"\n", :require ],
      "許可していない require" => [ "require \"json\"\n", :require ]
    }.each do |label, (source, kind)|
      it "#{label}: #{kind} を検知する" do
        kinds = scanner.violations_in_source(source, name: "sample").map(&:first)

        expect(kinds).to include(kind)
      end
    end

    {
      "コメントの中の Time.now・Rails・ENV・90・日本語・user_stop" => "# Time.now を呼ばない。Rails・ENV を参照しない。90 秒。user_stop\nx = 1\n",
      "契約の定数の参照" => "x = Contract::EndReason::USER_STOP\n",
      "0 と 1" => "x = [0, 1, size - 1]\n",
      "契約に無い、ASCII の符号（settle）" => "BUCKET = \"settle\"\n",
      "require \"date\"（許可）" => "require \"date\"\n",
      "文字列の補間の中の識別子" => "x = \"id=#{id}\"\n",
      "シンボル" => "x = :user_stop\n"
    }.each do |label, source|
      it "#{label}: 違反としない" do
        expect(scanner.violations_in_source(source, name: "sample")).to eq([])
      end
    end

    it "単位の換算のファイル（lifecycle_time_units）だけは、整数の直書きを許す" do
      source = "SECONDS_PER_MINUTE = 60\nSECONDS_PER_DAY = 86_400\n"

      expect(scanner.violations_in_source(source, name: "lifecycle_time_units")).to eq([])
      expect(scanner.violations_in_source(source, name: "other").map(&:first)).to eq(%i[integer_literal integer_literal])
    end

    it "許可の一覧（settlement_rules の live は、YouTube の lifeCycleStatus の値）は、そのファイルだけ" do
      source = "LIVE = \"live\"\n"

      expect(scanner.violations_in_source(source, name: "settlement_rules")).to eq([])
      expect(scanner.violations_in_source(source, name: "other").map(&:first)).to eq([ :contract_value_literal ])
    end

    it "違反には、行番号と、字句を載せる" do
      violations = scanner.violations_in_source("a = 1\nb = Time.now\n", name: "sample")

      expect(violations).to eq([ [ :real_clock, 2, "Time.now" ] ])
    end
  end
end
