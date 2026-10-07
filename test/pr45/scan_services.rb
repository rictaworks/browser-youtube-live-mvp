# frozen_string_literal: true

# この issue のサービス（app/services の DailyAllowance・QuotaLedger・TransferBudget・SettingsStore と、QuotaLedger の部品）を、
# Ruby の字句解析（Ripper）で走査する（読み取りのみ）。コメントは対象外。実装担当のスペック（service_sources_spec.rb）とは別の実装で、
# 同じ規則を確かめる（見落としの相互確認）。
#
# 規則:
#   1. 日本語の文字列リテラルが無い（利用者に表示する文章を、コードに直書きしない。例外のメッセージ・ログは ASCII）
#   2. 実時計を読まない。ただし、呼び出しの時刻の既定（now: Time.current）だけは許す
#   3. 契約の固定値（500・550・340・210・9,000・10,000・1 GB）を、数値で直書きしない
#   4. 行・ファイルを消す呼び出しが無い。requires_new・グローバル変数・クラス変数が無い
#   5. rescue は、クラスを指定する（StandardError・Exception・指定なしを使わない）。フォールバックで握りつぶさない
#   6. トランザクションは、参加できる形（ApplicationRecord.transaction）だけで開く
#   7. 外部のサービス・ネットワーク・ファイルを使わない（Net::HTTP・Faraday・File・IO・system・exec・バッククォート）
#
# 使い方（run_all.sh が実行する）:
#   scripts/dc.sh exec -T backend bundle exec ruby - < test/pr45/scan_services.rb
# 終了コード: 0 = 違反なし / 1 = 違反あり
require "ripper"

ROOT = ENV.fetch("ISSUE09_APP_ROOT", "/app")

FILES = (
  %w[ daily_allowance quota_ledger transfer_budget settings_store ].map { |name| "#{ROOT}/app/services/#{name}.rb" } +
  Dir["#{ROOT}/app/services/quota_ledger/*.rb"]
).sort.freeze

JAPANESE = /[\p{Hiragana}\p{Katakana}\p{Han}　-〿＀-￯]/
CLOCK = { "Time" => %w[ now current ], "Date" => %w[ today current ], "DateTime" => %w[ now current ] }.freeze
# 契約の固定値（QuotaPolicy・Contract::Limits・TransferBudgetPolicy の定数の値。数値の直書きを見つけるための一覧）
CONTRACT_NUMBERS = [ 500, 550, 340, 210, 9_000, 10_000, 1_000_000_000 ].freeze
# 行・ファイルを消す呼び出し・外部への入出力。語は、組み立てる
REMOVAL = [ "del" + "ete", "del" + "ete_all", "des" + "troy", "des" + "troy_all", "r" + "m", "un" + "link", "rem" + "ove" ].freeze
FORBIDDEN_CONSTANTS = %w[ Net Faraday HTTParty File FileUtils IO Dir Pathname Open3 Kernel ENV ].freeze
FORBIDDEN_CALLS = %w[ system exec spawn fork ].freeze
SKIPPED = %i[ on_comment on_sp on_nl on_ignored_nl on_embdoc_beg on_embdoc on_embdoc_end ].freeze

def tokens(path)
  Ripper.lex(File.read(path, encoding: "UTF-8")).reject { |_, type, _, _| SKIPPED.include?(type) }
end

def where(path, line)
  "#{path.delete_prefix("#{ROOT}/")}:#{line}"
end

violations = []
FILES.each do |path|
  list = tokens(path)

  list.each do |(line, _), type, text, _|
    violations << "#{where(path, line)}: 日本語の文字列リテラル" if type == :on_tstring_content && text.match?(JAPANESE)
    violations << "#{where(path, line)}: 契約の固定値の直書き（#{text}）" if type == :on_int && CONTRACT_NUMBERS.include?(text.delete("_").to_i)
    violations << "#{where(path, line)}: requires_new" if text.include?("requires_new")
    violations << "#{where(path, line)}: グローバル変数・クラス変数（#{text}）" if %i[ on_gvar on_cvar ].include?(type)
    violations << "#{where(path, line)}: バッククォートによるコマンドの実行" if type == :on_backtick
    violations << "#{where(path, line)}: 呼び出し（#{text}）" if type == :on_ident && FORBIDDEN_CALLS.include?(text)
    violations << "#{where(path, line)}: 外部への入出力・環境の参照（#{text}）" if type == :on_const && FORBIDDEN_CONSTANTS.include?(text)
  end

  list.each_cons(4) do |before, first, second, third|
    next unless first[1] == :on_const && second[1] == :on_period && CLOCK.fetch(first[2], []).include?(third[2])
    next if first[2] == "Time" && third[2] == "current" && before[1] == :on_label && before[2] == "now:"

    violations << "#{where(path, first[0][0])}: 実時計（#{first[2]}.#{third[2]}）"
  end

  list.each_cons(2) do |first, second|
    violations << "#{where(path, second[0][0])}: 消す呼び出し（.#{second[2]}）" if first[1] == :on_period && second[1] == :on_ident && REMOVAL.include?(second[2])
    next unless first[1] == :on_kw && first[2] == "rescue"
    next if second[1] == :on_const && !%w[ StandardError Exception ].include?(second[2])

    violations << "#{where(path, first[0][0])}: 広い rescue（クラスを指定する）"
  end

  list.each_cons(3) do |first, second, third|
    next unless second[1] == :on_period && third[2] == "transaction" && first[1] == :on_const

    violations << "#{where(path, first[0][0])}: 参加できない形のトランザクション（#{first[2]}.transaction）" unless first[2] == "ApplicationRecord"
  end
end

puts "#{FILES.size} ファイルを走査しました（app/services のこの issue のファイルと、QuotaLedger の部品）"
puts "規則: 日本語の文字列リテラル・実時計（now: の既定値を除く）・契約の固定値の直書き・消す呼び出し・requires_new・グローバル変数・広い rescue・参加できないトランザクション・外部への入出力"
if FILES.size < 6
  puts "問題: 走査したファイルが少なすぎます（#{FILES.size} 件）"
  exit 1
end
if violations.empty?
  puts "問題ありません"
  exit 0
end
puts "問題:"
violations.each { |line| puts "  - #{line}" }
exit 1
