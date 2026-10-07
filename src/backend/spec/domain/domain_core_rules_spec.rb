require "spec_helper"
require_relative "support/domain_loader"
require_relative "support/domain_rules"

# Domain Core（app/domain）の規則を、すべてのファイルに適用する（走査）。requirements.md 2.5・15 章・27 章。
# 走査器そのものの検査は、domain_rules_spec.rb。規則の一覧と意味は、support/domain_rules.rb の冒頭。
#
#   - ActiveRecord・ActionController・Rails.*・ENV・File などの入出力・環境の型を参照しない
#   - Time.now・Date.today・Time.current などの実時計を呼ばない（時刻・設定値・現況は、引数で受け取る）
#   - グローバル変数・クラス変数・出力・乱数・待機を使わない（副作用・非決定性を持たない）
#   - 文字列リテラルに、日本語の文章を直書きしない（利用者に表示する文字列は、Domain Core に置かない）
#   - 契約の固定値を、数値で直書きしない（契約の定数モジュールから使う）
#
# app/domain の下のファイルを、すべて検査する（後続の issue のファイルも、自動的に対象になる）。
RSpec.describe "Domain Core の規則の走査（app/domain のすべてのファイル）" do
  let(:domain_files) { Dir.glob(File.join(DomainLoader.domain_dir, "**", "*.rb")).sort }

  it "app/domain に、Ruby のファイルがある（走査の対象が空でない）" do
    expect(domain_files).not_to be_empty
    expect(domain_files.size).to be >= 20
  end

  it "この issue の Domain Core のファイルが、走査の対象に含まれる" do
    relative = domain_files.map { |path| path.delete_prefix("#{DomainLoader.domain_dir}/") }

    expect(relative).to include(
      "usage_calendar.rb", "settings.rb", "start_admission.rb", "quota_policy.rb", "transfer_budget_policy.rb",
      "account_snapshot.rb", "admission.rb", "preconditions.rb", "contract/limits.rb"
    )
  end

  DomainRules::FORBIDDEN_CONSTANTS.each do |constant|
    it "#{constant} を参照しない" do
      offenders = offenders_of(:forbidden_constant) { |violation| violation.excerpt == constant }

      expect(offenders).to be_empty, "#{constant} を参照しているファイル: #{offenders.join(', ')}"
    end
  end

  {
    wall_clock: "実時計（Time.now・Date.today・Time.current・Process.clock_gettime など）を呼ばない",
    global_variable: "グローバル変数を使わない",
    class_variable: "クラス変数を使わない",
    forbidden_call: "出力（puts など）・乱数（rand）・待機（sleep）を呼ばない",
    non_ascii_literal: "文字列リテラルに、非 ASCII（日本語の文章）を書かない",
    non_ascii_identifier: "識別子に、非 ASCII を使わない",
    require_not_allowed: "require は date・time・tzinfo だけ。require_relative・load・autoload を使わない",
    contract_number_literal: "契約の固定値（500・550・340・210・9,000・10,000）を、数値で直書きしない（契約の定数モジュールから使う）"
  }.each do |rule, label|
    it label do
      offenders = offenders_of(rule)

      expect(offenders).to be_empty, "#{label}。違反: #{offenders.join(', ')}"
    end
  end

  def offenders_of(rule)
    domain_files.flat_map do |path|
      DomainRules.violations_in_file(path).select { |violation| violation.rule == rule && (!block_given? || yield(violation)) }
        .map { |violation| "#{path.delete_prefix("#{DomainLoader.domain_dir}/")}:#{violation.line}" }
    end
  end
end
