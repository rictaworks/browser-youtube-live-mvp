require "rails_helper"
require "support/youtube_gateway_support"

# 窓口の記帳は、HTTP の前に、独立した短いトランザクションで確定する（issue #10 の申し送り（#9 のレビュー）。requirements.md 8.4・14 章）。
#   - HTTP を送る時点で、記帳は、すでにコミットされている（別の接続から見える）
#   - HTTP の待ちのあいだ、台帳の行（quota_days）・配信の行（broadcasts）のロックを持たない（別の接続が、すぐに確保できる）
#   - HTTP が失敗（例外）しても、記帳は残る（巻き戻らない。YouTube では実費が消費されている）
#   - 同時の呼び出しでも、記帳は失われない・枠を超えない（使用済みは、呼び出しの数の分だけ増える）
# 別の接続からは、未コミットの行が見えない。このグループは、トランザクションで包まず、実際にコミットする。
# 例が作った行は、各例の前後で、SQL で整理する（LedgerSupport#clean_committed_rows!）。
RSpec.describe YouTubeGateway do
  include LedgerSupport
  include YouTubeGatewaySupport

  self.use_transactional_tests = false

  let(:quota_date) { Date.new(2032, 5, 17) }
  let(:now) { noon_of(quota_date) }
  let(:vault) { token_vault_double }
  let(:gateway) { build_gateway(vault: vault, now: now) }
  let(:user) { create_tracked_user }
  let(:connection) { create(:youtube_connection, user: user) }
  let(:broadcast) { create_reserved_broadcast(quota_date: quota_date, user: user) }

  before do
    clean_committed_rows!(quota_dates: [ quota_date ])
    connection
    broadcast
  end

  after { clean_committed_rows!(quota_dates: [ quota_date ]) }

  # 別のスレッド（別の接続）で、ブロックを実行する
  def on_another_connection(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }.value
  end

  # 別の接続から、台帳の行・配信の行を、待たずに確保できるか（FOR UPDATE NOWAIT。確保できなければ false）
  def lockable_without_waiting?
    on_another_connection do
      ActiveRecord::Base.transaction do
        QuotaDay.lock("FOR UPDATE NOWAIT").find(quota_date)
        Broadcast.lock("FOR UPDATE NOWAIT").find(broadcast.id)
      end
      true
    rescue ActiveRecord::LockWaitTimeout, ActiveRecord::StatementInvalid
      false
    end
  end

  def stub_status_with(&observe)
    stub_request(:get, api_url("liveBroadcasts")).with(query: hash_including({})).to_return do |_request|
      observe.call
      list_response(broadcast_resource(life_cycle_status: "live"))
    end
  end

  it "HTTP を送る時点で、記帳は、すでにコミットされている（別の接続から見える）" do
    seen = nil
    stub_status_with { seen = on_another_connection { QuotaEntry.where(broadcast_id: broadcast.id).pluck(:method, :units, :bucket) } }

    gateway.fetch_status(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :prep)

    expect(seen).to eq([ [ "liveBroadcasts.list", 1, "prep" ] ])
  end

  it "HTTP の待ちのあいだ、台帳の行・配信の行のロックを持たない（別の接続が、待たずに確保できる）" do
    lockable = nil
    stub_status_with { lockable = lockable_without_waiting? }

    gateway.fetch_status(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :prep)

    expect(lockable).to be(true)
  end

  it "対照: 呼び出し側が行ロックを持っている間は、別の接続は確保できない（上の検査が、ロックの有無を見分けられる）" do
    lockable = nil
    ActiveRecord::Base.transaction do
      Broadcast.lock.find(broadcast.id)
      lockable = lockable_without_waiting?
    end

    expect(lockable).to be(false)
  end

  it "HTTP が例外（タイムアウト）で失敗しても、記帳は残る（巻き戻らない）。別の接続から見える" do
    stub_request(:get, api_url("liveBroadcasts")).with(query: hash_including({})).to_timeout

    expect { gateway.fetch_status(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :prep) }.to raise_error(YouTubeErrors::Timeout)

    expect(on_another_connection { QuotaEntry.where(broadcast_id: broadcast.id).pluck(:units) }).to eq([ 1 ])
    expect(on_another_connection { QuotaDay.find(quota_date).used_units }).to eq(1)
  end

  it "応答の解釈で例外になっても（想定外の形）、記帳は残る" do
    stub_request(:get, api_url("liveBroadcasts")).with(query: hash_including({})).to_return(json_response({ "items" => "x" }))

    expect { gateway.fetch_status(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :prep) }.to raise_error(YouTubeErrors::UnexpectedResponse)

    expect(on_another_connection { QuotaEntry.where(broadcast_id: broadcast.id).count }).to eq(1)
  end

  it "呼び出し側のトランザクションの内側では、InsideTransaction（実際のトランザクションでも）。記帳も HTTP もしない" do
    stub_request(:get, api_url("liveBroadcasts")).with(query: hash_including({})).to_return(list_response)

    ActiveRecord::Base.transaction do
      expect { gateway.fetch_status(connection, youtube_broadcast_id, broadcast: broadcast, bucket: :prep) }.to raise_error(YouTubeGateway::InsideTransaction)
    end

    expect(QuotaEntry.where(broadcast_id: broadcast.id).count).to eq(0)
    expect_no_youtube_request
  end

  it "同時の呼び出し: 記帳は失われない（使用済みは、呼び出しの数の分だけ増え、枠の残額は同じ数だけ減る）" do
    width = [ ActiveRecord::Base.connection_pool.size - 1, 2 ].max
    stub_request(:get, api_url("liveBroadcasts")).with(query: hash_including({})).to_return(list_response(broadcast_resource(life_cycle_status: "live")))

    results = run_concurrently(width) { gateway.fetch_status(connection, youtube_broadcast_id, broadcast: Broadcast.find(broadcast.id), bucket: :prep) }

    expect(results.map(&:first)).to all(eq(:ok))
    expect(QuotaEntry.where(broadcast_id: broadcast.id).count).to eq(width)
    expect(QuotaDay.find(quota_date).used_units).to eq(width)
    expect(Broadcast.find(broadcast.id).prep_reserved_units).to eq(340 - width)
    expect_ledger_consistent(quota_date)
  end

  it "同時の呼び出しが、最後の数ユニットを取り合っても、枠を超えて記帳しない。足りない呼び出しは、HTTP を送らない" do
    width = [ ActiveRecord::Base.connection_pool.size - 1, 2 ].max
    QuotaLedger.spend!(broadcast, method: "liveBroadcasts.list", units: 340 - (width - 1), bucket: :prep, result: "ok", now: now)
    request = stub_request(:get, api_url("liveBroadcasts")).with(query: hash_including({})).to_return(list_response(broadcast_resource(life_cycle_status: "live")))

    results = run_concurrently(width) { gateway.fetch_status(connection, youtube_broadcast_id, broadcast: Broadcast.find(broadcast.id), bucket: :prep) }

    succeeded = results.count { |status, _| status == :ok }
    refused = results.count { |status, error| status == :error && error.is_a?(YouTubeErrors::QuotaInsufficient) }
    expect(succeeded).to eq(width - 1)
    expect(refused).to eq(1)
    expect(request).to have_been_requested.times(width - 1)
    expect(Broadcast.find(broadcast.id).prep_reserved_units).to eq(0)
    expect_ledger_consistent(quota_date)
  end
end
