require "rails_helper"
require "support/model_support"
require "services/support/ledger_support"

# 割り当て台帳の記帳（requirements.md 8.4・15 章「割り当ての記帳」）。
#   spend!          配信に関する API 呼び出しの実費を、当該配信の予約の該当する枠から支出する。
#                   実費を使用済みへ、同額を予約中と配信の枠から取り崩し、明細を記帳する。
#                   準備・確認枠の残額が足りないときは、終了・清算枠から取り崩さず、支出しない（false）。
#                   終了・清算枠は、bucket: :settle の支出だけが使う
#   spend_common!   配信に属さない呼び出し（接続時の確認・再確認・チャンネル名の取得）を、共通枠（500）から支出する
# 割り当て日をまたいだ移し替えは quota_ledger_carry_release_spec.rb、同時の呼び出しは quota_ledger_concurrency_spec.rb。
RSpec.describe QuotaLedger do
  include LedgerSupport

  include ActiveSupport::Testing::TimeHelpers

  let(:day) { quota_day(0) }
  let(:now) { noon_of(day) }

  def spend(broadcast, units:, bucket: :prep, result: "ok", method: "liveBroadcasts.insert", at: now)
    described_class.spend!(broadcast, method: method, units: units, bucket: bucket, result: result, now: at)
  end

  def spend_common(units:, method: "channels.list", quota_date: day, result: "ok", at: now)
    described_class.spend_common!(method: method, units: units, quota_date: quota_date, result: result, now: at)
  end

  describe ".spend!（配信の予約からの支出）", :ledger do
    let!(:broadcast) { create_reserved_broadcast(quota_date: day) }

    it "準備・確認枠から支出する: 使用済みが増え、予約中と準備・確認枠の残額が、同額減る。true を返す" do
      expect(spend(broadcast, units: 50)).to be(true)

      expect(QuotaDay.find(day)).to have_attributes(used_units: 50, reserved_units: 500, common_used_units: 0)
      expect(Broadcast.find(broadcast.id)).to have_attributes(prep_reserved_units: 290, settle_reserved_units: 210)
    end

    it "終了・清算枠から支出する（bucket: :settle）: 終了・清算枠の残額が減り、準備・確認枠は変わらない" do
      expect(spend(broadcast, units: 51, bucket: :settle, method: "liveBroadcasts.transition")).to be(true)

      expect(QuotaDay.find(day)).to have_attributes(used_units: 51, reserved_units: 499)
      expect(Broadcast.find(broadcast.id)).to have_attributes(prep_reserved_units: 340, settle_reserved_units: 159)
    end

    it "明細を 1 件記帳する（割り当て日・配信・呼び出しの種別・実費・結果・枠・時刻）" do
      spend(broadcast, units: 50, method: "liveBroadcasts.insert")

      entry = QuotaEntry.find_by!(broadcast_id: broadcast.id)
      expect(entry).to have_attributes(quota_date: day, units: 50, result: "ok", bucket: "prep", called_at: now)
      expect(entry.method).to eq("liveBroadcasts.insert")
      expect(QuotaEntry.where(broadcast_id: broadcast.id).count).to eq(1)
    end

    it "メモリ上の配信にも、取り崩した後の枠の残額が反映される（変更済みの印は付かない）" do
      spend(broadcast, units: 50)
      spend(broadcast, units: 10, bucket: :settle)

      expect(broadcast).to have_attributes(prep_reserved_units: 290, settle_reserved_units: 200)
      expect(broadcast).not_to be_changed
    end

    it "枠と結果は、文字列でもよい" do
      expect(spend(broadcast, units: 1, bucket: "prep", result: "ok")).to be(true)
      expect(spend(broadcast, units: 1, bucket: "settle", result: :error)).to be(true)

      expect(QuotaEntry.where(broadcast_id: broadcast.id).pluck(:bucket, :result)).to contain_exactly(%w[ prep ok ], %w[ settle error ])
    end

    it "呼び出しが失敗（result: error）でも、実費を記帳する（使用済みが増え、枠が減る）" do
      expect(spend(broadcast, units: 50, result: "error")).to be(true)

      expect(QuotaDay.find(day).used_units).to eq(50)
      expect(Broadcast.find(broadcast.id).prep_reserved_units).to eq(290)
      expect(QuotaEntry.find_by!(broadcast_id: broadcast.id).result).to eq("error")
    end

    it "支出を重ねると、明細が積み上がり、残額が減る（記帳は、呼び出しのたびに 1 件）" do
      spend(broadcast, units: 1, method: "liveBroadcasts.list")
      spend(broadcast, units: 50, method: "liveBroadcasts.insert")
      spend(broadcast, units: 50, method: "liveBroadcasts.bind")

      expect(QuotaDay.find(day)).to have_attributes(used_units: 101, reserved_units: 449)
      expect(Broadcast.find(broadcast.id).prep_reserved_units).to eq(239)
      expect(QuotaEntry.where(broadcast_id: broadcast.id).map(&:method)).to contain_exactly("liveBroadcasts.list", "liveBroadcasts.insert", "liveBroadcasts.bind")
    end

    describe "枠の分離（終了・清算枠は、終了・清算の用途の支出だけが使う。8.4）" do
      {
        "準備・確認枠を使い切る（340）" => [ :prep, 340, true, 0, 210 ],
        "準備・確認枠より 1 多い（341）" => [ :prep, 341, false, 340, 210 ],
        "準備・確認枠の 1" => [ :prep, 1, true, 339, 210 ],
        "終了・清算枠を使い切る（210）" => [ :settle, 210, true, 340, 0 ],
        "終了・清算枠より 1 多い（211）" => [ :settle, 211, false, 340, 210 ],
        "終了・清算枠の 1" => [ :settle, 1, true, 340, 209 ]
      }.each do |label, (bucket, units, expected, prep_left, settle_left)|
        it "#{label}: #{expected ? '支出できる' : '支出しない（false）'}。残額は 準備・確認 #{prep_left} / 終了・清算 #{settle_left}" do
          expect(spend(broadcast, units: units, bucket: bucket)).to be(expected)

          expect(Broadcast.find(broadcast.id)).to have_attributes(prep_reserved_units: prep_left, settle_reserved_units: settle_left)
          expect(QuotaDay.find(day).used_units).to eq(expected ? units : 0)
        end
      end

      it "準備・確認枠を使い切ったあと、準備・確認の支出は、終了・清算枠から取り崩されず、断られる（終了・清算の支出が、不足しない）" do
        spend(broadcast, units: 340)

        expect(spend(broadcast, units: 1)).to be(false)
        expect(spend(broadcast, units: 50)).to be(false)

        expect(Broadcast.find(broadcast.id)).to have_attributes(prep_reserved_units: 0, settle_reserved_units: 210)
        expect(QuotaDay.find(day)).to have_attributes(used_units: 340, reserved_units: 210)
        expect(spend(broadcast, units: 210, bucket: :settle)).to be(true)
      end

      it "終了・清算枠を使い切っても、準備・確認枠の残額は、そのまま使える" do
        spend(broadcast, units: 210, bucket: :settle)

        expect(spend(broadcast, units: 340)).to be(true)
        expect(QuotaDay.find(day)).to have_attributes(used_units: 550, reserved_units: 0)
      end

      it "8.4 の単価表の最大の支出が、予約に収まる（準備・確認 321 ≦ 340。終了・清算 204 ≦ 210）" do
        preparation = [ 1, 50, 50, 1, 1, 50, 50, 50 ] + [ 1 ] * 24 + [ 2 ] * 12 + [ 2 ] * 10
        settlement = [ 1, 50 ] + [ 51 ] * 3

        expect(preparation.sum).to eq(321)
        expect(settlement.sum).to eq(204)
        expect(preparation.map { |units| spend(broadcast, units: units) }).to all(be(true))
        expect(settlement.map { |units| spend(broadcast, units: units, bucket: :settle) }).to all(be(true))

        expect(Broadcast.find(broadcast.id)).to have_attributes(prep_reserved_units: 19, settle_reserved_units: 6)
        expect(QuotaDay.find(day)).to have_attributes(used_units: 525, reserved_units: 25)
      end
    end

    describe "支出しない（false）とき" do
      before { spend(broadcast, units: 340) }

      it "台帳・配信を変えず、明細も作らない" do
        day_before = QuotaDay.find(day).attributes
        broadcast_before = Broadcast.find(broadcast.id).attributes
        entries_before = QuotaEntry.count

        expect(spend(broadcast, units: 1)).to be(false)

        expect(QuotaDay.find(day).attributes).to eq(day_before)
        expect(Broadcast.find(broadcast.id).attributes).to eq(broadcast_before)
        expect(QuotaEntry.count).to eq(entries_before)
      end

      it "実費の記帳でも（result: error）、残額が無ければ、記帳しない" do
        expect(spend(broadcast, units: 1, result: "error")).to be(false)

        expect(QuotaEntry.where(broadcast_id: broadcast.id).count).to eq(1)
      end

      it "理由・配信の識別子・枠・額を、警告のログへ出す。タイトルは出さない" do
        logged = []
        allow(Rails.logger).to receive(:warn) { |message| logged << message.to_s }

        spend(broadcast, units: 50)

        expect(logged.size).to eq(1)
        expect(logged.first).to include("reason=bucket_insufficient", "broadcast_id=#{broadcast.id}", "bucket=prep", "units=50", "quota_date=#{day}")
        expect(logged.first).not_to include("dummy-title")
      end
    end

    describe "予約を持たない配信（予約していない・解放済み）" do
      it "予約していない配信への支出は、断られる（false）" do
        bare = create_bare_broadcast(quota_date: day)

        expect(spend(bare, units: 1)).to be(false)
        expect(spend(bare, units: 1, bucket: :settle)).to be(false)

        expect(QuotaEntry.where(broadcast_id: bare.id).count).to eq(0)
      end

      it "解放済みの配信への支出は、断られる（false）" do
        described_class.release!(broadcast)

        expect(spend(broadcast, units: 1)).to be(false)
        expect(spend(broadcast, units: 1, bucket: :settle)).to be(false)
      end
    end

    describe "割り当て超過の印がある日（mark_exhausted!）" do
      it "進行中の配信の記帳は、続けられる（8.4）" do
        described_class.mark_exhausted!(quota_date: day)

        expect(spend(broadcast, units: 50)).to be(true)
        expect(spend(broadcast, units: 51, bucket: :settle)).to be(true)

        expect(QuotaDay.find(day)).to have_attributes(exhausted: true, used_units: 101, reserved_units: 449)
      end
    end

    describe "別の配信・別の割り当て日への影響" do
      it "別の配信の予約の枠に、触れない" do
        other = create_reserved_broadcast(quota_date: day)

        spend(broadcast, units: 340)

        expect(Broadcast.find(other.id)).to have_attributes(prep_reserved_units: 340, settle_reserved_units: 210)
        expect(QuotaDay.find(day)).to have_attributes(used_units: 340, reserved_units: 760)
      end

      it "別の割り当て日の台帳に、触れない" do
        other_day = seed_day(day + 1, used: 7, reserved: 11, common: 3)

        spend(broadcast, units: 50)

        expect(other_day.reload).to have_attributes(used_units: 7, reserved_units: 11, common_used_units: 3)
      end

      it "共通枠に、触れない" do
        spend_common(units: 100) # 予約で、台帳の行はできている。共通枠の使用済みは、記帳で作る

        spend(broadcast, units: 50)

        expect(QuotaDay.find(day).common_used_units).to eq(100)
      end
    end

    describe "時刻を省いた呼び出し（now の既定は、呼び出しの時点の時刻）" do
      it "呼び出しの時刻を、明細の called_at に記帳し、その時刻の割り当て日で、台帳へ記帳する" do
        travel_to(now) do
          expect(described_class.spend!(broadcast, method: "liveBroadcasts.list", units: 1, bucket: :prep, result: "ok")).to be(true)
        end

        entry = QuotaEntry.find_by!(broadcast_id: broadcast.id)
        expect(entry.called_at).to eq(now)
        expect(entry.quota_date).to eq(day)
      end
    end

    describe "明細に、トークン・配信キー・タイトルを残さない（method は、呼び出しの種別だけ）" do
      it "明細の列は、固定の 8 列だけ（自由な文章の列が無い）。記帳した明細の値に、配信のタイトルが現れない" do
        Broadcast.find(broadcast.id).update_columns(pending_title: "dummy-secret-title")

        spend(broadcast, units: 50, method: "liveBroadcasts.insert")

        entry = QuotaEntry.find_by!(broadcast_id: broadcast.id)
        expect(QuotaEntry.column_names).to match_array(%w[ id quota_date broadcast_id method units result bucket called_at ])
        expect(entry.attributes.values.map(&:to_s).join(" ")).not_to include("dummy-secret-title")
      end

      {
        "YouTube の API のメソッド名" => "liveBroadcasts.insert",
        "一覧取得" => "liveStreams.list",
        "チャンネルの確認" => "channels.list",
        "1 語" => "list",
        "1 文字" => "a",
        "英数字・アンダースコア・ピリオド" => "A_b.c9",
        "64 文字（上限）" => "x" * 64
      }.each do |label, kind|
        it "呼び出しの種別として通る（#{label}）" do
          expect(spend(broadcast, units: 1, method: kind)).to be(true)

          expect(QuotaEntry.find_by!(broadcast_id: broadcast.id).method).to eq(kind)
        end
      end

      {
        "空文字" => "",
        "空白だけ" => " ",
        "空白を含む（タイトルの形）" => "live broadcasts",
        "日本語（タイトルの形）" => "ライブ配信のタイトル",
        "山括弧（タイトルの形）" => "<b>title</b>",
        "ハイフンを含む（配信キーの形）" => "dummy-stream-key-1234",
        "ハイフンを含む（トークンの形）" => "ya29.dummy-access-token",
        "スラッシュを含む（更新トークンの形）" => "1//dummy-refresh-token",
        "コロンを含む" => "Bearer:dummy",
        "数字で始まる" => "1list",
        "ピリオドで始まる" => ".list",
        "アンダースコアで始まる" => "_list",
        "65 文字（上限超過）" => "x" * 65,
        "長いトークンの形（200 文字）" => "a" * 200,
        "末尾に改行" => "list\n",
        "先頭に改行" => "\nlist",
        "nil" => nil,
        "シンボル" => :list,
        "整数" => 1,
        "配列" => [ "list" ]
      }.each do |label, bad|
        it "呼び出しの種別として通らない（#{label}）: ArgumentError。台帳も明細も変えず、メッセージに値を含めない" do
          day_before = QuotaDay.find(day).attributes

          expect { spend(broadcast, units: 1, method: bad) }.to raise_error(ArgumentError) { |error|
            expect(error.message).not_to include(bad) if bad.is_a?(String) && bad.length > 3
          }

          expect(QuotaDay.find(day).attributes).to eq(day_before)
          expect(QuotaEntry.where(broadcast_id: broadcast.id).count).to eq(0)
        end
      end
    end

    describe "不正な引数は ArgumentError。何も変えない" do
      def expect_no_change
        day_before = QuotaDay.find(day).attributes
        broadcast_before = Broadcast.find(broadcast.id).attributes
        entries_before = QuotaEntry.count
        yield
        expect(QuotaDay.find(day).attributes).to eq(day_before)
        expect(Broadcast.find(broadcast.id).attributes).to eq(broadcast_before)
        expect(QuotaEntry.count).to eq(entries_before)
      end

      it "実費が、1 以上の整数でない" do
        expect_no_change do
          [ 0, -1, 1.5, "50", nil, true, 50.0 ].each do |bad|
            expect { spend(broadcast, units: bad) }.to raise_error(ArgumentError)
          end
        end
      end

      it "枠が、準備・確認（prep）・終了・清算（settle）でない（共通枠は、配信の支出に使えない）" do
        expect_no_change do
          [ :common, "common", :other, "Prep", "", nil, 1, [ :prep ] ].each do |bad|
            expect { spend(broadcast, units: 1, bucket: bad) }.to raise_error(ArgumentError)
          end
        end
      end

      it "結果が、ok・error でない" do
        expect_no_change do
          [ "OK", "success", "", nil, 1, true ].each do |bad|
            expect { spend(broadcast, units: 1, result: bad) }.to raise_error(ArgumentError)
          end
        end
      end

      it "時刻が、Time でない" do
        expect_no_change do
          [ nil, Date.new(2026, 10, 7), "2026-10-07T12:00:00Z", 0 ].each do |bad|
            expect { spend(broadcast, units: 1, at: bad) }.to raise_error(ArgumentError)
          end
        end
      end

      it "配信が、保存されていない・Broadcast でない" do
        expect_no_change do
          expect { spend(build(:broadcast), units: 1) }.to raise_error(ArgumentError)
          expect { spend(nil, units: 1) }.to raise_error(ArgumentError)
          expect { spend(broadcast.id, units: 1) }.to raise_error(ArgumentError)
        end
      end
    end

    describe "原子性" do
      it "配信の行 → 台帳の行の順に、FOR UPDATE で確保してから、書く（予約・移し替え・解放と同じ順序）" do
        statements = capture_sql { spend(broadcast, units: 50) }
        locks = statements.grep(/ FOR UPDATE/).map { |sql| sql[/FROM "(\w+)"/, 1] }

        expect(locks).to eq(%w[ broadcasts quota_days ])
      end

      it "外側のトランザクションに参加する（SAVEPOINT を作らない）" do
        statements = nil
        ActiveRecord::Base.transaction do
          User.exists?(broadcast.user_id) # トランザクションは、最初の SQL で実体になる（遅延）。記録の前に、外側を実体にしておく
          statements = capture_every_sql { spend(broadcast, units: 50) }
        end

        expect(statements.grep(/SAVEPOINT/)).to be_empty
      end

      it "外側のトランザクションを巻き戻すと、台帳・配信・明細のすべてが、取り消される" do
        ActiveRecord::Base.transaction(requires_new: true) do
          spend(broadcast, units: 50)
          raise ActiveRecord::Rollback
        end

        expect(QuotaDay.find(day)).to have_attributes(used_units: 0, reserved_units: 550)
        expect(Broadcast.find(broadcast.id)).to have_attributes(prep_reserved_units: 340, settle_reserved_units: 210)
        expect(QuotaEntry.where(broadcast_id: broadcast.id).count).to eq(0)
      end
    end
  end

  describe ".spend!（台帳が壊れているとき。呼び出し側の誤り・データの破損は、例外にする）" do
    it "配信が DB に無い: ActiveRecord::RecordNotFound。明細を作らない", ledger: false do
      gone = create_reserved_broadcast(quota_date: day)
      Broadcast.where(id: gone.id).delete_all

      expect { spend(gone, units: 1) }.to raise_error(ActiveRecord::RecordNotFound)

      expect(QuotaEntry.count).to eq(0)
    end

    it "配信の予約が、台帳の予約中を超える（台帳に載っていない予約）: QuotaPolicy::InconsistentLedger。何も記帳しない", ledger: false do
      unbooked = create(:broadcast, quota_date: day) # ファクトリの既定は、予約の枠を埋めた姿（340・210）。台帳へは載せていない

      expect { spend(unbooked, units: 50) }.to raise_error(QuotaPolicy::InconsistentLedger)

      expect(QuotaEntry.count).to eq(0)
      expect(Broadcast.find(unbooked.id)).to have_attributes(prep_reserved_units: 340, settle_reserved_units: 210)
    end
  end

  describe ".spend_common!（共通枠からの支出）", :ledger do
    it "共通枠の使用済みが増える。明細は、枠 common・配信なし。true を返す" do
      expect(spend_common(units: 1, method: "channels.list")).to be(true)

      expect(QuotaDay.find(day)).to have_attributes(common_used_units: 1, used_units: 0, reserved_units: 0)
      entry = QuotaEntry.find_by!(quota_date: day)
      expect(entry).to have_attributes(broadcast_id: nil, units: 1, result: "ok", bucket: "common", called_at: now)
      expect(entry.method).to eq("channels.list")
    end

    it "行が無い割り当て日は、行を作って記帳する" do
      expect { spend_common(units: 2, quota_date: day + 5) }.to change { QuotaDay.where(quota_date: day + 5).count }.from(0).to(1)

      expect(QuotaDay.find(day + 5).common_used_units).to eq(2)
    end

    it "結果を省くと ok。error を渡すと、実費を記帳する" do
      expect(described_class.spend_common!(method: "channels.list", units: 1, quota_date: day, now: now)).to be(true)
      expect(spend_common(units: 1, result: "error")).to be(true)

      expect(QuotaEntry.where(quota_date: day).order(:result).pluck(:result)).to eq(%w[ error ok ])
      expect(QuotaDay.find(day).common_used_units).to eq(2)
    end

    describe "共通枠 500（尽きたら、当該割り当て日の終わりまで、これらの操作を受け付けない）" do
      {
        "空から 500（ちょうど）" => [ 0, 500, true ],
        "空から 501" => [ 0, 501, false ],
        "450 のあと 50（ちょうど 500）" => [ 450, 50, true ],
        "450 のあと 51（501）" => [ 450, 51, false ],
        "499 のあと 1（ちょうど 500）" => [ 499, 1, true ],
        "500 のあと 1" => [ 500, 1, false ],
        "1 回 1 ユニットの確認" => [ 100, 1, true ]
      }.each do |label, (already, units, expected)|
        it "#{label}: #{expected ? '支出できる' : '支出しない（false）'}" do
          seed_day(day, common: already)

          expect(spend_common(units: units)).to be(expected)

          expect(QuotaDay.find(day).common_used_units).to eq(expected ? already + units : already)
        end
      end

      it "尽きた日は、台帳も明細も変えない。理由 common_exhausted を、警告のログへ出す" do
        seed_day(day, common: 500)
        day_before = QuotaDay.find(day).attributes
        entries_before = QuotaEntry.count
        logged = []
        allow(Rails.logger).to receive(:warn) { |message| logged << message.to_s }

        expect(spend_common(units: 1, method: "channels.list")).to be(false)

        expect(QuotaDay.find(day).attributes).to eq(day_before)
        expect(QuotaEntry.count).to eq(entries_before)
        expect(logged.first).to include("reason=common_exhausted", "quota_date=#{day}", "units=1", "method=channels.list")
      end

      it "尽きるのは、その割り当て日だけ。翌日は、また支出できる" do
        seed_day(day, common: 500)

        expect(spend_common(units: 1, quota_date: day + 1)).to be(true)
      end

      it "共通枠が尽きても、配信の予約からの支出は、できる（共通枠と配信の枠は、別）" do
        seed_day(day, common: 500)
        reserved = create_reserved_broadcast(quota_date: day)

        expect(spend(reserved, units: 50)).to be(true)
      end

      it "配信の予約からの支出は、共通枠を使わない（共通枠を取り崩さない）" do
        reserved = create_reserved_broadcast(quota_date: day)

        spend(reserved, units: 340)

        expect(QuotaDay.find(day).common_used_units).to eq(0)
        expect(spend_common(units: 500)).to be(true)
      end
    end

    it "配信の予約・使用済みに触れない" do
      reserved = create_reserved_broadcast(quota_date: day)
      spend(reserved, units: 50)

      spend_common(units: 10)

      expect(QuotaDay.find(day)).to have_attributes(used_units: 50, reserved_units: 500, common_used_units: 10)
      expect(Broadcast.find(reserved.id)).to have_attributes(prep_reserved_units: 290, settle_reserved_units: 210)
    end

    it "割り当て超過の印がある日にも、共通枠の範囲で記帳できる（印は、新規の予約を止めるだけ）" do
      described_class.mark_exhausted!(quota_date: day)

      expect(spend_common(units: 1)).to be(true)
    end

    it "時刻を省くと、呼び出しの時刻を called_at に記帳する" do
      travel_to(now) do
        expect(described_class.spend_common!(method: "channels.list", units: 1, quota_date: day)).to be(true)
      end

      expect(QuotaEntry.find_by!(quota_date: day).called_at).to eq(now)
    end

    describe "不正な引数は ArgumentError。何も変えない" do
      it "呼び出しの種別が、識別子の形でない（タイトル・トークンの形）" do
        [ "", "live broadcasts", "ライブ", "dummy-key-1", "x" * 65, nil, :list ].each do |bad|
          expect { spend_common(units: 1, method: bad) }.to raise_error(ArgumentError)
        end
        expect(QuotaEntry.count).to eq(0)
      end

      it "実費・割り当て日・結果・時刻が不正" do
        [ 0, -1, 1.5, "1", nil ].each { |bad| expect { spend_common(units: bad) }.to raise_error(ArgumentError) }
        [ nil, "2026-10-07", Time.utc(2026, 10, 7) ].each { |bad| expect { spend_common(units: 1, quota_date: bad) }.to raise_error(ArgumentError) }
        [ "OK", nil, 1 ].each { |bad| expect { spend_common(units: 1, result: bad) }.to raise_error(ArgumentError) }
        [ nil, Date.new(2026, 10, 7), "now" ].each { |bad| expect { spend_common(units: 1, at: bad) }.to raise_error(ArgumentError) }
        expect(QuotaEntry.count).to eq(0)
        expect(QuotaDay.count).to eq(0)
      end
    end

    describe "原子性" do
      it "台帳の行を FOR UPDATE で確保してから、書く" do
        statements = capture_sql { spend_common(units: 1) }

        expect(statements.grep(/FROM "quota_days".* FOR UPDATE/m).size).to eq(1)
      end

      it "外側のトランザクションに参加し（SAVEPOINT を作らない）、巻き戻すと取り消される" do
        statements = nil
        ActiveRecord::Base.transaction do
          QuotaDay.exists?(day) # トランザクションは、最初の SQL で実体になる（遅延）。記録の前に、外側を実体にしておく
          statements = capture_every_sql { spend_common(units: 1) }
        end
        expect(statements.grep(/SAVEPOINT/)).to be_empty

        ActiveRecord::Base.transaction(requires_new: true) do
          spend_common(units: 1, quota_date: day + 1)
          raise ActiveRecord::Rollback
        end
        expect(QuotaDay.find_by(quota_date: day + 1)).to be_nil
        expect(QuotaEntry.where(quota_date: day + 1).count).to eq(0)
      end
    end
  end
end
