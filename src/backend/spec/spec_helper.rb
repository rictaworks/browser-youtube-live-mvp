# RSpec の共通設定。Rails も DB も読み込まない。
#
# このファイルだけを読み込むスペック（`require "spec_helper"`）は、Rails を起動せず、DB へ接続せずに動く。
# 純粋な Domain Core（app/domain/）のスペックは、これだけを読み込んで速く回す。
# Rails・DB を使うスペックは、`require "rails_helper"` を読み込む。
RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups

  # --only-failures のための記録。tmp/ は gitignore 済み
  config.example_status_persistence_file_path = "tmp/rspec_status.txt"

  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
