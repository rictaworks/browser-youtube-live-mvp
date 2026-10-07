require "spec_helper"
require_relative "support/contracts_loader"

# 契約のディレクトリの探し方（/contracts・../contracts・../../contracts・このファイルからの相対パス）と、
# 見つからないときに、黙ってスキップせず、明確なメッセージで失敗すること。
RSpec.describe ContractSpecSupport do
  describe ".candidate_dirs" do
    it "/contracts・../contracts・../../contracts・このファイルから src/contracts へ上る相対パスの順（同じ場所は 1 つにまとめる）" do
      candidates = described_class.candidate_dirs(cwd: "/work/src/backend", here: "/work/src/backend/spec/domain/contract/support")

      expect(candidates).to eq([ "/contracts", "/work/src/contracts", "/work/contracts" ])
    end

    it "コンテナの中（作業ディレクトリが /app）では、すべて /contracts になる" do
      expect(described_class.candidate_dirs(cwd: "/app", here: "/app/spec/domain/contract/support")).to eq([ "/contracts" ])
    end

    it "CI のチェックアウトでは、作業ディレクトリが src/backend のとき、../contracts が src/contracts を指す" do
      candidates = described_class.candidate_dirs(cwd: "/repo/src/backend", here: "/elsewhere/spec/domain/contract/support")

      expect(candidates).to include("/repo/src/contracts")
    end
  end

  describe ".locate_contracts_dir" do
    it "最初に見つかった候補を返す" do
      found = described_class.locate_contracts_dir(candidates: %w[ /a /b /c ], marker_exists: ->(dir) { %w[ /b /c ].include?(dir) })

      expect(found).to eq("/b")
    end

    it "1 つも無ければ、探した場所をすべて並べて失敗する（黙ってスキップしない）" do
      candidates = %w[ /contracts /x/contracts /contracts-missing ]

      expect { described_class.locate_contracts_dir(candidates: candidates, marker_exists: ->(_dir) { false }) }
        .to raise_error(described_class::ContractsNotFound) { |error|
          candidates.each { |dir| expect(error.message).to include(dir) }
          expect(error.message).to include(described_class::MARKER_FILE)
          expect(error.message).to include("スキップせず")
        }
    end

    it "実際の環境で、契約のディレクトリが見つかる" do
      dir = described_class.locate_contracts_dir

      expect(File.exist?(File.join(dir, described_class::MARKER_FILE))).to be(true)
    end
  end

  describe ".same_value?（型まで含めた比較）" do
    {
      "同じ整数" => [ 60, 60, true ],
      "整数と浮動小数点（60 と 60.0）は別" => [ 60.0, 60, false ],
      "真偽値の違い" => [ false, true, false ],
      "文字列の違い" => [ "a", "b", false ],
      "入れ子の Hash が同じ" => [ { "a" => [ 1, { "b" => 2.5 } ] }, { "a" => [ 1, { "b" => 2.5 } ] }, true ],
      "Hash のキーが多い" => [ { "a" => 1, "b" => 2 }, { "a" => 1 }, false ],
      "Hash のキーが足りない" => [ { "a" => 1 }, { "a" => 1, "b" => 2 }, false ],
      "Array の要素数が違う" => [ [ 1, 2 ], [ 1, 2, 3 ], false ],
      "Array の順が違う" => [ [ 1, 2 ], [ 2, 1 ], false ]
    }.each do |label, (actual, expected, result)|
      it label do
        expect(described_class.same_value?(actual, expected)).to be(result)
      end
    end
  end

  describe ".strip_document_keys" do
    it "$comment・note・*_note を、再帰的に取り除く" do
      source = { "$comment" => "x", "a" => { "note" => "y", "b" => 1, "b_note" => "z", "c" => [ { "note" => "w", "d" => 2 } ] } }

      expect(described_class.strip_document_keys(source)).to eq({ "a" => { "b" => 1, "c" => [ { "d" => 2 } ] } })
    end
  end

  describe "名前の対応" do
    {
      "source_kind" => "SourceKind",
      "ws_message_type" => "WsMessageType",
      "youtube_connection_state" => "YoutubeConnectionState",
      "resolution" => "Resolution"
    }.each do |snake, camel|
      it "#{snake} は Contract::#{camel}（Zeitwerk の規則）" do
        expect(described_class.module_name_for(snake)).to eq(camel)
      end
    end

    {
      "camera" => "CAMERA",
      "shared_audio" => "SHARED_AUDIO",
      "720p" => "P720",
      "480p" => "P480",
      "end" => "END_"
    }.each do |value, constant|
      it "値 #{value} の定数名は #{constant}" do
        expect(described_class.constant_name_for(value)).to eq(constant)
      end
    end
  end
end
