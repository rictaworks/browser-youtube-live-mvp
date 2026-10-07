require "rails_helper"
require "support/model_support"
require "services/support/ledger_support"

# 送信転送量（requirements.md 8.3・15 章「転送量の判定」・20.1 の transfer_months）。
# 暦月（JST。03:00 区切りではなく 00:00 区切り）ごとに、中継の送出量の報告を積算する。積算が予算に達した月は、新規の受付を受理しない。
# 判定の規則（1 GB = 10 億バイト。達したら不可）は、#5 の TransferBudgetPolicy。このサービスは、DB への原子的な加算と読み取りを行う。
#   add!                  月の行を upsert して、原子的に加算する
#   exceeded?             積算を読み、TransferBudgetPolicy で判定する（行が無い月は 0 バイト）
#   add_for_broadcast!    配信の sent_bytes と月次の積算を、同一のトランザクションで加算する
# 同時の呼び出しと、途中で失敗したときの取り消しは、transfer_budget_concurrency_spec.rb。
RSpec.describe TransferBudget do
  include LedgerSupport

  let(:month) { "2026-10" }
  let(:settings) { Settings.defaults }
  let(:gigabyte) { TransferBudgetPolicy::BYTES_PER_GB }

  describe ".add!" do
    it "行が無い月は、行を作って加算する（0 から）。加算後の積算を返す" do
      expect(described_class.add!(month_key: month, bytes: 1_500)).to eq(1_500)

      expect(TransferMonth.find(month).sent_bytes).to eq(1_500)
    end

    it "既存の月には、積算へ加算する" do
      described_class.add!(month_key: month, bytes: 1_500)

      expect(described_class.add!(month_key: month, bytes: 2_500)).to eq(4_000)
      expect(TransferMonth.find(month).sent_bytes).to eq(4_000)
      expect(TransferMonth.where(month: month).count).to eq(1)
    end

    it "別の月の積算に触れない" do
      described_class.add!(month_key: "2026-09", bytes: 700)

      described_class.add!(month_key: month, bytes: 1_500)

      expect(TransferMonth.find("2026-09").sent_bytes).to eq(700)
    end

    it "0 バイトの加算は、積算を変えない（月の行は作られる）" do
      described_class.add!(month_key: month, bytes: 40)

      expect(described_class.add!(month_key: month, bytes: 0)).to eq(40)
    end

    it "10 億バイトを超える積算も、bigint として扱える（1 GB = 10 億バイトの 10 倍を超える）" do
      expect(described_class.add!(month_key: month, bytes: 12 * gigabyte)).to eq(12 * gigabyte)
      expect(described_class.add!(month_key: month, bytes: gigabyte)).to eq(13 * gigabyte)
    end

    it "1 つの upsert 文で加算する（読んでから書く 2 段にしない）" do
      statements = capture_sql { described_class.add!(month_key: month, bytes: 10) }
      writes = statements.grep(/\A(INSERT|UPDATE) /)

      expect(writes.size).to eq(1)
      expect(writes.first).to match(/\AINSERT INTO "transfer_months".*ON CONFLICT \("month"\) DO UPDATE/m)
    end

    {
      "年が 3 桁" => "202-10",
      "月が 13" => "2026-13",
      "月が 00" => "2026-00",
      "月が 1 桁" => "2026-1",
      "日まである" => "2026-10-01",
      "前後に空白" => " 2026-10",
      "末尾に改行" => "2026-10\n",
      "区切りがスラッシュ" => "2026/10",
      "空文字" => "",
      "nil" => nil,
      "Date" => Date.new(2026, 10, 1),
      "シンボル" => :"2026-10"
    }.each do |label, bad|
      it "暦月の形が不正（#{label}）: ArgumentError。行は作られない" do
        expect { described_class.add!(month_key: bad, bytes: 10) }.to raise_error(ArgumentError)
        expect(TransferMonth.count).to eq(0)
      end
    end

    {
      "負の値" => -1,
      "小数" => 1.5,
      "文字列" => "10",
      "nil" => nil,
      "真偽値" => true,
      "bigint の上限を超える" => (2**63)
    }.each do |label, bad|
      it "バイト数が不正（#{label}）: ArgumentError。行は作られない" do
        expect { described_class.add!(month_key: month, bytes: bad) }.to raise_error(ArgumentError)
        expect(TransferMonth.count).to eq(0)
      end
    end
  end

  describe ".sent_bytes" do
    it "行が無い月は 0。読み取りは、行を作らない" do
      expect(described_class.sent_bytes(month_key: month)).to eq(0)
      expect(TransferMonth.count).to eq(0)
    end

    it "積算を返す" do
      described_class.add!(month_key: month, bytes: 123)

      expect(described_class.sent_bytes(month_key: month)).to eq(123)
    end

    it "暦月の形が不正なら ArgumentError" do
      expect { described_class.sent_bytes(month_key: "2026-13") }.to raise_error(ArgumentError)
    end
  end

  describe ".exceeded?" do
    it "行が無い月は、予算に達していない（積算 0 バイト）" do
      expect(described_class.exceeded?(month_key: month, settings: settings)).to be(false)
      expect(TransferMonth.count).to eq(0)
    end

    # 既定の予算は 10 GB（10,000,000,000 バイト）。積算が予算に達した（以上）月は、不可
    {
      "予算の 1 バイト手前" => [ 10 * 1_000_000_000 - 1, false ],
      "ちょうど予算（達した）" => [ 10 * 1_000_000_000, true ],
      "予算を超えた" => [ 10 * 1_000_000_000 + 1, true ],
      "積算 0" => [ 0, false ]
    }.each do |label, (sent, expected)|
      it "#{label}（積算 #{sent} バイト）: #{expected}" do
        described_class.add!(month_key: month, bytes: sent)

        expect(described_class.exceeded?(month_key: month, settings: settings)).to be(expected)
      end
    end

    it "予算（設定 monthly_transfer_budget_gb）を、引数の設定から読む（10 億バイト単位）" do
      described_class.add!(month_key: month, bytes: 3 * gigabyte)

      expect(described_class.exceeded?(month_key: month, settings: settings.with(monthly_transfer_budget_gb: 3))).to be(true)
      expect(described_class.exceeded?(month_key: month, settings: settings.with(monthly_transfer_budget_gb: 4))).to be(false)
    end

    it "予算 0 は、積算 0 でも達している（TransferBudgetPolicy のとおり。以上）" do
      expect(described_class.exceeded?(month_key: month, settings: settings.with(monthly_transfer_budget_gb: 0))).to be(true)
    end

    it "別の月の積算は、判定に使わない" do
      described_class.add!(month_key: "2026-09", bytes: 50 * gigabyte)

      expect(described_class.exceeded?(month_key: month, settings: settings)).to be(false)
      expect(described_class.exceeded?(month_key: "2026-09", settings: settings)).to be(true)
    end

    it "判定の規則は TransferBudgetPolicy に従う（同じ入力で、同じ答え）" do
      [ 0, 1, gigabyte, 9 * gigabyte, 10 * gigabyte - 1, 10 * gigabyte, 11 * gigabyte ].each do |sent|
        TransferMonth.find_or_create_by!(month: month).update_columns(sent_bytes: sent)

        expected = TransferBudgetPolicy.exceeded?(sent_bytes: sent, budget_gb: settings.monthly_transfer_budget_gb)
        expect(described_class.exceeded?(month_key: month, settings: settings)).to be(expected)
      end
    end

    it "設定が Settings でなければ ArgumentError（既定値で補わない）" do
      [ nil, { monthly_transfer_budget_gb: 10 }, 10 ].each do |bad|
        expect { described_class.exceeded?(month_key: month, settings: bad) }.to raise_error(ArgumentError)
      end
    end

    it "暦月の形が不正なら ArgumentError" do
      expect { described_class.exceeded?(month_key: "2026-1", settings: settings) }.to raise_error(ArgumentError)
    end
  end

  describe ".add_for_broadcast!" do
    # let! にする（保存点の内側で、初めて作られて、巻き戻しに巻き込まれないように）
    let!(:broadcast) { create(:broadcast, sent_bytes: 100) }
    let(:october) { Time.utc(2026, 10, 7, 4, 30, 0) }

    it "配信の sent_bytes と、月次の積算の両方へ加算し、月次の積算を返す" do
      expect(described_class.add_for_broadcast!(broadcast, delta_bytes: 2_500, now: october)).to eq(2_500)

      expect(Broadcast.find(broadcast.id).sent_bytes).to eq(2_600)
      expect(TransferMonth.find("2026-10").sent_bytes).to eq(2_500)
    end

    it "メモリ上の配信も、加算後の値になる（変更済みの印は付かない）" do
      described_class.add_for_broadcast!(broadcast, delta_bytes: 2_500, now: october)

      expect(broadcast.sent_bytes).to eq(2_600)
      expect(broadcast).not_to be_changed
    end

    it "報告のたびに累積する（送出量の報告は、増分）" do
      described_class.add_for_broadcast!(broadcast, delta_bytes: 1_000, now: october)
      described_class.add_for_broadcast!(broadcast, delta_bytes: 2_000, now: october + 2)
      total = described_class.add_for_broadcast!(broadcast, delta_bytes: 3_000, now: october + 4)

      expect(total).to eq(6_000)
      expect(Broadcast.find(broadcast.id).sent_bytes).to eq(6_100)
    end

    it "古いメモリ上のレコードでも、DB の行へ加算する（メモリ上の値に積み上げない）" do
      stale = Broadcast.find(broadcast.id)
      described_class.add_for_broadcast!(broadcast, delta_bytes: 1_000, now: october)

      described_class.add_for_broadcast!(stale, delta_bytes: 500, now: october)

      expect(Broadcast.find(broadcast.id).sent_bytes).to eq(1_600)
      expect(stale.sent_bytes).to eq(1_600)
    end

    it "別の配信の送出量も、同じ月の積算へ加算する（配信の sent_bytes は別々）" do
      other = create(:broadcast, sent_bytes: 0)

      described_class.add_for_broadcast!(broadcast, delta_bytes: 1_000, now: october)
      total = described_class.add_for_broadcast!(other, delta_bytes: 2_000, now: october)

      expect(total).to eq(3_000)
      expect(Broadcast.find(broadcast.id).sent_bytes).to eq(1_100)
      expect(Broadcast.find(other.id).sent_bytes).to eq(2_000)
    end

    it "終了した配信の最後の報告も、積算に入る（送出した分は、予算に数える）" do
      ended = create(:broadcast, :ended, sent_bytes: 10)

      described_class.add_for_broadcast!(ended, delta_bytes: 90, now: october)

      expect(Broadcast.find(ended.id).sent_bytes).to eq(100)
      expect(TransferMonth.find("2026-10").sent_bytes).to eq(90)
    end

    it "0 バイトの報告も受け付ける（変わらない）" do
      expect(described_class.add_for_broadcast!(broadcast, delta_bytes: 0, now: october)).to eq(0)

      expect(Broadcast.find(broadcast.id).sent_bytes).to eq(100)
    end

    describe "暦月は JST（00:00 区切り。利用日の 03:00 区切りではない）" do
      {
        "JST 10 月 31 日 23:59:59（UTC 14:59:59）" => [ Time.utc(2026, 10, 31, 14, 59, 59), "2026-10" ],
        "JST 11 月 1 日 00:00:00（UTC 15:00:00）" => [ Time.utc(2026, 10, 31, 15, 0, 0), "2026-11" ],
        "JST 11 月 1 日 02:59（利用日はまだ 10 月 31 日。暦月は 11 月）" => [ Time.utc(2026, 10, 31, 17, 59, 0), "2026-11" ],
        "JST 11 月 1 日 03:00" => [ Time.utc(2026, 10, 31, 18, 0, 0), "2026-11" ],
        "JST 1 月 1 日 00:00（年をまたぐ）" => [ Time.utc(2026, 12, 31, 15, 0, 0), "2027-01" ],
        "JST 12 月 31 日 23:59:59" => [ Time.utc(2026, 12, 31, 14, 59, 59), "2026-12" ]
      }.each do |label, (time, expected_month)|
        it "#{label}: #{expected_month} の積算へ加算する" do
          described_class.add_for_broadcast!(broadcast, delta_bytes: 77, now: time)

          expect(TransferMonth.pluck(:month, :sent_bytes)).to eq([ [ expected_month, 77 ] ])
        end
      end

      it "UTC 以外のタイムゾーンの時刻（TimeWithZone）でも、同じ月になる" do
        zoned = Time.utc(2026, 10, 31, 15, 0, 0).in_time_zone("America/Los_Angeles") # 太平洋時間では 10 月 31 日の午前 8 時

        described_class.add_for_broadcast!(broadcast, delta_bytes: 5, now: zoned)

        expect(TransferMonth.pluck(:month)).to eq([ "2026-11" ])
      end
    end

    describe "不正な引数は、何も変えずに ArgumentError" do
      {
        "負の増分" => { delta_bytes: -1 },
        "小数の増分" => { delta_bytes: 1.5 },
        "文字列の増分" => { delta_bytes: "10" },
        "nil の増分" => { delta_bytes: nil },
        "時刻が nil" => { now: nil },
        "時刻が Date" => { now: Date.new(2026, 10, 7) },
        "時刻が文字列" => { now: "2026-10-07T04:30:00Z" }
      }.each do |label, override|
        it "#{label}" do
          arguments = { delta_bytes: 10, now: october }.merge(override)

          expect { described_class.add_for_broadcast!(broadcast, **arguments) }.to raise_error(ArgumentError)
          expect(Broadcast.find(broadcast.id).sent_bytes).to eq(100)
          expect(TransferMonth.count).to eq(0)
        end
      end

      it "配信が保存されていない（new）なら ArgumentError" do
        expect { described_class.add_for_broadcast!(build(:broadcast), delta_bytes: 10, now: october) }.to raise_error(ArgumentError)
        expect(TransferMonth.count).to eq(0)
      end

      it "配信が Broadcast でなければ ArgumentError" do
        expect { described_class.add_for_broadcast!(nil, delta_bytes: 10, now: october) }.to raise_error(ArgumentError)
        expect { described_class.add_for_broadcast!(broadcast.id, delta_bytes: 10, now: october) }.to raise_error(ArgumentError)
      end
    end

    it "配信が DB に無いとき（別の経路で除かれた）は ActiveRecord::RecordNotFound。月次の積算へも加算しない" do
      gone = create(:broadcast)
      Broadcast.where(id: gone.id).delete_all

      expect { described_class.add_for_broadcast!(gone, delta_bytes: 10, now: october) }.to raise_error(ActiveRecord::RecordNotFound)
      expect(TransferMonth.count).to eq(0)
    end

    it "外側のトランザクションに参加する（SAVEPOINT を作らない。requires_new を使わない）" do
      statements = nil
      # スペックのトランザクションは、参加できない（joinable: false）ため、最初の transaction は保存点になる。
      # 呼び出し側のトランザクションを開いたあとの、サービスの呼び出しだけを記録する
      ActiveRecord::Base.transaction do
        Broadcast.exists?(broadcast.id) # トランザクションは、最初の SQL で実体になる（遅延）。記録の前に、外側を実体にしておく
        statements = capture_every_sql { described_class.add_for_broadcast!(broadcast, delta_bytes: 10, now: october) }
      end

      expect(statements.grep(/SAVEPOINT/)).to be_empty
      expect(statements.grep(/\ABEGIN|\ACOMMIT/)).to be_empty
    end

    it "外側のトランザクションを巻き戻すと、配信の加算も、月次の積算も、ともに取り消される" do
      ActiveRecord::Base.transaction(requires_new: true) do
        described_class.add_for_broadcast!(broadcast, delta_bytes: 10, now: october)
        raise ActiveRecord::Rollback
      end

      expect(Broadcast.find(broadcast.id).sent_bytes).to eq(100)
      expect(TransferMonth.count).to eq(0)
    end

    it "配信の行を FOR UPDATE で確保してから加算する（同じ配信の同時の報告が、積み上げを失わない）" do
      statements = capture_sql { described_class.add_for_broadcast!(broadcast, delta_bytes: 10, now: october) }

      expect(statements.grep(/FROM "broadcasts".* FOR UPDATE/m).size).to eq(1)
    end
  end
end
