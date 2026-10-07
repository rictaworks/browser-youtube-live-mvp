require "spec_helper"
require "tmpdir"
require_relative "support/domain_loader"
require_relative "contract/support/contracts_loader"

# Domain Core のスペックの共通部品（support/domain_loader.rb）。
# Rails を起動しない実行でも、Rails を起動するスペックと同じ実行でも、app/domain が読み込めること。
#
# 一時ディレクトリは、ブロックなしの Dir.mktmpdir で作る。ブロック形式は、ブロックの終了時に、標準ライブラリが、
# ディレクトリを中身ごと削除する（CLAUDE.md の削除の禁止は、自動の判断を含む）。ブロックなしは削除しない（後始末は OS に任せる）。
# 走査（test/pr39/scan_sources.py）が、ブロック形式を検出する。
RSpec.describe "Domain Core の読み込みの補助（DomainLoader）" do
  describe ".strategy（ローダーの設定の方針）" do
    dir = "/app/app/domain"

    {
      "このプロセスでローダーを作ってある: 何もしない" => [ true, [ dir ], :ready ],
      "このプロセスでローダーを作ってあり、ほかも管理していない: 何もしない" => [ true, [], :ready ],
      "Rails（別のローダー）が app/domain を管理している: 作らない" => [ false, [ "/app/app/models", dir ], :rails ],
      "どのローダーも管理していない: 作る" => [ false, [], :create ],
      "別のディレクトリだけを管理している: 作る" => [ false, [ "/app/app/models", "/app/app/domain/contract" ], :create ]
    }.each do |label, (own_loader, managed_dirs, expected)|
      it label do
        expect(DomainLoader.strategy(own_loader: own_loader, managed_dirs: managed_dirs, dir: dir)).to eq(expected)
      end
    end

    it "Zeitwerk::Loader.all_dirs の実際の値に対して、動く（既定の dir は app/domain）" do
      expect(DomainLoader.domain_dir).to end_with("/app/domain")
      expect(File.directory?(DomainLoader.domain_dir)).to be(true)
      expect(DomainLoader.strategy(own_loader: false, managed_dirs: [], dir: DomainLoader.domain_dir)).to eq(:create)
    end
  end

  describe ".expected_constants（app/domain の直下の定数名）" do
    it "ファイルとディレクトリを Zeitwerk の規則で camelize する。.rb 以外と、Ruby を含まないディレクトリは含めない" do
      dir = Dir.mktmpdir("domain_loader_expected_constants")
      File.write(File.join(dir, "usage_calendar.rb"), "")
      File.write(File.join(dir, "start_admission.rb"), "")
      File.write(File.join(dir, ".gitkeep"), "")
      File.write(File.join(dir, "notes.txt"), "")
      Dir.mkdir(File.join(dir, "contract"))
      File.write(File.join(dir, "contract", "limits.rb"), "")
      Dir.mkdir(File.join(dir, "empty_dir"))
      Dir.mkdir(File.join(dir, "docs_only"))
      File.write(File.join(dir, "docs_only", "memo.md"), "")

      expect(DomainLoader.expected_constants(dir: dir)).to eq(%w[Contract StartAdmission UsageCalendar])
    end

    it "実際の app/domain には、契約（Contract）と、この issue の定数が含まれる" do
      expect(DomainLoader.expected_constants).to include("Contract", "UsageCalendar", "Settings", "StartAdmission", "QuotaPolicy")
    end
  end

  describe ".verify!（解決できない定数を、黙って通さない）" do
    it "すべて解決できれば、何も返さず通る" do
      dir = Dir.mktmpdir("domain_loader_verify_ok")
      File.write(File.join(dir, "usage_calendar.rb"), "")

      expect(DomainLoader.verify!(dir: dir, resolvable: ->(_name) { true })).to be_nil
    end

    it "解決できない定数を、すべて名前で挙げて失敗する" do
      dir = Dir.mktmpdir("domain_loader_verify_all_missing")
      File.write(File.join(dir, "usage_calendar.rb"), "")
      File.write(File.join(dir, "settings.rb"), "")

      expect { DomainLoader.verify!(dir: dir, resolvable: ->(_name) { false }) }
        .to raise_error(DomainLoader::NotLoadable) { |error|
          expect(error.message).to include("Settings")
          expect(error.message).to include("UsageCalendar")
          expect(error.message).to include(dir)
          expect(error.message).to include("別のローダー")
        }
    end

    it "一部だけ解決できないときも、その定数だけを挙げて失敗する" do
      dir = Dir.mktmpdir("domain_loader_verify_some_missing")
      File.write(File.join(dir, "usage_calendar.rb"), "")
      File.write(File.join(dir, "settings.rb"), "")

      expect { DomainLoader.verify!(dir: dir, resolvable: ->(name) { name == "Settings" }) }
        .to raise_error(DomainLoader::NotLoadable) { |error|
          expect(error.message).to include("UsageCalendar")
          expect(error.message).not_to include("Settings")
        }
    end
  end

  describe ".setup!（スイートの開始時に実行済み）" do
    it "Zeitwerk のローダー（:zeitwerk）か、Rails のローダー（:rails）が、app/domain を管理している。何度呼んでも同じ" do
      first = DomainLoader.setup!

      expect(%i[zeitwerk rails]).to include(first)
      expect(DomainLoader.setup!).to eq(first)
      expect(Zeitwerk::Loader.all_dirs).to include(DomainLoader.domain_dir)
    end

    it "app/domain の直下の定数が、すべて解決できる" do
      DomainLoader.expected_constants.each do |name|
        expect(Object.const_defined?(name)).to be(true), "#{name} が解決できません"
      end
    end

    it "契約の定数（Contract）も、同じローダーで読み込める" do
      expect(Contract::RejectionReason::ALL.size).to eq(14)
      expect(Contract::Limits::QUOTA.fetch("broadcast_reservation_units")).to eq(550)
    end

    it "契約のスペックの補助（ContractSpecSupport.load_contract_namespace!）は、すでに app/domain が管理されているので、何もしない（衝突しない）" do
      expect(ContractSpecSupport.load_contract_namespace!).to eq(:rails)
    end
  end
end
