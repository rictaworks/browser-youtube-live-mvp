# モデル（app/models）・マイグレーション（db/migrate）・エラーメッセージの初期化子（config/initializers/postgres_error_verbosity.rb）の
# Ruby のソースを、字句解析（Ripper）で走査する（読み取りのみ）。
# コメントは対象外。コードの部分だけを見る。
#
# 実行: backend のコンテナの中の Ruby へ、標準入力で渡す（run_all.sh が行う）。
#   scripts/dc.sh exec -T backend ruby - /app < test/<このディレクトリ>/scan_ruby_sources.rb
# 引数: アプリケーションのルート（既定 /app）。終了コード: 0 = 問題なし / 1 = 問題あり
#
#   1. 日本語の文字列リテラルが無い（利用者に表示する文章は、文言カタログへ分離する。直書きを検知する）
#   2. 実時計を読まない（時刻は引数で受け取る。Time.now・Time.current・Time.zone.now・Date.today・Date.current・DateTime.now・
#      Process.clock_gettime）
#   3. ファイル・ディレクトリを消す呼び出しが無い
#   4. 検出の仕組みの確認（日本語の文字列・実時計・消す呼び出しを含む断片を、必ず検出する）
# 削除系の語は、このファイルにも素のまま書かない（語を組み立てる）。
require "ripper"
require "pathname"

root = Pathname.new(ARGV.fetch(0, "/app"))
files = (Dir[root.join("app/models/**/*.rb").to_s] + Dir[root.join("db/migrate/*.rb").to_s] +
         Dir[root.join("config/initializers/postgres_error_verbosity.rb").to_s]).sort

JAPANESE = /[\p{Hiragana}\p{Katakana}\p{Han}　-〿＀-￯]/
IGNORED_TOKEN_TYPES = %i[ on_comment on_sp on_nl on_ignored_nl on_embdoc_beg on_embdoc on_embdoc_end ].freeze

CLOCK_CALLS = {
  [ "Time", "now" ] => "Time.now",
  [ "Time", "current" ] => "Time.current",
  [ "Date", "today" ] => "Date.today",
  [ "Date", "current" ] => "Date.current",
  [ "DateTime", "now" ] => "DateTime.now",
  [ "DateTime", "current" ] => "DateTime.current"
}.freeze

REMOVAL_RECEIVERS = %w[ File FileUtils Dir Pathname ].freeze
REMOVAL_METHODS = [ "r" + "m", "r" + "m_r", "r" + "m_rf", "r" + "mdir", "rem" + "ove", "rem" + "ove_entry", "del" + "ete", "un" + "link" ].freeze

# 字句（[[行, 桁], 種類, 文字列, 状態]）から、問題の説明の一覧を作る
def scan_tokens(tokens)
  code = tokens.reject { |_, type, _, _| IGNORED_TOKEN_TYPES.include?(type) }
  problems = []

  code.each do |(line, _), type, text, _|
    problems << [ line, "日本語の文字列リテラル（文言カタログへ分離する）" ] if type == :on_tstring_content && text.match?(JAPANESE)
  end

  code.each_cons(3) do |first, second, third|
    next unless first[1] == :on_const && second[1] == :on_period

    clock = CLOCK_CALLS[[ first[2], third[2] ]]
    problems << [ first[0][0], "実時計の参照（#{clock}）。時刻は引数で受け取る" ] if clock
    if REMOVAL_RECEIVERS.include?(first[2]) && REMOVAL_METHODS.include?(third[2])
      problems << [ first[0][0], "ファイル・ディレクトリを消す呼び出し" ]
    end
  end

  code.each_cons(5) do |a, b, c, d, e|
    zone_call = a[2] == "Time" && b[1] == :on_period && c[2] == "zone" && d[1] == :on_period && %w[ now today ].include?(e[2])
    problems << [ a[0][0], "実時計の参照（Time.zone.#{e[2]}）。時刻は引数で受け取る" ] if zone_call
  end

  code.each_cons(3) do |a, b, c|
    problems << [ a[0][0], "実時計の参照（Process.clock_gettime）" ] if a[2] == "Process" && b[1] == :on_period && c[2] == "clock_gettime"
  end

  problems
end

found = []
files.each do |path|
  scan_tokens(Ripper.lex(File.read(path, encoding: "UTF-8"))).each do |line, message|
    found << "#{Pathname.new(path).relative_path_from(root)}:#{line}: #{message}"
  end
end

# 検出の仕組みの確認。次の断片は、すべての種類の問題を含む（日本語の文字は、コードポイントから作る）
japanese_text = [ 0x65E5, 0x672C, 0x8A9E ].pack("U*")
removal_call = "File." + "del" + "ete('x')"
sample = <<~RUBY
  label = "#{japanese_text}"
  now = Time.now
  zoned = Time.zone.now
  #{removal_call}
  # コメントの日本語と Time.now は、検出しない
RUBY
sample_messages = scan_tokens(Ripper.lex(sample)).map(&:last)
detection_ok =
  sample_messages.any? { |m| m.start_with?("日本語") } &&
  sample_messages.any? { |m| m.include?("Time.now") } &&
  sample_messages.any? { |m| m.include?("Time.zone.now") } &&
  sample_messages.any? { |m| m.start_with?("ファイル") } &&
  scan_tokens(Ripper.lex("# #{japanese_text} Time.now\nx = 1\n")).empty?

puts "走査したファイル #{files.size} 件（モデル・マイグレーション・エラーメッセージの初期化子）"
puts "検出の仕組みの確認: #{detection_ok ? 'ok' : 'FAIL'}"

problems = []
problems << "走査したファイルが少なすぎる（#{files.size} 件。モデル 17 ファイル・マイグレーション 16 ファイル・初期化子 1 ファイルが対象）" if files.size < 34
problems << "検出の仕組みが働かない（走査器の不具合）" unless detection_ok
problems.concat(found)

if problems.empty?
  puts "問題ありません"
  exit 0
end

puts "問題:"
problems.each { |problem| puts "  - #{problem}" }
exit 1
