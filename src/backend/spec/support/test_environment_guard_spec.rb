require "spec_helper"
require_relative "test_environment_guard"

RSpec.describe TestEnvironmentGuard do
  describe ".verify_rails_env!" do
    it "RAILS_ENV が未設定なら通す" do
      expect { described_class.verify_rails_env!({}) }.not_to raise_error
    end

    it "RAILS_ENV=test なら通す" do
      expect { described_class.verify_rails_env!({ "RAILS_ENV" => "test" }) }.not_to raise_error
    end

    %w[ development production staging ].each do |value|
      it "RAILS_ENV=#{value} なら拒否する" do
        expect { described_class.verify_rails_env!({ "RAILS_ENV" => value }) }
          .to raise_error(TestEnvironmentGuard::UnsafeTestEnvironmentError, /RAILS_ENV=#{value}/)
      end
    end

    it "RAILS_ENV が空文字なら拒否する" do
      expect { described_class.verify_rails_env!({ "RAILS_ENV" => "" }) }
        .to raise_error(TestEnvironmentGuard::UnsafeTestEnvironmentError)
    end
  end

  describe ".verify_database_name!" do
    %w[ bl_test bl_test_issue5 bl_test_2 issue5_test a_test_b test ].each do |name|
      it "テスト用の名前 #{name} は通す" do
        expect { described_class.verify_database_name!(name) }.not_to raise_error
      end
    end

    {
      "開発 DB" => "bl_development",
      "既定の DB" => "postgres",
      "テンプレート" => "template1",
      "本番を思わせる名前" => "bl_production",
      "test を語として含まない名前" => "bl_testing",
      "大文字" => "BL_TEST",
      "ハイフン" => "bl-test",
      "SQL の断片" => "bl_test; DROP DATABASE bl_development",
      "空文字" => "",
      "64 文字（PostgreSQL の識別子の上限を超える）" => "#{"a" * 60}_test",
      "数字で始まる名前" => "1_test"
    }.each do |label, name|
      it "#{label}（#{name.inspect}）は拒否する" do
        expect { described_class.verify_database_name!(name) }
          .to raise_error(TestEnvironmentGuard::UnsafeTestEnvironmentError, /database/i)
      end
    end

    it "nil は拒否する" do
      expect { described_class.verify_database_name!(nil) }
        .to raise_error(TestEnvironmentGuard::UnsafeTestEnvironmentError)
    end

    it "63 文字ちょうどの名前は通す" do
      expect { described_class.verify_database_name!("#{"a" * 58}_test") }.not_to raise_error
    end
  end
end
