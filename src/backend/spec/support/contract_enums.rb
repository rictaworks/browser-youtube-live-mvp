require_relative "../domain/contract/support/contracts_loader"

# DB の CHECK 制約の符号と、契約（src/contracts）の符号の一致を検査するための、契約の読み込み口。
#
# 契約のディレクトリの探し方は、#3 のテスト補助（spec/domain/contract/support/contracts_loader.rb。参照のみ）に従う。
# 見つからなければ、黙ってスキップせず、探した場所を並べて失敗する（ContractSpecSupport::ContractsNotFound）。
module ContractEnums
  # 公開範囲（broadcasts.privacy_status）の符号は、列挙（enums.json）ではなく、HTTP API の文書の表にだけある。
  PRIVACY_STATUS_ROW_PREFIX = "| `privacy_status` | 文字列 |".freeze

  module_function

  # enums.json の enums（列挙の名前 => 定義）
  def all
    @all ||= ContractSpecSupport.load_json("enums.json").fetch("enums")
  end

  # 列挙の符号（契約の順）
  def values(name)
    all.fetch(name).fetch("values")
  end

  # POST /api/broadcasts の privacy_status の符号（http-api.md の要求の表の行）。
  # 文書の形が変わって読み取れなくなったときは、黙って空にせず、失敗する。
  def privacy_statuses
    path = File.join(ContractSpecSupport.locate_contracts_dir, "http-api.md")
    row = File.read(path, encoding: "UTF-8").lines.find { |line| line.start_with?(PRIVACY_STATUS_ROW_PREFIX) }
    raise "http-api.md に privacy_status の行（#{PRIVACY_STATUS_ROW_PREFIX} で始まる行）が無い" unless row

    codes = row.split("|").map(&:strip).fetch(3).scan(/`([a-z_]+)`/).flatten
    raise "http-api.md の privacy_status の行から、符号を読み取れない: #{row.strip}" if codes.empty?

    codes
  end
end
