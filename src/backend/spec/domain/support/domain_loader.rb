require "zeitwerk"

# Domain Core（app/domain）のスペックの共通部品。
#
# Rails を起動しないスペック（spec_helper だけを読み込むもの）が、Zeitwerk の規則
# （app/domain が autoload のルート。ファイルのパスと定数名の対応）で、Domain Core を読み込めるようにする。
# 後続の issue（#6 以降）のスペックも、同じ補助を使う。
# spec/domain/contract/support/contracts_loader.rb は、#3 の契約（Contract）だけを読み込む別の補助で、変更しない。
#
# 使い方: スペックの先頭に次の 2 行を書く（support への相対パスは、スペックの置き場所に合わせる）。
#
#   require "spec_helper"
#   require_relative "support/domain_loader"
#
# ローダーの設定は、スイートの開始時（before(:suite)）に 1 回だけ行う。
#   - before(:suite) は、すべてのスペックのファイルを読み込んだ後に動く。Rails を起動するスペック（rails_helper）が
#     同じ実行に含まれていても、Rails が先に app/domain を管理し、ここは何もしない（同じディレクトリを 2 つのローダーが
#     管理すると Zeitwerk が失敗するため、Rails のローダーを優先する）。
#   - 契約のスペックの補助（ContractSpecSupport.load_contract_namespace!）は、example group の before(:all) で動くので、
#     ここが先に app/domain を管理し、契約のスペックの補助は何もしない（逆順だと、app/domain の contract 以外が読み込まれない）。
#   - そのため、スペックのファイルの読み込み中（describe の本体）では、Domain Core の定数を参照しない。
#     it・let・before の中で参照する（表は、符号の文字列などの値で書く）。
module DomainLoader
  # app/domain の定数を、ローダーが解決できないときのエラー。黙って通さず、原因の候補を並べて失敗する。
  class NotLoadable < StandardError; end

  module_function

  # app/domain のディレクトリ
  def domain_dir
    File.expand_path("../../../app/domain", __dir__)
  end

  # ローダーの設定の方針を返す（副作用なし）。
  #   :ready   このプロセスで、すでにローダーを作ってある
  #   :rails   別のローダー（Rails の autoloader）が、app/domain を管理している。何もしない
  #   :create  どのローダーも管理していない。素の Zeitwerk のローダーを作る
  def strategy(own_loader:, managed_dirs:, dir: domain_dir)
    return :ready if own_loader
    return :rails if managed_dirs.include?(dir)

    :create
  end

  # app/domain の直下のファイル・ディレクトリに対応する、Zeitwerk の規則での定数名（トップレベル）。
  # Ruby のファイルを含まないディレクトリは、Zeitwerk が読み込み対象にしないので、含めない。
  def expected_constants(dir: domain_dir)
    inflector = Zeitwerk::Inflector.new

    Dir.children(dir).sort.filter_map do |entry|
      path = File.join(dir, entry)
      if File.file?(path) && entry.end_with?(".rb")
        inflector.camelize(File.basename(entry, ".rb"), path)
      elsif File.directory?(path) && Dir.glob(File.join(path, "**", "*.rb")).any?
        inflector.camelize(entry, path)
      end
    end
  end

  # app/domain の直下の定数が、すべて解決できること。解決できないときは NotLoadable。
  # resolvable は、定数名（文字列）が解決できるかを返す。ファイルシステム・ローダーを使わずに試すための差し替え口。
  def verify!(dir: domain_dir, resolvable: ->(name) { Object.const_defined?(name) })
    missing = expected_constants(dir: dir).reject { |name| resolvable.call(name) }
    return if missing.empty?

    raise NotLoadable, [
      "app/domain の次の定数を、ローダーが解決できません（#{dir}）: #{missing.join("、")}",
      "考えられる原因: 別のローダー（contracts_loader.rb の素の Zeitwerk のローダーなど）が、先に app/domain を管理して、",
      "contract 以外を読み込み対象から外しています。Domain Core のスペックは、先頭で domain_loader を読み込んでください。",
      "対処: ローダーの設定は before(:suite) で行われます。スペックのファイルの読み込み中に、Domain Core の定数を参照していないか確かめてください。"
    ].join("\n")
  end

  # app/domain を、Zeitwerk の規則で読み込めるようにする。プロセスで 1 回だけ作る（2 回目以降は何もしない）。
  # eager_load はしない（定数を参照したときに、そのファイルだけを読み込む）。ほかの issue が作業中のファイルの誤りが、
  # 無関係なスペックを巻き込まないようにするため。ファイルが、規則どおりの定数を定義しているか（名前の誤り）は、
  # app_domain_loading_spec が、ファイルごとに検査する。
  # 戻り値は、:zeitwerk（このプロセスのローダー）または :rails（別のローダーが管理している）。
  def setup!(managed_dirs: Zeitwerk::Loader.all_dirs)
    case strategy(own_loader: @own_loader, managed_dirs: managed_dirs)
    when :ready
      :zeitwerk
    when :rails
      verify!
      :rails
    else
      create_loader!
      :zeitwerk
    end
  end

  def create_loader!
    loader = Zeitwerk::Loader.new
    loader.push_dir(domain_dir)
    loader.setup
    @own_loader = loader
    verify!
  end
  private_class_method :create_loader!
end

RSpec.configure do |config|
  config.before(:suite) { DomainLoader.setup! }
end
