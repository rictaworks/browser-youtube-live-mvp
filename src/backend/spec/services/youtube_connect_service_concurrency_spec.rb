require "rails_helper"
require "timeout"
require "support/youtube_connect_support"

# YouTube 接続の同時の操作（issue #11。requirements.md 7.3・14 章。#10 のレビューの申し送り）。
#   - 接続の成立（更新トークンの保存・状態・ストリームの識別子の破棄）と、アクセストークンの取得・再確認が、同じアカウントで重なっても、デッドロックしない
#     （接続の行ロックを持ったまま、TokenVault を呼ばない。TokenVault は、アカウントごとの排他のあとで行をロックする。逆の順序は、デッドロックし得る）
#   - 同じアカウントで、接続が同時に成立しても（2 つのタブ）、接続の行は 1 件のまま
#   - 別のアカウントの接続は、互いに影響しない
#   - 同じアカウントのチャンネル名の取得は、同時に何本呼んでも、YouTube への確認は 1 回分（共通枠の消費を重ねない）
#
# 別の接続からは、未コミットの行が見えない。このグループは、トランザクションで包まず、実際にコミットする。
# 例が作った行（アカウント。接続は、連鎖で消える）と台帳の行は、各例の前後で、SQL で整理する。時刻は、他のスペックと重ならない未来に固定する。
RSpec.describe YouTubeConnectService, "（同時の操作）" do
  self.use_transactional_tests = false

  include LedgerSupport
  include YouTubeConnectSupport
  include ActiveSupport::Testing::TimeHelpers
  include_context "YouTube 接続の環境"

  let(:now) { Time.utc(2036, 3, 1, 3, 0, 0) }
  let(:quota_date) { UsageCalendar.quota_date(now) }
  let(:deadline_seconds) { 60 }

  before do
    clean_committed_rows!(quota_dates: [ quota_date ])
    travel_to(now)
  end

  after do
    travel_back
    clean_committed_rows!(quota_dates: [ quota_date ])
  end

  def committed_connection(account, state: "connected")
    connection = token_vault.store(user_id: account.id, refresh_token: "1//dummy-refresh-token-#{SecureRandom.hex(4)}", now: now - 1.day)
    connection.update!(state: state, youtube_stream_id: "dummy-stream-id-#{SecureRandom.hex(4)}", stream_verified_at: now - 1.day)
    connection.reload
  end

  # 時間内に終わらなければ（デッドロック・待ち続け）、失敗にする
  def within_deadline(&block)
    Timeout.timeout(deadline_seconds, &block)
  end

  # count 本のスレッドを同時に開始する（LedgerSupport#run_threads）。各スレッドの接続に、行ロックの待ちの上限（PostgreSQL の lock_timeout）を設ける。
  # Ruby の排他（TokenVault のアカウントごとの排他）と DB の行ロックを、逆の順に待ち合う（デッドロック）と、どちらも永遠に待つ
  # （PostgreSQL は、Ruby の排他の待ちを検知できない）。行ロックの待ちに上限を設ければ、止まらずに、スレッドの例外
  # （ActiveRecord::LockWaitTimeout）になり、例の失敗として検出できる。止まると、例の後の整理が終わらず、コミット済みの行が残り、
  # ほかのスペックの「接続の行は 0 件」の確認まで落とす。正しい実装の行ロックの待ちは数ミリ秒なので、上限には届かない
  def bounded_threads(count, lock_timeout: "10s")
    run_threads(count) do |index|
      connection = ActiveRecord::Base.connection
      connection.execute("SET lock_timeout = '#{lock_timeout}'")
      begin
        yield index
      ensure
        connection.execute("RESET lock_timeout")
      end
    end
  end

  # 失敗したスレッドの例外のクラス名（失敗の表示用。メッセージは出さない）
  def failure_classes(results)
    results.select { |status, _| status == :error }.map { |_, error| error.class.name }.join(",")
  end

  describe "同じアカウントの、成立・アクセストークンの取得・再確認が重なる" do
    it "どれも例外なく終わる（デッドロックしない）。接続の行は 1 件で、成立の更新（ストリームの識別子の破棄）が反映されている" do
      user = create_tracked_user
      committed_connection(user)
      service = connect_service
      vault = token_vault
      flows = Array.new(2) { begin_connect(user, service: service) }
      codes = flows.map { |flow| grant_code(flow) }

      results = within_deadline do
        bounded_threads(4) do |index|
          case index
          when 0, 1 then complete_connect(flows.fetch(index), code: codes.fetch(index), service: service)
          when 2 then vault.access_token(user_id: user.id, now: now)
          else service.recheck(user: user, now: now)
          end
        end
      end

      expect(results.map(&:first)).to eq(Array.new(4) { :ok }), failure_classes(results)
      expect(YoutubeConnection.owned_by(user).count).to eq(1)
      expect(YoutubeConnection.owned_by(user).sole).to have_attributes(state: "connected", youtube_stream_id: nil, stream_verified_at: nil)
    end

    it "繰り返しても、デッドロックしない（成立と、アクセストークンの取得・再確認を、20 回ずつ重ねる）" do
      user = create_tracked_user
      committed_connection(user)
      service = connect_service
      vault = token_vault
      attempts = Array.new(4) { begin_connect(user, service: service) }
      codes = attempts.map { |flow| grant_code(flow) }

      results = within_deadline do
        bounded_threads(4) do |index|
          complete_connect(attempts.fetch(index), code: codes.fetch(index), service: service) if index.even?
          20.times { |round| round.even? ? vault.access_token(user_id: user.id, now: now) : service.recheck(user: user, now: now) }
        end
      end

      expect(results.map(&:first)).to eq(Array.new(4) { :ok }), failure_classes(results)
      expect(YoutubeConnection.owned_by(user).count).to eq(1)
    end
  end

  describe "同じアカウントの、成立と、別の経路の更新トークンの保存（TokenVault#store を直接呼ぶ経路）が重なる" do
    it "デッドロックしない（成立が、接続の行ロックを持ったまま TokenVault を呼ぶと、別の経路の store と、行ロックとアカウントごとの排他を、逆の順に待ち合う）" do
      user = create_tracked_user
      committed_connection(user)
      service = connect_service
      vault = token_vault
      flows = Array.new(2) { begin_connect(user, service: service) }
      codes = flows.map { |flow| grant_code(flow) }

      results = within_deadline do
        bounded_threads(4) do |index|
          case index
          when 0, 1
            complete_connect(flows.fetch(index), code: codes.fetch(index), service: service)
          else
            5.times { vault.store(user_id: user.id, refresh_token: "1//dummy-direct-refresh-token-#{index}", now: now) }
          end
        end
      end

      expect(results.map(&:first)).to eq(Array.new(4) { :ok }), failure_classes(results)
      expect(YoutubeConnection.owned_by(user).count).to eq(1)
    end
  end

  describe "同じアカウントで、接続が同時に成立する（2 つのタブ）" do
    it "接続を持たないアカウント: 両方が成立し、接続の行は 1 件（一意制約に当たっても、1 回やり直して成功する）" do
      user = create_tracked_user
      service = connect_service
      flows = Array.new(2) { begin_connect(user, service: service) }
      codes = flows.map { |flow| grant_code(flow) }

      results = within_deadline do
        bounded_threads(2) { |index| complete_connect(flows.fetch(index), code: codes.fetch(index), service: service) }
      end

      expect(results.map(&:first)).to eq([ :ok, :ok ])
      expect(results.map { |_, completion| completion.result }).to eq(%w[ connected connected ])
      expect(YoutubeConnection.owned_by(user).count).to eq(1)
    end

    it "最後に成立した更新トークンで、アクセストークンを取得できる（暗号文が壊れていない）" do
      user = create_tracked_user
      service = connect_service
      flows = Array.new(2) { begin_connect(user, service: service) }
      codes = flows.map { |flow| grant_code(flow) }

      within_deadline { bounded_threads(2) { |index| complete_connect(flows.fetch(index), code: codes.fetch(index), service: service) } }

      expect(token_vault.access_token(user_id: user.id, now: now)).to start_with("fake-access-token-")
    end
  end

  describe "別のアカウントの接続は、互いに影響しない" do
    it "同時に成立させても、アカウントごとに 1 件。それぞれの暗号文で、アクセストークンを取得できる。チャンネル名は、混ざらない" do
      users = Array.new(4) { create_tracked_user }
      service = connect_service
      flows = users.map { |account| begin_connect(account, service: service) }
      codes = flows.map { |flow| grant_code(flow) }

      results = within_deadline do
        bounded_threads(4) { |index| complete_connect(flows.fetch(index), code: codes.fetch(index), service: service) }
      end

      expect(results.map(&:first)).to eq(Array.new(4) { :ok })
      users.each do |account|
        expect(YoutubeConnection.owned_by(account).count).to eq(1)
        expect(channel_names.cached(account.id)).to eq("Fake Channel")
      end
      expect(YoutubeConnection.where(user_id: users.map(&:id)).pluck(:refresh_token_ciphertext).uniq.size).to eq(4)
    end

    it "あるアカウントの成立が、別のアカウントの接続の行・ストリームの識別子を変えない" do
      user = create_tracked_user
      other = create_tracked_user
      other_connection = committed_connection(other)
      before = other_connection.reload.slice(:state, :refresh_token_ciphertext, :youtube_stream_id)
      service = connect_service
      flow = begin_connect(user, service: service)

      within_deadline { complete_connect(flow, code: grant_code(flow), service: service) }

      expect(other_connection.reload.slice(:state, :refresh_token_ciphertext, :youtube_stream_id)).to eq(before)
    end
  end

  describe "チャンネル名の取得" do
    it "同じアカウントを同時に何本呼んでも、YouTube への確認は 1 回分（共通枠 2 ユニット）。全員が同じ名前を得る" do
      user = create_tracked_user
      committed_connection(user)
      service = connect_service

      results = within_deadline { bounded_threads(4) { service.channel_title(user) } }

      expect(results.map(&:first)).to eq(Array.new(4) { :ok })
      expect(results.map(&:last).uniq).to eq([ "Fake Channel" ])
      expect(QuotaEntry.where(quota_date: quota_date, bucket: "common").sum(:units)).to eq(2)
    end

    it "別々のアカウントは、互いに待たずに取得できる（アカウントごとに 2 ユニット）" do
      users = Array.new(4) { create_tracked_user }
      users.each { |account| committed_connection(account) }
      service = connect_service

      results = within_deadline { bounded_threads(4) { |index| service.channel_title(users.fetch(index)) } }

      expect(results.map(&:last)).to eq(Array.new(4) { "Fake Channel" })
      expect(QuotaEntry.where(quota_date: quota_date, bucket: "common").sum(:units)).to eq(8)
    end
  end
end
