require "ripper"

# Domain Core（app/domain）の規則を、ソースの字句（Ripper）で検査する。
#
# 検査の対象は、コードだけ。コメントと、文字列リテラルの内容（説明・例外のメッセージ）は、検査しない
# （ただし、文字列リテラルは、非 ASCII を含まないこと。利用者が読む文章をコードへ直書きしないため）。
#
# 規則（requirements.md 2.5・15 章・27 章。CLAUDE.md の不変条件）
#   forbidden_constant         入出力・環境の型（Rails・ActiveRecord・ENV・File・Net など）を参照しない
#   wall_clock                 実時計（Time.now・Date.today・Time.current など）を呼ばない。時刻は引数で受け取る
#   global_variable            グローバル変数（$stdout など）を使わない
#   class_variable             クラス変数（@@x）を使わない
#   forbidden_call             出力（puts など）・乱数（rand）・待機（sleep）を呼ばない（副作用・非決定性）
#   non_ascii_literal          文字列リテラルに非 ASCII（日本語の文章）を書かない（文言は文言カタログ。契約の符号は ASCII）
#   non_ascii_identifier       識別子（変数・メソッド・定数）に非 ASCII を使わない
#   require_not_allowed        require は date・time・tzinfo だけ。require_relative・load・autoload は使わない（読み込みは Zeitwerk）
#   contract_number_literal    契約の固定値（500・550・340・210・9,000・10,000）を、数値で直書きしない（契約の定数モジュールから使う）。
#                              契約の定数モジュール（app/domain/contract）は、対象外
module DomainRules
  Violation = Data.define(:rule, :line, :excerpt)

  FORBIDDEN_CONSTANTS = %w[
    Rails ActiveRecord ActiveSupport ActiveModel ActiveJob ActionController ActionDispatch ActionView
    ApplicationRecord ApplicationController Rack ENV File Dir IO Net Socket Logger Random SecureRandom
  ].freeze

  FORBIDDEN_CALLS = %w[puts print pp warn printf putc rand srand sleep].freeze

  ALLOWED_REQUIRES = %w[date time tzinfo].freeze

  CONTRACT_NUMBERS = [ 500, 550, 340, 210, 9_000, 10_000 ].freeze

  WALL_CLOCK = Regexp.union(
    /\b(?:Time|DateTime)\s*\.\s*now\b/,
    /\bTime\s*\.\s*current\b/,
    /\bDate\s*\.\s*(?:today|current)\b/,
    /\bProcess\s*\.\s*clock_gettime\b/,
    /\bTime\s*\.\s*zone\b/,
    /\bTime\s*\.\s*new\s*\(\s*\)/,
    /\bTime\s*\.\s*new\b(?!\s*\()/
  )

  module_function

  # source（Ruby のソース）の規則違反（Violation の配列）。contract: true は、契約の定数モジュール（数値の直書きを許す）。
  def violations(source, contract: false)
    found = []
    code = +""
    pending_require = nil

    Ripper.lex(source).each do |(line, _column), type, text, _state|
      case type
      when :on_comment, :on_embdoc_beg, :on_embdoc, :on_embdoc_end
        code << ("\n" * text.count("\n"))
      when :on_tstring_content
        found << Violation.new(:non_ascii_literal, line, text[0, 30]) unless text.ascii_only?
        found << Violation.new(:require_not_allowed, line, text[0, 30]) if pending_require == "require" && !ALLOWED_REQUIRES.include?(text)
        pending_require = nil
        code << ("\n" * text.count("\n"))
      else
        code << text
        pending_require = check_token(found, type, text, line, contract, pending_require)
      end
    end

    found + wall_clock_violations(code)
  end

  # ファイルのパスの規則違反。app/domain/contract の下は、契約の定数モジュール。
  def violations_in_file(path)
    violations(File.read(path, encoding: "UTF-8"), contract: path.include?("/app/domain/contract/"))
  end

  # 1 トークンの検査。require の直後の文字列（読み込む名前）を検査するため、require の状態（nil または "require"）を返す。
  def check_token(found, type, text, line, contract, pending_require)
    case type
    when :on_const
      found << Violation.new(:forbidden_constant, line, text) if FORBIDDEN_CONSTANTS.include?(text)
      found << Violation.new(:non_ascii_identifier, line, text) unless text.ascii_only?
    when :on_ident
      found << Violation.new(:forbidden_call, line, text) if FORBIDDEN_CALLS.include?(text)
      found << Violation.new(:non_ascii_identifier, line, text) unless text.ascii_only?
      found << Violation.new(:require_not_allowed, line, text) if %w[require_relative load autoload].include?(text)
      return "require" if text == "require"
    when :on_gvar
      found << Violation.new(:global_variable, line, text)
    when :on_cvar
      found << Violation.new(:class_variable, line, text)
    when :on_int
      found << Violation.new(:contract_number_literal, line, text) if !contract && CONTRACT_NUMBERS.include?(text.delete("_").to_i)
    when :on_label
      found << Violation.new(:non_ascii_identifier, line, text) unless text.ascii_only?
    end
    # require の引数は、空白・括弧・引用符の開きを挟んで、文字列の内容が来る。それ以外のトークンが来たら、状態を解除する
    %i[on_sp on_lparen on_tstring_beg].include?(type) ? pending_require : nil
  end
  private_class_method :check_token

  def wall_clock_violations(code)
    matches = []
    code.scan(WALL_CLOCK) do
      match = Regexp.last_match
      matches << Violation.new(:wall_clock, code[0...match.begin(0)].count("\n") + 1, match[0])
    end
    matches
  end
  private_class_method :wall_clock_violations
end
