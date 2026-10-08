require "rails_helper"

# YouTube への呼び出しの、閉じた表（issue #10。requirements.md 8.4・6.1）。窓口のすべての HTTP 呼び出しは、この表の 1 行に当たる。
#   api_method  台帳の明細の呼び出しの種別（YouTube の API のメソッド名）
#   cost_key    単価の出どころ（契約 limits.json の quota.unit_costs のキー）。単価は、コードに数値で直書きしない
#   buckets     支出できる枠。配信に属する呼び出しは prep（準備・確認枠）か settle（終了・清算枠）、属さない呼び出しは common（共通枠）
#               :settle を使えるのは、終了・清算の用途（状態確認・完了への遷移・削除）だけ。ほかの呼び出しは、終了・清算枠を取り崩せない
#               （8.4「終了・清算枠は、他の用途で取り崩さない」）。先行配信の清算（10.5）は、準備・確認枠から支出する
# この表をスペックで固定する。枠の別を変えるときは、このスペックと、requirements.md 8.4 の支出表を、あわせて見直す。
RSpec.describe YouTubeGateway::Calls do
  # 表の写し: [api_method, cost_key, http_method, path, buckets]
  expected = {
    insert_broadcast: [ "liveBroadcasts.insert", "insert", :post, "liveBroadcasts", [ :prep ] ],
    list_unstarted_broadcasts: [ "liveBroadcasts.list", "list", :get, "liveBroadcasts", [ :prep ] ],
    check_stream: [ "liveStreams.list", "list", :get, "liveStreams", [ :prep ] ],
    create_stream: [ "liveStreams.insert", "insert", :post, "liveStreams", [ :prep ] ],
    bind: [ "liveBroadcasts.bind", "bind", :post, "liveBroadcasts/bind", [ :prep ] ],
    fetch_status: [ "liveBroadcasts.list", "list", :get, "liveBroadcasts", [ :prep, :settle ] ],
    fetch_stream_health: [ "liveStreams.list", "list", :get, "liveStreams", [ :prep ] ],
    complete: [ "liveBroadcasts.transition", "transition", :post, "liveBroadcasts/transition", [ :prep, :settle ] ],
    delete: [ "liveBroadcasts.delete", "delete", :delete, "liveBroadcasts", [ :prep, :settle ] ],
    probe_channel_lookup: [ "channels.list", "list", :get, "channels", [ :common ] ],
    probe_live_enabled: [ "liveBroadcasts.list", "list", :get, "liveBroadcasts", [ :common ] ]
  }

  describe "表" do
    it "11 行（窓口の 9 つの公開メソッドが使う HTTP 呼び出しのすべて）。表の写しと一致する" do
      actual = described_class::TABLE.transform_values { |spec| [ spec.api_method, spec.cost_key, spec.http_method, spec.path, spec.buckets ] }

      expect(actual).to eq(expected)
      expect(described_class::TABLE).to be_frozen
      expect(described_class::TABLE.values).to all(be_frozen)
    end

    expected.each do |kind, (api_method, _cost_key, _http_method, _path, buckets)|
      it "#{kind}: #{api_method}。枠 #{buckets.inspect}" do
        spec = described_class.fetch(kind)

        expect(spec.kind).to eq(kind)
        expect(spec.api_method).to eq(api_method)
        expect(spec.buckets).to eq(buckets)
        expect(QuotaLedger::Arguments::METHOD_PATTERN).to match(spec.api_method)
      end
    end

    it "未知の種別は KeyError（黙って別の呼び出しにしない）" do
      expect { described_class.fetch(:unknown_call) }.to raise_error(KeyError)
      expect { described_class.fetch("bind") }.to raise_error(KeyError)
    end
  end

  describe "単価（契約 limits.json の quota.unit_costs）" do
    it "一覧取得は 1 ユニット、作成・更新・紐づけ・遷移・削除は各 50 ユニット（requirements.md 3 章・8.4）" do
      units = described_class::TABLE.transform_values(&:units)

      expect(units.select { |_, value| value == 1 }.keys).to contain_exactly(
        :list_unstarted_broadcasts, :check_stream, :fetch_status, :fetch_stream_health, :probe_channel_lookup, :probe_live_enabled
      )
      expect(units.select { |_, value| value == 50 }.keys).to contain_exactly(:insert_broadcast, :create_stream, :bind, :complete, :delete)
      expect(units.size).to eq(11)
    end

    it "単価は、契約の値そのもの（スペックにも、数値を書き写さない）" do
      costs = Contract::Limits::QUOTA.fetch("unit_costs")

      described_class::TABLE.each_value { |spec| expect(spec.units).to eq(costs.fetch(spec.cost_key)) }
      expect(costs).to include("list" => 1, "insert" => 50, "bind" => 50, "transition" => 50, "delete" => 50)
    end

    it "1 配信の最大の支出は、8.4 の表の小計（準備・確認枠 321・終了・清算枠 204）と一致し、予約（340・210）に収まる" do
      units = described_class::TABLE.transform_values(&:units)
      # 準備・確認枠: 先行配信の状態確認 1 + 清算 50 + 配信の作成 50 + 応答喪失時の一覧取得 1 + ストリームの確認 1 + ストリームの作成 50
      #               + 紐づけ 50 + 準備中の再試行 50 + ライブ確定の確認 24 回 + 定期確認 12 回 x 2 + 復帰時の確認 10 回 x 2
      prep = units[:fetch_status] + units[:complete] + units[:insert_broadcast] + units[:list_unstarted_broadcasts] + units[:check_stream] +
             units[:create_stream] + units[:bind] + units[:insert_broadcast] + (24 * units[:fetch_status]) + (12 * 2 * units[:fetch_status]) +
             (10 * 2 * units[:fetch_status])
      # 終了・清算枠: 終了時の状態確認 1 + 完了への遷移または削除 50 + 清算の再試行 3 回 x（状態確認 1 + 清算 50）
      settle = units[:fetch_status] + units[:complete] + (3 * (units[:fetch_status] + units[:delete]))

      expect([ prep, settle ]).to eq([ 321, 204 ])
      expect(prep).to be <= Contract::Limits::QUOTA.fetch("prep_reservation_units")
      expect(settle).to be <= Contract::Limits::QUOTA.fetch("settle_reservation_units")
    end
  end

  describe "枠の別" do
    it ":settle を使えるのは、終了・清算の用途の呼び出し（状態確認・完了への遷移・削除）だけ" do
      with_settle = described_class::TABLE.select { |_, spec| spec.buckets.include?(:settle) }.keys

      expect(with_settle).to contain_exactly(:fetch_status, :complete, :delete)
    end

    it "共通枠（common）を使うのは、配信に属さない呼び出し（接続時の確認）だけ。配信に属する呼び出しは、共通枠を使わない" do
      common = described_class::TABLE.select { |_, spec| spec.buckets.include?(:common) }.keys

      expect(common).to contain_exactly(:probe_channel_lookup, :probe_live_enabled)
      described_class::TABLE.each_value { |spec| expect(spec.buckets == [ :common ] || !spec.buckets.include?(:common)).to be(true) }
    end

    it "common? は、共通枠の呼び出しだけ true" do
      expect(described_class.fetch(:probe_channel_lookup)).to be_common
      expect(described_class.fetch(:bind)).not_to be_common
    end

    describe "#resolve_bucket" do
      it "枠が 1 つだけの呼び出しは、省略すると、その枠。指定する場合は、その枠だけ" do
        bind = described_class.fetch(:bind)

        expect(bind.resolve_bucket(nil)).to eq(:prep)
        expect(bind.resolve_bucket(:prep)).to eq(:prep)
        expect { bind.resolve_bucket(:settle) }.to raise_error(ArgumentError, /bucket/)
        expect { bind.resolve_bucket(:common) }.to raise_error(ArgumentError, /bucket/)
      end

      it "枠が 2 つの呼び出し（状態確認・完了への遷移・削除）は、省略できない（用途で、呼び出し側が決める）" do
        %i[ fetch_status complete delete ].each do |kind|
          spec = described_class.fetch(kind)

          expect { spec.resolve_bucket(nil) }.to raise_error(ArgumentError, /required/)
          expect(spec.resolve_bucket(:prep)).to eq(:prep)
          expect(spec.resolve_bucket(:settle)).to eq(:settle)
          expect { spec.resolve_bucket(:common) }.to raise_error(ArgumentError, /bucket/)
        end
      end

      it "共通枠の呼び出しは、省略すると common。準備・確認枠・終了・清算枠は指定できない" do
        probe = described_class.fetch(:probe_live_enabled)

        expect(probe.resolve_bucket(nil)).to eq(:common)
        expect(probe.resolve_bucket(:common)).to eq(:common)
        expect { probe.resolve_bucket(:prep) }.to raise_error(ArgumentError, /bucket/)
        expect { probe.resolve_bucket(:settle) }.to raise_error(ArgumentError, /bucket/)
      end

      it "枠はシンボルだけ（文字列・その他は ArgumentError）" do
        spec = described_class.fetch(:fetch_status)

        [ "prep", "settle", 1, true, :other ].each do |value|
          expect { spec.resolve_bucket(value) }.to raise_error(ArgumentError, /bucket/)
        end
      end
    end
  end
end
