require "spec_helper"
require "zeitwerk"
require_relative "support/domain_loader"

# app/domain の、すべてのファイルが、Zeitwerk の規則（app/domain が autoload のルート。ファイルのパスと定数名の対応）で
# 読み込めること。Rails（config.eager_load = true の CI・本番）でも、素の Zeitwerk（Rails を起動しないスペック）でも、
# 同じ規則で、パスに対応する定数が定義される。ファイルごとに検査し、失敗したファイルを、すべて名前で挙げる。
# （ローダーは eager_load しない。定数を参照して、そのファイルだけを読み込む。DomainLoader の説明）
RSpec.describe "app/domain の読み込み（Zeitwerk の規則）" do
  def domain_files
    Dir.glob(File.join(DomainLoader.domain_dir, "**", "*.rb")).sort
  end

  # app/domain からの相対パスを、Zeitwerk の規則での定数名にする（contract/ws_message_type.rb は Contract::WsMessageType）
  def constant_path(path)
    inflector = Zeitwerk::Inflector.new
    path.delete_prefix("#{DomainLoader.domain_dir}/").delete_suffix(".rb").split("/").map { |segment| inflector.camelize(segment, path) }.join("::")
  end

  {
    "usage_calendar.rb" => "UsageCalendar",
    "start_admission.rb" => "StartAdmission",
    "start_admission/rate_limit.rb" => "StartAdmission::RateLimit",
    "start_admission/state_rules.rb" => "StartAdmission::StateRules",
    "quota_policy/day.rb" => "QuotaPolicy::Day",
    "settings/invalid_setting.rb" => "Settings::InvalidSetting",
    "admission/applied_limits.rb" => "Admission::AppliedLimits",
    "contract/ws_message_type.rb" => "Contract::WsMessageType",
    "contract/http_rejections.rb" => "Contract::HttpRejections"
  }.each do |relative, expected|
    it "パスと定数名の対応（検査の妥当性）: #{relative} は #{expected}" do
      expect(constant_path(File.join(DomainLoader.domain_dir, relative))).to eq(expected)
    end
  end

  it "app/domain のすべてのファイルが、パスに対応する定数（Module・Class）を定義している" do
    failures = domain_files.filter_map do |path|
      name = constant_path(path)
      value = Object.const_get(name)
      "#{name}: Module でも Class でもありません" unless value.is_a?(Module)
    rescue NameError, LoadError, SyntaxError => error
      "#{path.delete_prefix("#{DomainLoader.domain_dir}/")}（#{name}）: #{error.class}: #{error.message.lines.first&.strip}"
    end

    expect(failures).to eq([])
  end

  it "この issue の定数（Domain Core 1）が、すべて読み込める" do
    names = %w[
      Preconditions UsageCalendar Settings Settings::Rules Settings::InvalidSetting TransferBudgetPolicy
      QuotaPolicy QuotaPolicy::Day QuotaPolicy::Reservation QuotaPolicy::Booked QuotaPolicy::Refused QuotaPolicy::Carried
      AccountSnapshot Admission Admission::Accepted Admission::Rejected Admission::AppliedLimits
      StartAdmission StartAdmission::Input StartAdmission::RateLimit StartAdmission::RetryAt StartAdmission::StateRules
    ]

    names.each { |name| expect(Object.const_get(name)).to be_a(Module), "#{name} が読み込めません" }
  end
end
