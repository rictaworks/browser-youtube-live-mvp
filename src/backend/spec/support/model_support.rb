# モデル・DB のスペックの共通の読み込み。
#
# spec/rails_helper.rb は、spec/support/** を自動では読み込まない。モデル・DB のスペックは、先頭で
#   require "rails_helper"
#   require "support/model_support"
# とする（rails_helper・FactoryBot の構文・契約の読み込み・カタログの読み取り・制約違反の補助が、すべてそろう）。
#
# rails_helper を、各スペックで直接読み込むのは、scripts/test_backend.sh のため。このスクリプトは、対象のパスの配下に
# rails_helper を読み込むスペックがあるときだけ、テスト用 DB を準備する（無ければ作り、db/structure.sql を読み込む）。
# 直接の読み込みが無いと、新しい名前の DB では、DB が無いまま RSpec が始まり、失敗する。
require "rails_helper"
require_relative "factory_bot"
require_relative "contract_enums"
require_relative "schema_inspector"
require_relative "db_helpers"
require_relative "account_records"
