require "rails_helper"
require "support/model_support"
require "ripper"

# 利用枠・割り当て台帳・転送量・設定（issue #9）のサービスのソースの検査。コメントは対象外（字句解析で、コードの部分だけを見る）。
# 対象は、このサービスのファイルだけ（app/services には、ほかの issue のファイルも入る）。
#   1. 日本語の文字列リテラルが無い（利用者に表示する文章・設定値は、コードに直書きしない。例外のメッセージ・ログは、ASCII）
#   2. 実時計を読まない。ただし、呼び出しの時刻の既定（now: Time.current）だけは許す（テストでは、時刻を引数で渡す）
#   3. 契約の固定値（予約額 550・準備・確認枠 340・終了・清算枠 210・共通枠 500・配信に使える上限 9,000・1 日の割り当て 10,000・1 GB）を、
#      数値で直書きしない（QuotaPolicy・Contract::Limits の定数を使う）
#   4. ファイルを消す呼び出しも、行を消す呼び出しも無い（サービスは、行を消さない。台帳は、記帳で増え、解放で減る）
#   5. requires_new を使わない（呼び出し側のトランザクションに参加する。SAVEPOINT を作らない）
#   6. グローバル変数・クラス変数が無い
#   7. 例外を握りつぶさない: rescue は、クラスを指定し、StandardError・Exception を指定しない
# 削除系の語は、このファイルにも素のまま書かない（語を組み立てる）。
RSpec.describe "利用枠・割り当て台帳・転送量・設定のサービスのソース" do
  files = (
    %w[ daily_allowance quota_ledger transfer_budget settings_store ].map { |name| Rails.root.join("app/services/#{name}.rb").to_s } +
    Dir[Rails.root.join("app/services/quota_ledger/*.rb").to_s]
  ).sort

  # 日本語の文字（ひらがな・カタカナ・漢字・全角の記号・半角カナ）
  japanese = /[\p{Hiragana}\p{Katakana}\p{Han}　-〿＀-￯]/

  clock_receivers = { "Time" => %w[ now current ], "Date" => %w[ today current ], "DateTime" => %w[ now current ] }

  # 契約の固定値（数値）。QuotaPolicy・Contract::Limits から得る（このスペックにも、直書きしない）
  contract_numbers = (
    Contract::Limits::QUOTA.values.grep(Integer) +
    [ Contract::Limits::SETTING_DEFAULTS.fetch("daily_quota_units"), TransferBudgetPolicy::BYTES_PER_GB ]
  ).select { |value| value >= 100 }.uniq

  # 行・ファイルを消す呼び出しの名前。語は、組み立てる
  removal_names = [ "del" + "ete", "del" + "ete_all", "des" + "troy", "des" + "troy_all", "r" + "m", "un" + "link", "rem" + "ove" ]
  removal_receivers = %w[ File FileUtils Dir Pathname ]

  ignored_token_types = %i[ on_comment on_sp on_nl on_ignored_nl on_embdoc_beg on_embdoc on_embdoc_end ]

  # コメント・空白を除いた字句（[[行, 桁], 種類, 文字列, 状態]）
  tokens_of = lambda do |source|
    Ripper.lex(source).reject { |_, type, _, _| ignored_token_types.include?(type) }
  end

  code_tokens = ->(path) { tokens_of.call(File.read(path, encoding: "UTF-8")) }
  relative = ->(path) { Pathname.new(path).relative_path_from(Rails.root).to_s }

  # 実時計の呼び出し（レシーバ.メソッド）の位置。Time.current が、now: の既定値の位置にあるものは、許す
  clock_calls = lambda do |tokens|
    tokens.each_cons(4).filter_map do |before, first, second, third|
      next unless first[1] == :on_const && second[1] == :on_period && clock_receivers.fetch(first[2], []).include?(third[2])
      next if first[2] == "Time" && third[2] == "current" && before[1] == :on_label && before[2] == "now:"

      [ first[0][0], "#{first[2]}.#{third[2]}" ]
    end
  end

  # 日本語の文字列リテラルの位置
  japanese_literals = lambda do |tokens|
    tokens.filter_map { |(line, _), type, text, _| line if type == :on_tstring_content && text.match?(japanese) }
  end

  # 契約の固定値の数値リテラルの位置（1_000 のような区切りも、数値として比べる）
  contract_literals = lambda do |tokens|
    tokens.filter_map { |(line, _), type, text, _| line if type == :on_int && contract_numbers.include?(text.delete("_").to_i) }
  end

  # 行・ファイルを消す呼び出し（.名前）の位置
  removal_calls = lambda do |tokens|
    tokens.each_cons(2).filter_map do |first, second|
      next unless first[1] == :on_period && second[1] == :on_ident && removal_names.include?(second[2])

      second[0][0]
    end
  end

  # rescue のあとに、クラスが無い・StandardError・Exception が続く位置
  broad_rescues = lambda do |tokens|
    tokens.each_cons(2).filter_map do |first, second|
      next unless first[1] == :on_kw && first[2] == "rescue"
      next if second[1] == :on_const && !%w[ StandardError Exception ].include?(second[2])

      first[0][0]
    end
  end

  it "検査の対象が、空ではない（4 つのサービスと、QuotaLedger の部品）" do
    expect(files.size).to be >= 6
    expect(files.map { |path| File.basename(path) }).to include("daily_allowance.rb", "quota_ledger.rb", "transfer_budget.rb", "settings_store.rb", "rows.rb", "arguments.rb")
    expect(files).to all(satisfy { |path| File.file?(path) })
  end

  it "文字列リテラルに、日本語が無い（利用者に表示する文章・設定値を、コードに直書きしない）" do
    found = files.flat_map { |path| japanese_literals.call(code_tokens.call(path)).map { |line| "#{relative.call(path)}:#{line}" } }

    expect(found).to be_empty, "日本語の文字列リテラルがある（文言カタログへ分離してください）:\n#{found.join("\n")}"
  end

  it "実時計（Time.now・Date.today・Date.current・DateTime.now・Time.current）を読まない。ただし、now: の既定値の Time.current だけは許す" do
    found = files.flat_map { |path| clock_calls.call(code_tokens.call(path)).map { |line, call| "#{relative.call(path)}:#{line}: #{call}" } }

    expect(found).to be_empty, "実時計を読んでいる（時刻は引数で受け取る）:\n#{found.join("\n")}"
  end

  it "now: の既定値の Time.current は、呼び出しの時刻を受け取るメソッド（spend!・spend_common!）の 2 か所だけにある" do
    defaults = files.to_h do |path|
      count = code_tokens.call(path).each_cons(4).count do |label, receiver, period, name|
        label[1] == :on_label && label[2] == "now:" && receiver[2] == "Time" && period[1] == :on_period && name[2] == "current"
      end
      [ File.basename(path), count ]
    end

    expect(defaults.reject { |_, count| count.zero? }).to eq("quota_ledger.rb" => 2)
  end

  it "契約の固定値（550・340・210・500・9,000・10,000・1 GB）を、数値で直書きしない" do
    found = files.flat_map { |path| contract_literals.call(code_tokens.call(path)).map { |line| "#{relative.call(path)}:#{line}" } }

    expect(found).to be_empty, "契約の固定値を直書きしている（QuotaPolicy・Contract::Limits の定数を使う）:\n#{found.join("\n")}"
  end

  it "ファイルを消す呼び出しも、行を消す呼び出しも無い（サービスは、行を消さない）" do
    found = files.flat_map { |path| removal_calls.call(code_tokens.call(path)).map { |line| "#{relative.call(path)}:#{line}" } }

    expect(found).to be_empty, "消す呼び出しがある:\n#{found.join("\n")}"
  end

  it "requires_new を使わない（呼び出し側のトランザクションに参加する。SAVEPOINT を作らない）" do
    found = files.flat_map do |path|
      code_tokens.call(path).filter_map { |(line, _), type, text, _| "#{relative.call(path)}:#{line}" if text.include?("requires_new") && type != :on_comment }
    end

    expect(found).to be_empty
  end

  it "グローバル変数・クラス変数が無い" do
    found = files.flat_map do |path|
      code_tokens.call(path).filter_map { |(line, _), type, _, _| "#{relative.call(path)}:#{line}" if %i[ on_gvar on_cvar ].include?(type) }
    end

    expect(found).to be_empty
  end

  it "例外を握りつぶさない: rescue は、クラスを指定し、StandardError・Exception を指定しない" do
    found = files.flat_map { |path| broad_rescues.call(code_tokens.call(path)).map { |line| "#{relative.call(path)}:#{line}" } }

    expect(found).to be_empty, "広い rescue がある:\n#{found.join("\n")}"
  end

  it "どのサービスも、トランザクションは ApplicationRecord.transaction（参加できる形）で開く" do
    offenders = files.select do |path|
      source = File.read(path, encoding: "UTF-8").lines.reject { |line| line.strip.start_with?("#") }.join
      source.scan(/(\w+(?:::\w+)*)\.transaction\b/).flatten.any? { |receiver| receiver != "ApplicationRecord" }
    end

    expect(offenders.map { |path| relative.call(path) }).to be_empty
  end

  describe "検出の仕組みが働く（断片で確かめる）" do
    it "日本語の文字列リテラル・実時計・契約の固定値・消す呼び出し・広い rescue・now: の既定値の例外を、区別して検出する" do
      source = <<~RUBY
        a = "#{[ 0x65E5, 0x672C ].pack('U*')}"
        b = Time.now
        c = Date.today
        d = Time.current
        e = 550
        f = 1_000_000_000
        g = record.#{removal_names.first}
        begin
          1
        rescue => error
          2
        end
        begin
          1
        rescue StandardError
          2
        end
        begin
          1
        rescue ArgumentError
          2
        end
        def ok(now: Time.current)
        end
      RUBY
      tokens = tokens_of.call(source)

      expect(japanese_literals.call(tokens)).to eq([ 1 ])
      expect(clock_calls.call(tokens).map(&:last)).to contain_exactly("Time.now", "Date.today", "Time.current")
      expect(contract_literals.call(tokens)).to eq([ 5, 6 ])
      expect(removal_calls.call(tokens)).to eq([ 7 ])
      expect(broad_rescues.call(tokens)).to eq([ 10, 15 ])
    end
  end
end
