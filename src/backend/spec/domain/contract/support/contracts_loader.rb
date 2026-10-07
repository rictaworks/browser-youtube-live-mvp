require "json"
require "zeitwerk"

# 契約（src/contracts）のスペックの共通部品。
#
# このディレクトリのスペックは、spec_helper だけを読み込み、Rails を起動せず、DB へ接続しない
# （scripts/test_backend.sh --no-db spec/domain/contract）。
# Contract の定数は、app/domain を autoload のルートとする Zeitwerk の規則（ファイルのパスと定数名の対応）で読み込む。
# require_relative で個々のファイルを読み込むと、規則に反するファイル（名前の誤り）を見逃すため、使わない。
module ContractSpecSupport
  # 契約のディレクトリの目印のファイル
  MARKER_FILE = "enums.json".freeze

  # 契約の JSON にある、文書用のキー（$comment・note・*_note）。定数モジュールへは複製しない。
  DOCUMENT_KEY = /\A(\$comment|note|.+_note)\z/

  # requirements.md 20.4（マスタデータ件数）の 17 区分の件数。表の順。
  REQUIREMENTS_20_4_COUNTS = {
    "source_kind" => 5,
    "layout" => 4,
    "profile" => 2,
    "broadcast_state" => 6,
    "settlement_state" => 4,
    "end_reason" => 13,
    "rejection_reason" => 14,
    "youtube_connection_state" => 4,
    "studio_state" => 10,
    "source_state" => 5,
    "ws_message_type" => 14,
    "internal_call" => 4,
    "broadcast_event_type" => 24,
    "usage_event_type" => 20,
    "setting_key" => 9,
    "adaptive_condition" => 7,
    "color_role" => 12
  }.freeze

  # 契約独自の 7 区分の件数（設計メモ）
  CONTRACT_ONLY_COUNTS = {
    "fatal_code" => 10,
    "relay_event_kind" => 6,
    "interrupt_cause" => 4,
    "browser_event_kind" => 8,
    "connect_result" => 6,
    "login_error" => 2,
    "resolution" => 11
  }.freeze

  # 値を、Ruby の定数名へ直すときの、例外。数字で始まる値と、予約語（END）。ほかは、大文字にするだけ。
  CONSTANT_NAME_OVERRIDES = {
    "720p" => "P720",
    "480p" => "P480",
    "end" => "END_"
  }.freeze

  # 契約のディレクトリが見つからないときのエラー。黙ってスキップせず、探した場所を並べて失敗する。
  class ContractsNotFound < StandardError; end

  module_function

  # 契約のディレクトリの候補を、探す順に返す。
  #   1. /contracts          docker compose のマウント（読み取り専用）
  #   2. <cwd>/../contracts  CI のチェックアウト（作業ディレクトリが src/<層>）
  #   3. <cwd>/../../contracts
  #   4. このファイルから src/contracts へ上る相対パス（作業ディレクトリに依らない）
  # 同じ場所を指す候補は、最初の 1 つだけを残す。
  def candidate_dirs(cwd: Dir.pwd, here: __dir__)
    [
      "/contracts",
      File.expand_path("../contracts", cwd),
      File.expand_path("../../contracts", cwd),
      File.expand_path("../../../../../contracts", here)
    ].uniq
  end

  # 候補を順に探し、最初に見つかったディレクトリを返す。1 つも無ければ ContractsNotFound。
  # marker_exists は、ファイルシステムを使わずに試すための差し替え口。
  def locate_contracts_dir(candidates: candidate_dirs, marker_exists: ->(dir) { File.exist?(File.join(dir, MARKER_FILE)) })
    found = candidates.find { |dir| marker_exists.call(dir) }
    return found if found

    lines = candidates.map { |dir| "  - #{dir}（#{MARKER_FILE} が無い）" }
    raise ContractsNotFound, [
      "契約のディレクトリ（src/contracts）が見つかりません。黙ってスキップせず、失敗します。",
      "探した場所（この順）:",
      *lines,
      "対処: docker compose の環境では scripts/test_backend.sh を使ってください（/contracts へ読み取り専用でマウントされます）。",
      "CI では、リポジトリをチェックアウトしたうえで、src/backend を作業ディレクトリにして実行してください（../contracts が src/contracts になります）。"
    ].join("\n")
  end

  # 契約の JSON を読む。
  def load_json(name, dir: locate_contracts_dir)
    JSON.parse(File.read(File.join(dir, name), encoding: "UTF-8"))
  end

  # 文書用のキー（$comment・note・*_note）を、再帰的に取り除いた複製を返す。
  def strip_document_keys(value)
    case value
    when Hash
      value.reject { |key, _| DOCUMENT_KEY.match?(key) }.transform_values { |child| strip_document_keys(child) }
    when Array
      value.map { |child| strip_document_keys(child) }
    else
      value
    end
  end

  # 型まで含めて等しいか（Integer の 60 と Float の 60.0 を区別する）。Hash・Array は再帰する。
  def same_value?(actual, expected)
    case expected
    when Hash
      actual.is_a?(Hash) && actual.keys.sort == expected.keys.sort &&
        expected.all? { |key, child| same_value?(actual[key], child) }
    when Array
      actual.is_a?(Array) && actual.size == expected.size &&
        actual.zip(expected).all? { |a, e| same_value?(a, e) }
    else
      actual.instance_of?(expected.class) && actual == expected
    end
  end

  # 列挙の名前（snake_case）から、Zeitwerk の規則での定数名（Contract::<ここ>）へ。
  def module_name_for(enum_name)
    enum_name.split("_").map(&:capitalize).join
  end

  # 値から、値ごとの定数の名前へ。
  def constant_name_for(value)
    CONSTANT_NAME_OVERRIDES.fetch(value) { value.upcase }
  end

  # app/domain のディレクトリ
  def domain_dir
    File.expand_path("../../../../app/domain", __dir__)
  end

  # app/domain/contract のディレクトリ
  def contract_dir
    File.join(domain_dir, "contract")
  end

  # Contract を、app/domain をルートとする Zeitwerk の規則で読み込む（Rails を使わない）。
  #   - 同じプロセスで、Rails がすでに app/domain を管理しているとき（rails_helper を読むスペックと一緒に実行したとき）は、
  #     その Rails のローダーが Contract を autoload する。ここでは何もしない。
  #   - そうでなければ、素の Zeitwerk のローダーを作る。app/domain の中の、contract 以外（別の作業中のファイル）は、
  #     読み込み対象から外す。eager_load は、ファイルが、規則どおりの定数を定義していないとき（名前の誤り）に、例外にする。
  # ローダーは、プロセスで 1 つだけ作る。
  def load_contract_namespace!
    return :rails if Zeitwerk::Loader.all_dirs.include?(domain_dir)
    return :zeitwerk if defined?(@zeitwerk_loader) && @zeitwerk_loader

    loader = Zeitwerk::Loader.new
    loader.push_dir(domain_dir)
    Dir.children(domain_dir).each do |entry|
      loader.ignore(File.join(domain_dir, entry)) unless entry == "contract"
    end
    loader.setup
    loader.eager_load
    @zeitwerk_loader = loader
    :zeitwerk
  end
end
