# issue #6（配信の生命周期の Domain Core）のソースが、Domain Core の規則を守っていることを確かめる（読み取りのみ）。
#
# backend のコンテナの中で、標準入力から実行する（test/pr41/run_all.sh が呼ぶ）。
#   scripts/dc.sh exec -T backend bundle exec ruby - < test/pr41/check_domain_purity.rb
#
# 検査（ソースの字句を、Ripper で検査する。コメントは対象にしない。検査器は spec/domain/lifecycle/support/domain_source_scanner.rb）
#   * 入出力の型（Rails・ActiveRecord・ActionController・ENV・File など）と、実時計（Time.now など）を参照しない
#   * 他の issue の Domain Core（#5）に依存しない
#   * グローバル変数・クラス変数を使わない
#   * 期限・間隔・回数の数値、状態・終了理由・清算状態・配信の出来事の符号を直書きしない（契約から取る）
#   * 文字列リテラルは ASCII だけ（画面に出す文言を持たない）
#   * 読み込みは require "date" だけ
# あわせて、Zeitwerk の規則（app/domain が autoload のルート。ファイル名と定数名の対応）で、各ファイルの定数が解決できること。
require "zeitwerk"

DOMAIN_DIR = "/app/app/domain".freeze
SCANNER = "/app/spec/domain/lifecycle/support/domain_source_scanner.rb".freeze

abort "FAIL #{SCANNER} がありません" unless File.exist?(SCANNER)

loader = Zeitwerk::Loader.new
loader.push_dir(DOMAIN_DIR)
loader.setup
require SCANNER

failures = 0
lines = 0

DomainSourceScanner::LIFECYCLE_FILES.each do |name|
  path = File.join(DOMAIN_DIR, "#{name}.rb")
  unless File.exist?(path)
    puts "FAIL #{name}.rb: ファイルがありません"
    failures += 1
    next
  end

  constant = name.split("_").map(&:capitalize).join
  begin
    Object.const_get(constant)
  rescue NameError => error
    puts "FAIL #{name}.rb: Zeitwerk の規則で #{constant} を解決できません（#{error.message}）"
    failures += 1
    next
  end

  source = File.read(path)
  lines += source.lines.size
  violations = DomainSourceScanner.violations(path)
  magic = source.lines.first(3).join.include?("# frozen_string_literal: true")

  if violations.empty? && magic
    puts "PASS #{name}.rb（#{source.lines.size} 行）"
  else
    failures += 1
    puts "FAIL #{name}.rb"
    violations.each { |kind, line, text| puts "  - #{line} 行目: #{kind}: #{text}" }
    puts "  - frozen_string_literal のマジックコメントがありません" unless magic
  end
end

puts
puts "検査したファイル: #{DomainSourceScanner::LIFECYCLE_FILES.size}・#{lines} 行"
if failures.zero?
  puts "PASS Domain Core の規則（入出力・実時計・#5 への依存・数値と符号の直書き・日本語の文字列・グローバル変数）に、違反はありません"
  exit 0
end
puts "FAIL 違反があります（#{failures} ファイル）"
exit 1
