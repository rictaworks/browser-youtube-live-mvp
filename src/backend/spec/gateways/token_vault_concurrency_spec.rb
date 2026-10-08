require "rails_helper"
require "support/model_support"

# TokenVault の同時の操作（issue #10。requirements.md 7.3・14 章）。
#   - 同じアカウントのアクセストークンの更新は、同時に何本呼んでも、Google への通信は 1 回（重複排除）。
#     要求ごとに作る TokenVault が、プロセスで共有するキャッシュを使えば、別のインスタンスからでも 1 回
#   - 別のアカウントの更新は、互いを待たずに並行する
#   - 恒久的な失敗（取り消し）は、待っていた呼び出しも TokenRevoked になり、Google への通信は 1 回
#   - 更新トークンの保存は、別のプロセスと競合して一意制約に当たっても、1 件のまま成功する
#
# 別の接続からは、未コミットの行が見えない。このグループは、トランザクションで包まず、実際にコミットする。
# 例が作った行（アカウント。接続は、連鎖で消える）は、各例の前後で、SQL で整理する。
RSpec.describe "TokenVault の同時の操作" do
  self.use_transactional_tests = false

  let(:key) { "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }
  let(:now) { Time.utc(2026, 10, 8, 3, 0, 0) }
  let(:cache) { TokenVault::AccessTokenCache.new }
  let(:width) { [ ActiveRecord::Base.connection_pool.size - 1, 2 ].max }

  # Google への通信の代わり。呼び出しの回数・同時に動いた最大数を数える（スレッドセーフ）。delay 秒かけて、結果を返す
  let(:client_class) do
    Class.new do
      attr_reader :refresh_calls, :max_running

      def initialize(delay:, failure: nil)
        @delay = delay
        @failure = failure
        @mutex = Mutex.new
        @refresh_calls = 0
        @running = 0
        @max_running = 0
      end

      def refresh(refresh_token:)
        number = @mutex.synchronize do
          @refresh_calls += 1
          @running += 1
          @max_running = [ @max_running, @running ].max
          @refresh_calls
        end
        sleep @delay
        raise @failure if @failure

        GoogleTokenClient::Tokens.new(access_token: "ya29.dummy-#{number}-#{refresh_token.hash.abs}", expires_in: 3600)
      ensure
        @mutex.synchronize { @running -= 1 }
      end

      def revoke(token:)
        :revoked
      end
    end
  end

  def create_committed_user
    create(:user, google_sub: "dummy-google-sub-vault-#{SecureRandom.hex(8)}").tap { |user| created_user_ids << user.id }
  end

  def created_user_ids
    @created_user_ids ||= []
  end

  def clean_rows!
    User.where(id: created_user_ids).delete_all
  end

  after { clean_rows! }

  describe "アクセストークンの更新の重複排除" do
    it "同じアカウントを同時に何本呼んでも、Google への通信は 1 回で、全員が同じトークンを得る" do
      client = client_class.new(delay: 0.2)
      vault = TokenVault.new(key: key, token_client: client, cache: cache)
      user = create_committed_user
      vault.store(user_id: user.id, refresh_token: "1//dummy-refresh-token", now: now)

      results = run_concurrently(width) { vault.access_token(user_id: user.id, now: now) }

      expect(results.map(&:first)).to all(eq(:ok))
      expect(results.map(&:last).uniq.size).to eq(1)
      expect(client.refresh_calls).to eq(1)
    end

    it "別の TokenVault のインスタンス（要求ごとに作る）が、共有のキャッシュを使えば、同じく 1 回" do
      client = client_class.new(delay: 0.2)
      user = create_committed_user
      TokenVault.new(key: key, token_client: client, cache: cache).store(user_id: user.id, refresh_token: "1//dummy-refresh-token", now: now)

      results = run_concurrently(width) { TokenVault.new(key: key, token_client: client, cache: cache).access_token(user_id: user.id, now: now) }

      expect(results.map(&:first)).to all(eq(:ok))
      expect(results.map(&:last).uniq.size).to eq(1)
      expect(client.refresh_calls).to eq(1)
    end

    it "キャッシュを共有しない別のインスタンスは、それぞれ更新する（共有が重複排除の条件）" do
      client = client_class.new(delay: 0)
      user = create_committed_user
      TokenVault.new(key: key, token_client: client, cache: cache).store(user_id: user.id, refresh_token: "1//dummy-refresh-token", now: now)

      run_concurrently(2) { TokenVault.new(key: key, token_client: client).access_token(user_id: user.id, now: now) }

      expect(client.refresh_calls).to eq(2)
    end

    it "別のアカウントの更新は、互いを待たずに並行する（同時に動いた通信が 2 本以上）。アカウントごとに 1 回" do
      client = client_class.new(delay: 0.3)
      vault = TokenVault.new(key: key, token_client: client, cache: cache)
      users = Array.new(width) { create_committed_user }
      users.each { |user| vault.store(user_id: user.id, refresh_token: "1//dummy-refresh-token-#{user.id}", now: now) }

      results = run_concurrently(width) { |index| vault.access_token(user_id: users.fetch(index).id, now: now) }

      expect(results.map(&:first)).to all(eq(:ok))
      expect(results.map(&:last).uniq.size).to eq(width)
      expect(client.refresh_calls).to eq(width)
      expect(client.max_running).to be >= 2
    end

    it "更新したあとは、待っていなかった呼び出しも、Google を呼ばずに再利用する" do
      client = client_class.new(delay: 0.05)
      vault = TokenVault.new(key: key, token_client: client, cache: cache)
      user = create_committed_user
      vault.store(user_id: user.id, refresh_token: "1//dummy-refresh-token", now: now)
      vault.access_token(user_id: user.id, now: now)

      results = run_concurrently(width) { vault.access_token(user_id: user.id, now: now + 100) }

      expect(results.map(&:first)).to all(eq(:ok))
      expect(client.refresh_calls).to eq(1)
    end
  end

  describe "恒久的な失敗（取り消し）の最中の同時の呼び出し" do
    it "待っていた呼び出しも TokenRevoked になり、Google への通信は 1 回だけ。接続状態は revoked" do
      failure = YouTubeErrors::TokenRevoked.new(call_kind: :token_refresh, status: 400, reason: "invalid_grant")
      client = client_class.new(delay: 0.2, failure: failure)
      vault = TokenVault.new(key: key, token_client: client, cache: cache)
      user = create_committed_user
      vault.store(user_id: user.id, refresh_token: "1//dummy-refresh-token", now: now)

      results = run_concurrently(width) { vault.access_token(user_id: user.id, now: now) }

      expect(results.map(&:first)).to all(eq(:error))
      expect(results.map { |_, error| error.class }).to all(eq(YouTubeErrors::TokenRevoked))
      expect(client.refresh_calls).to eq(1)
      expect(YoutubeConnection.find_by!(user_id: user.id).state).to eq("revoked")
    end
  end

  describe "更新トークンの保存の競合" do
    it "別のプロセスのように、キャッシュ（排他）を共有しない保存が同時に来ても、接続は 1 件のまま、全員が成功する" do
      client = client_class.new(delay: 0)
      user = create_committed_user

      results = run_concurrently(width) do |index|
        TokenVault.new(key: key, token_client: client).store(user_id: user.id, refresh_token: "1//dummy-refresh-token-#{index}", now: now)
      end

      expect(results.map(&:first)).to all(eq(:ok))
      expect(YoutubeConnection.where(user_id: user.id).count).to eq(1)
      readable = TokenVault.new(key: key, token_client: client)
      expect(readable.access_token(user_id: user.id, now: now)).to start_with("ya29.dummy-")
    end

    it "同じプロセス（共有のキャッシュ）の同時の保存は、直列になり、接続は 1 件のまま" do
      vault = TokenVault.new(key: key, token_client: client_class.new(delay: 0), cache: cache)
      user = create_committed_user

      results = run_concurrently(width) { |index| vault.store(user_id: user.id, refresh_token: "1//dummy-refresh-token-#{index}", now: now).id }

      expect(results.map(&:first)).to all(eq(:ok))
      expect(results.map(&:last).uniq.size).to eq(1)
      expect(YoutubeConnection.where(user_id: user.id).count).to eq(1)
    end
  end
end
