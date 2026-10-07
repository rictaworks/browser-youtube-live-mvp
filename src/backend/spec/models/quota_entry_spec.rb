require "rails_helper"
require "support/model_support"

# 割り当ての記帳の明細（quota_entries）。
# 列名 method（呼び出しの種別）は、Object#method と同じ名前で、ActiveRecord が生成する属性のリーダーが Object#method を隠す。
# QuotaEntry#method は、引数なしなら列の値を、引数ありなら Object#method（リフレクション）として働く。
RSpec.describe QuotaEntry do
  describe "列名 method の扱い" do
    it "method: を渡して作成でき、DB に保存される" do
      entry = create(:quota_entry, method: "liveBroadcasts.insert")

      expect(described_class.where(method: "liveBroadcasts.insert").pluck(:id)).to eq([ entry.id ])
      expect(described_class.find(entry.id)[:method]).to eq("liveBroadcasts.insert")
    end

    it "entry.method（引数なし）が、呼び出しの種別を返す。entry[:method]・read_attribute も同じ" do
      entry = described_class.find(create(:quota_entry, method: "liveStreams.list").id)

      expect(entry.method).to eq("liveStreams.list")
      expect(entry[:method]).to eq("liveStreams.list")
      expect(entry.read_attribute(:method)).to eq("liveStreams.list")
      expect(entry.attributes["method"]).to eq("liveStreams.list")
    end

    it "引数ありの entry.method(:name) は、Object#method（リフレクション）として働く" do
      entry = build(:quota_entry)

      expect(entry.method(:save)).to be_a(Method)
      expect { entry.method(:no_such_method_anywhere) }.to raise_error(NameError)
    end

    it "rspec-mocks の、レシーバへの差し替えも使える（partial double の検証が、method を呼ぶため）" do
      entry = build(:quota_entry)
      allow(entry).to receive(:valid?).and_return(false)

      expect(entry.valid?).to be(false)
    end

    it "method が空のレコードは、検証で拒否され、エラーは method に付く" do
      [ nil, "", "  " ].each do |blank|
        entry = build(:quota_entry, method: blank)

        expect(entry).not_to be_valid
        expect(entry.errors.where(:method, :blank)).to be_present
      end
    end
  end

  describe "関連" do
    it "割り当て日（quota_days）に属し、配信には、任意で属する" do
      day = create(:quota_day)
      common = create(:quota_entry, :common, quota_day: day)
      broadcast = create(:broadcast)
      spent = create(:quota_entry, quota_day: day, broadcast: broadcast)

      expect(common.quota_day).to eq(day)
      expect(common.broadcast).to be_nil
      expect(spent.broadcast).to eq(broadcast)
      expect(day.quota_entries).to match_array([ common, spent ])
      expect(broadcast.quota_entries).to eq([ spent ])
    end
  end
end
