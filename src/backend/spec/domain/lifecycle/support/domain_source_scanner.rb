# frozen_string_literal: true

require "ripper"

# 配信の生命周期の Domain Core（issue #6 のファイル）の、ソースの検査器。Ripper で、コメント・空白を除いたコードの字句を検査する
# （コメントの説明文は、検査の対象にしない）。rspec（lifecycle_purity_spec.rb）と、システムテスト
# （test/pr<番号>/check_domain_purity.rb）が使う。Domain Core の定数は、メソッドの中で参照する。
#
# 検知するもの（違反は [種別, 行, 字句]）
#   forbidden_constant    入出力・環境・実行基盤の型（Rails・ActiveRecord・ActiveSupport・ActionController・ENV・File など）
#   other_issue_constant  他の issue の Domain Core（#5 の UsageCalendar など。この issue は #5 に依存しない）
#   real_clock            実時計（Time.now・Time.current・Date.today・DateTime.now・Process.clock_gettime）
#   global_variable       グローバル変数      class_variable  クラス変数（状態を持たない）
#   integer_literal       整数の直書き（0・1 を除く。期限・間隔・回数は、契約から取る）。単位の換算のファイルだけは許す
#   float_literal         小数の直書き
#   non_ascii_literal     ASCII 以外の文字列リテラル・識別子（画面に出す文言を持たない。日本語はコメントだけ）
#   contract_value_literal 契約の値（状態・清算状態・終了理由・配信の出来事の種別）の文字列の直書き（契約の定数を使う）
#   require               標準ライブラリ以外（許可は require "date" だけ）の読み込み
module DomainSourceScanner
  # issue #6 の Domain Core のファイル（app/domain の直下。拡張子なし）
  LIFECYCLE_FILES = %w[
    lifecycle_checks
    lifecycle_time_units
    directive
    broadcast_snapshot
    broadcast_state_machine
    termination_planner
    deadline_evaluator
    settlement_rules
    prior_settlement_check
    stream_replacement_policy
    retention_policy
  ].freeze

  FORBIDDEN_CONSTANTS = %w[
    Rails ActiveRecord ActiveSupport ActionController ActionDispatch ApplicationRecord ENV
    File Dir IO Net Socket Logger Thread Mutex Random SecureRandom
  ].freeze

  # #5 の Domain Core。この issue は #5 に依存しない
  OTHER_ISSUE_CONSTANTS = %w[
    UsageCalendar StartAdmission QuotaPolicy TransferBudgetPolicy Settings AccountSnapshot Preconditions
  ].freeze

  # 定数 => 実時計を読む呼び出し
  REAL_CLOCK_CALLS = {
    "Time" => %w[now current],
    "Date" => %w[today current],
    "DateTime" => %w[now current],
    "Process" => %w[clock_gettime]
  }.freeze

  ALLOWED_INTEGERS = %w[0 1].freeze

  # 単位の換算（分・日 → 秒）を持つファイル。整数の直書きを許す
  INTEGER_EXEMPT_FILES = %w[lifecycle_time_units].freeze

  ALLOWED_REQUIRES = %w[date].freeze

  # ファイル => 契約の値と同じ綴りでも、別の語彙の値として許す文字列。
  # settlement_rules: YouTube の lifeCycleStatus の live（契約の配信の状態 live とは別の語彙）
  CONTRACT_LITERAL_ALLOWANCES = { "settlement_rules" => %w[live] }.freeze

  IGNORED_TOKEN_TYPES = %i[on_comment on_sp on_nl on_ignored_nl on_embdoc_beg on_embdoc on_embdoc_end].freeze
  IDENTIFIER_TOKEN_TYPES = %i[on_ident on_const on_label on_ivar].freeze

  module_function

  # ファイルの違反の一覧。
  def violations(path)
    violations_in_source(File.read(path), name: File.basename(path, ".rb"))
  end

  # ソースの違反の一覧 [種別, 行, 字句]。name は、ファイル名（拡張子なし。許可の判定に使う）。
  def violations_in_source(source, name:)
    tokens = significant_tokens(source)
    found = []
    found.concat(constant_violations(tokens))
    found.concat(real_clock_violations(tokens))
    found.concat(variable_violations(tokens))
    found.concat(number_violations(tokens, name))
    found.concat(literal_violations(tokens, name))
    found.concat(require_violations(tokens))
    found.sort_by { |_kind, line, _text| line }
  end

  # コメントを除いたコードの字句を、空白で連結した文字列。
  def code_of(source)
    significant_tokens(source).map { |token| token[2] }.join(" ")
  end

  def significant_tokens(source)
    Ripper.lex(source).reject { |(_position, type, _text, _state)| IGNORED_TOKEN_TYPES.include?(type) }
  end

  def constant_violations(tokens)
    tokens.filter_map do |(position, type, text, _state)|
      next unless type == :on_const

      if FORBIDDEN_CONSTANTS.include?(text)
        [ :forbidden_constant, position.first, text ]
      elsif OTHER_ISSUE_CONSTANTS.include?(text)
        [ :other_issue_constant, position.first, text ]
      end
    end
  end

  def real_clock_violations(tokens)
    tokens.each_cons(3).filter_map do |(position, type, receiver, _), (_, _, separator, _), (_, _, method_name, _)|
      next unless type == :on_const && %w[. ::].include?(separator)
      next unless REAL_CLOCK_CALLS.fetch(receiver, []).include?(method_name)

      [ :real_clock, position.first, "#{receiver}#{separator}#{method_name}" ]
    end
  end

  def variable_violations(tokens)
    tokens.filter_map do |(position, type, text, _state)|
      case type
      when :on_gvar then [ :global_variable, position.first, text ]
      when :on_cvar then [ :class_variable, position.first, text ]
      end
    end
  end

  def number_violations(tokens, name)
    tokens.filter_map do |(position, type, text, _state)|
      if type == :on_int && !INTEGER_EXEMPT_FILES.include?(name) && !ALLOWED_INTEGERS.include?(text.delete("_"))
        [ :integer_literal, position.first, text ]
      elsif type == :on_float
        [ :float_literal, position.first, text ]
      end
    end
  end

  def literal_violations(tokens, name)
    allowed = CONTRACT_LITERAL_ALLOWANCES.fetch(name, [])
    tokens.filter_map do |(position, type, text, _state)|
      if (type == :on_tstring_content || IDENTIFIER_TOKEN_TYPES.include?(type)) && !text.ascii_only?
        [ :non_ascii_literal, position.first, text ]
      elsif type == :on_tstring_content && contract_values.include?(text) && !allowed.include?(text)
        [ :contract_value_literal, position.first, text ]
      end
    end
  end

  # require は、許可した標準ライブラリ（date）だけ。require_relative・load・autoload は、常に違反
  def require_violations(tokens)
    tokens.each_with_index.filter_map do |(position, type, text, _state), index|
      next unless type == :on_ident

      line = position.first
      if %w[require_relative load autoload].include?(text)
        [ :require, line, text ]
      elsif text == "require" && !ALLOWED_REQUIRES.include?(tokens.dig(index + 2, 2))
        [ :require, line, "require #{tokens.dig(index + 2, 2)}" ]
      end
    end
  end

  # 契約の値（状態・清算状態・終了理由・配信の出来事の種別）。直書きを検知する対象
  def contract_values
    [
      Contract::BroadcastState::ALL, Contract::SettlementState::ALL,
      Contract::EndReason::ALL, Contract::BroadcastEventType::ALL
    ].flatten.uniq
  end
end
