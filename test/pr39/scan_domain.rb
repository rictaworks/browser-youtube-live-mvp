# frozen_string_literal: true

# app/domain の、すべての Ruby ファイルを、Domain Core の規則で走査する（読み取りのみ）。
# 規則（spec/domain/support/domain_rules.rb。Ruby の字句解析 Ripper で、コメントと文字列の内容を除いて検査する）:
#   - ActiveRecord・ActionController・Rails.*・ENV・File などの入出力・環境の型を参照しない
#   - Time.now・Date.today・Time.current などの実時計を呼ばない（時刻・設定値・現況は、引数で受け取る）
#   - グローバル変数・クラス変数・出力・乱数・待機を使わない
#   - 文字列リテラルに、日本語の文章を直書きしない（非 ASCII の文字列リテラルが無い）
#   - 契約の固定値（500・550・340・210・9,000・10,000）を、数値で直書きしない（契約の定数モジュールは対象外）
#
# 使い方（run_all.sh が実行する）:
#   scripts/dc.sh exec -T backend bundle exec ruby - < test/pr39/scan_domain.rb
# 終了コード: 0 = 違反なし / 1 = 違反あり
require "find"

ROOT = ENV.fetch("ISSUE05_APP_ROOT", "/app")
require "#{ROOT}/spec/domain/support/domain_rules"

files = []
Find.find("#{ROOT}/app/domain") { |path| files << path if File.file?(path) && path.end_with?(".rb") }
files.sort!

violations = files.flat_map do |path|
  DomainRules.violations_in_file(path).map { |violation| "#{path.delete_prefix("#{ROOT}/")}:#{violation.line}: #{violation.rule} (#{violation.excerpt})" }
end

puts "#{files.size} ファイルを走査しました（app/domain。契約の定数モジュールを含む）"
puts "規則: 入出力の型・実時計・グローバル変数・クラス変数・出力・乱数・待機・非 ASCII の文字列と識別子・require の制限・契約の固定値の直書き"
if violations.empty?
  puts "問題ありません"
  exit 0
end
puts "問題:"
violations.each { |line| puts "  - #{line}" }
exit 1
