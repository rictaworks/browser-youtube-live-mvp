require "rails_helper"

# 正規化した配信の状態（issue #10。requirements.md 10.2・10.3・10.4・15 章）。
# YouTube の lifeCycleStatus の 8 値（complete・created・live・liveStarting・ready・revoked・testStarting・testing）と、
# 「存在しない」（NOT_FOUND）を持つ。値は SettlementRules（#6）の清算の規則の入力と同じ（plan(youtube_status:) へそのまま渡せる）。
RSpec.describe YouTubeStatus do
  life_cycle_values = %w[ complete created live liveStarting ready revoked testStarting testing ]

  describe "値" do
    it "lifeCycleStatus の 8 値と NOT_FOUND を持つ。SettlementRules の値と同じ" do
      expect(described_class::VALUES).to eq(SettlementRules::LifeCycleStatus::ALL + [ SettlementRules::NOT_FOUND ])
      expect(SettlementRules::LifeCycleStatus::ALL).to match_array(life_cycle_values)
      expect(described_class::NOT_FOUND).to eq(:not_found)
    end

    life_cycle_values.each do |value|
      it "#{value} を受け付け、value で取り出せる（SettlementRules.plan へそのまま渡せる）" do
        status = described_class.from_life_cycle_status(value)

        expect(status.value).to eq(value)
        expect { SettlementRules.plan(youtube_status: status.value) }.not_to raise_error
      end
    end

    it "存在しない: not_found。SettlementRules.plan へそのまま渡せる" do
      status = described_class.not_found

      expect(status.value).to eq(:not_found)
      expect(SettlementRules.plan(youtube_status: status.value)).to eq(Directive.of(:mark_settled))
    end

    [ "unknown", "", "LIVE", "Live", " live", "live ", nil, :live, 1, [], "not_found" ].each do |value|
      it "未知の lifeCycleStatus（#{value.inspect}）は ArgumentError（黙って受け付けない）。値をメッセージに出さない" do
        expect { described_class.from_life_cycle_status(value) }.to raise_error(ArgumentError) { |error|
          expect(error.message).not_to include(value.to_s) unless value.to_s.empty?
        }
      end
    end
  end

  describe "述語" do
    # [値, live?, complete?, revoked?, not_found?, terminal?, transitioning?]
    {
      "complete" => [ false, true, false, false, true, false ],
      "created" => [ false, false, false, false, false, false ],
      "live" => [ true, false, false, false, false, false ],
      "liveStarting" => [ false, false, false, false, false, true ],
      "ready" => [ false, false, false, false, false, false ],
      "revoked" => [ false, false, true, false, true, false ],
      "testStarting" => [ false, false, false, false, false, true ],
      "testing" => [ false, false, false, false, false, false ]
    }.each do |value, (live, complete, revoked, not_found, terminal, transitioning)|
      it "#{value}: live?=#{live}・complete?=#{complete}・revoked?=#{revoked}・not_found?=#{not_found}・terminal?=#{terminal}・transitioning?=#{transitioning}" do
        status = described_class.from_life_cycle_status(value)

        expect(status).to have_attributes(live?: live, complete?: complete, revoked?: revoked, not_found?: not_found, terminal?: terminal, transitioning?: transitioning)
      end
    end

    it "存在しない: not_found? と terminal? だけが true（YouTube 側で終わったものとして扱う）" do
      expect(described_class.not_found).to have_attributes(live?: false, complete?: false, revoked?: false, not_found?: true, terminal?: true, transitioning?: false)
    end

    it "完了・取り消し（revoked）・存在しない が終端。遷移中（liveStarting・testStarting）は終端ではなく、まだライブでない（10.2）" do
      terminals = described_class::VALUES.select { |value| described_class.new(value).terminal? }

      expect(terminals).to contain_exactly("complete", "revoked", :not_found)
    end
  end

  describe "等価性と表示" do
    it "同じ値は等しい（Hash のキー・集合で使える）。値が違えば等しくない" do
      expect(described_class.from_life_cycle_status("live")).to eq(described_class.from_life_cycle_status("live"))
      expect(described_class.from_life_cycle_status("live")).not_to eq(described_class.from_life_cycle_status("ready"))
      expect(described_class.not_found).to eq(described_class.not_found)
      expect({ described_class.not_found => 1 }[described_class.not_found]).to eq(1)
    end

    it "凍結されている。inspect は値を示す" do
      status = described_class.from_life_cycle_status("liveStarting")

      expect(status).to be_frozen
      expect(status.inspect).to eq("#<YouTubeStatus liveStarting>")
      expect(status.to_s).to eq("#<YouTubeStatus liveStarting>")
      expect(described_class.not_found.inspect).to eq("#<YouTubeStatus not_found>")
    end

    it "直接 new するときも、値を検査する（未知の値は ArgumentError）" do
      expect { described_class.new("bogus") }.to raise_error(ArgumentError)
      expect(described_class.new("live")).to be_live
      expect(described_class.new(:not_found)).to be_not_found
    end
  end
end
