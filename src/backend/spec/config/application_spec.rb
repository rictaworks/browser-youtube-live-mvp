require "rails_helper"

# 雛形が満たすべき設定（issue #1 の受け入れ条件）を確かめる
RSpec.describe "アプリケーションの設定" do
  describe "時刻" do
    it "タイムゾーンは Tokyo（JST）" do
      expect(Rails.application.config.time_zone).to eq("Tokyo")
      expect(Time.zone.name).to eq("Tokyo")
      expect(Time.zone.formatted_offset).to eq("+09:00")
    end

    it "DB へは UTC で保存する（Rails の既定）" do
      expect(ActiveRecord.default_timezone).to eq(:utc)
    end
  end

  describe "スキーマ" do
    it "schema_format は :sql（部分一意索引・CHECK 制約を保持するため）" do
      expect(ActiveRecord.schema_format).to eq(:sql)
    end

    it "db/structure.sql がある" do
      expect(Rails.root.join("db/structure.sql")).to exist
    end
  end

  describe "入れないもの（issue #1）" do
    {
      "Action Cable" => :action_cable,
      "Action Mailer" => :action_mailer,
      "Action Mailbox" => :action_mailbox,
      "Action Text" => :action_text,
      "Active Storage" => :active_storage,
      "アセットパイプライン" => :assets
    }.each do |label, config_name|
      it "#{label} を有効にしない" do
        expect(Rails.application.config).not_to respond_to(config_name)
      end
    end

    %w[
      turbo-rails stimulus-rails importmap-rails propshaft sprockets
      solid_cache solid_queue solid_cable kamal thruster
    ].each do |gem_name|
      it "#{gem_name} を使わない" do
        expect(Gem.loaded_specs).not_to have_key(gem_name)
      end
    end

    it "標準モード（--api にしない）。管理画面のビューのため ActionController::Base を使える" do
      expect(Rails.application.config.api_only).to be(false)
    end
  end

  describe "json gem" do
    it "2 系に固定する（3 系は ActiveSupport 8.1 と非互換になり得る）" do
      expect(Gem.loaded_specs.fetch("json").version.segments.first).to eq(2)
    end
  end

  describe "資格情報" do
    it "config/master.key を作らない" do
      expect(Rails.root.join("config/master.key")).not_to exist
    end

    it "config/credentials.yml.enc を作らない" do
      expect(Rails.root.join("config/credentials.yml.enc")).not_to exist
    end

    it "secret_key_base は環境変数 SESSION_SECRET（未設定なら明示した開発用の値）から与える" do
      expected = AppEnvironment.current.session_secret(ENV)

      expect(Rails.application.secret_key_base).to eq(expected)
      expect(Rails.application.secret_key_base).to be_present
    end
  end

  describe "環境の判定" do
    it "テストは test 環境で動き、外部サービスは疑似実装（:fake）を使う" do
      expect(AppEnvironment.current.name).to eq(:test)
      expect(AppEnvironment.current.external_services).to eq(:fake)
    end
  end
end
