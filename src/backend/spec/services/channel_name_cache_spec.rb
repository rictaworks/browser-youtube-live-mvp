require "rails_helper"
require "pp"
require "support/model_support"
require "support/log_capture"

# チャンネル名のメモリ保持（issue #11。requirements.md 7.2・28.2。src/contracts/http-api.md 2.3 の channel_title）。
#   プロセス内のメモリだけに置く（DB・ログ・Rails.cache の永続ストアに書かない）。取得から最長 10 分で失効する（時計は注入）。
#   スレッドセーフ。アカウント単位で分離する。接続の解除・アカウント削除・再接続で破棄できる。
#   fetch(user_id) { 取得処理 }: キャッシュがあれば再取得を省く（共通枠を消費しない）。
RSpec.describe ChannelNameCache do
  let(:clock_state) { { now: Time.utc(2026, 10, 8, 4, 30, 0) } }
  let(:clock) { -> { clock_state[:now] } }
  let(:cache) { described_class.new(clock: clock) }
  let(:user_id) { SecureRandom.uuid }
  let(:other_user_id) { SecureRandom.uuid }
  let(:title) { "dummy-channel-title-must-not-appear" }

  def advance(seconds)
    clock_state[:now] += seconds
  end

  # 呼び出し回数を数える取得処理
  def counting(value)
    calls = []
    [ -> { calls << true && value }, calls ]
  end

  describe "失効の時間（取得から最長 10 分）" do
    it "既定の寿命は、契約の保持期間（channel_title_memory_max_minutes）の 10 分 = 600 秒" do
      expect(Contract::Limits::RETENTION.fetch("channel_title_memory_max_minutes")).to eq(10)
      expect(described_class::MAX_TTL_SECONDS).to eq(600)
      expect(described_class.new(clock: clock).ttl_seconds).to eq(600)
    end

    it "寿命は 10 分を超えて設定できない（最長 10 分）。0 以下・数値でないものも拒否" do
      expect { described_class.new(clock: clock, ttl_seconds: 601) }.to raise_error(ArgumentError, /ttl_seconds/)
      expect { described_class.new(clock: clock, ttl_seconds: 0) }.to raise_error(ArgumentError, /ttl_seconds/)
      expect { described_class.new(clock: clock, ttl_seconds: -1) }.to raise_error(ArgumentError, /ttl_seconds/)
      expect { described_class.new(clock: clock, ttl_seconds: "600") }.to raise_error(ArgumentError, /ttl_seconds/)
      expect(described_class.new(clock: clock, ttl_seconds: 600).ttl_seconds).to eq(600)
      expect(described_class.new(clock: clock, ttl_seconds: 30).ttl_seconds).to eq(30)
    end

    it "取得の 599 秒後までは、キャッシュを返す。取得処理は呼ばない" do
      fetcher, calls = counting(title)
      cache.fetch(user_id, &fetcher)

      advance(599)

      expect(cache.fetch(user_id, &fetcher)).to eq(title)
      expect(calls.size).to eq(1)
    end

    it "取得のちょうど 600 秒後に失効する（境界）。取得処理を呼び直す" do
      fetcher, calls = counting(title)
      cache.fetch(user_id, &fetcher)

      advance(600)

      expect(cache.cached(user_id)).to be_nil
      expect(cache.fetch(user_id, &fetcher)).to eq(title)
      expect(calls.size).to eq(2)
    end

    it "読み出しで寿命は延びない（取得から 10 分が最長。何度読んでも）" do
      fetcher, calls = counting(title)
      cache.fetch(user_id, &fetcher)

      5.times do
        advance(119)
        cache.fetch(user_id, &fetcher)
      end
      advance(5) # 取得から 600 秒

      expect(calls.size).to eq(1)
      expect(cache.cached(user_id)).to be_nil
    end

    it "取得し直した時刻から、改めて 10 分" do
      fetcher, = counting(title)
      cache.fetch(user_id, &fetcher)
      advance(600)
      cache.fetch(user_id, &fetcher)

      advance(599)

      expect(cache.cached(user_id)).to eq(title)
    end

    it "時計は注入されたものを使う（実時計に依存しない）" do
      real_before = Time.now
      cache.write(user_id, title)

      advance(1_000_000)

      expect(cache.cached(user_id)).to be_nil
      expect(Time.now - real_before).to be < 5
    end

    it "時計が Time を返さなければ ArgumentError（黙って通さない）" do
      broken = described_class.new(clock: -> { 123 })

      expect { broken.write(user_id, title) }.to raise_error(ArgumentError, /Time/)
      expect { broken.fetch(user_id) { title } }.to raise_error(ArgumentError, /Time/)
    end
  end

  describe "#fetch（取得処理のブロック）" do
    it "キャッシュが無ければ、取得処理を呼び、その値を返して保持する" do
      fetcher, calls = counting(title)

      expect(cache.fetch(user_id, &fetcher)).to eq(title)

      expect(calls.size).to eq(1)
      expect(cache.cached(user_id)).to eq(title)
    end

    it "キャッシュがあれば、取得処理を呼ばない（再取得を省く = 共通枠を消費しない）" do
      cache.write(user_id, title)
      fetcher, calls = counting("dummy-other-title")

      expect(cache.fetch(user_id, &fetcher)).to eq(title)

      expect(calls).to be_empty
    end

    it "取得処理が nil を返したとき（チャンネルが無いなど）: nil を返し、保持しない（次回は取得し直す）" do
      fetcher, calls = counting(nil)

      expect(cache.fetch(user_id, &fetcher)).to be_nil
      expect(cache.fetch(user_id, &fetcher)).to be_nil

      expect(calls.size).to eq(2)
      expect(cache.size).to eq(0)
    end

    it "取得処理が例外を投げたとき: そのまま伝え、保持しない。次の呼び出しは、取得し直せる（鍵の排他も解放される）" do
      expect { cache.fetch(user_id) { raise YouTubeErrors::Transient.new(call_kind: :probe_channel_lookup) } }
        .to raise_error(YouTubeErrors::Transient)

      expect(cache.cached(user_id)).to be_nil
      expect(cache.fetch(user_id) { title }).to eq(title)
    end

    it "ブロックが無ければ ArgumentError" do
      expect { cache.fetch(user_id) }.to raise_error(ArgumentError, /block/)
    end

    it "取得処理が文字列でない値を返したら ArgumentError（実装の誤りを、黙って保持しない）" do
      expect { cache.fetch(user_id) { 123 } }.to raise_error(ArgumentError, /title/)
      expect { cache.fetch(user_id) { "" } }.to raise_error(ArgumentError, /title/)
      expect(cache.size).to eq(0)
    end

    it "返す文字列は凍結されている（呼び出し側が書き換えて、保持した値を壊せない）" do
      value = cache.fetch(user_id) { +"dummy-mutable-title" }

      expect(value).to be_frozen
      expect(cache.cached(user_id)).to be_frozen
      expect { value << "x" }.to raise_error(FrozenError)
    end

    it "取得処理に渡した文字列を後から書き換えても、保持した値は変わらない（複製して保持）" do
      original = +"dummy-original-title"
      cache.write(user_id, original)

      original << "-changed"

      expect(cache.cached(user_id)).to eq("dummy-original-title")
    end
  end

  describe "アカウント単位の分離" do
    it "別のアカウントのキャッシュは返さない" do
      cache.write(user_id, title)
      fetcher, calls = counting("dummy-other-title")

      expect(cache.fetch(other_user_id, &fetcher)).to eq("dummy-other-title")

      expect(calls.size).to eq(1)
      expect(cache.cached(user_id)).to eq(title)
      expect(cache.cached(other_user_id)).to eq("dummy-other-title")
    end

    it "あるアカウントの破棄は、別のアカウントに影響しない" do
      cache.write(user_id, title)
      cache.write(other_user_id, "dummy-other-title")

      cache.delete(user_id)

      expect(cache.cached(user_id)).to be_nil
      expect(cache.cached(other_user_id)).to eq("dummy-other-title")
    end

    it "あるアカウントの失効は、別のアカウントの寿命に影響しない（それぞれの取得時刻から数える）" do
      cache.write(user_id, title)
      advance(300)
      cache.write(other_user_id, "dummy-other-title")
      advance(300) # user_id は 600 秒、other は 300 秒

      expect(cache.cached(user_id)).to be_nil
      expect(cache.cached(other_user_id)).to eq("dummy-other-title")
    end

    it "アカウント（User）も渡せる。識別子は小文字の UUID に正規化される（大文字小文字の違いで別の鍵にならない）" do
      account = create(:user)
      cache.write(account, title)

      expect(cache.cached(account.id)).to eq(title)
      expect(cache.cached(account.id.upcase)).to eq(title)
    end

    it "アカウントを特定できない値は ArgumentError（nil・空・UUID でない文字列。全員が共有する鍵にならない）" do
      [ nil, "", "  ", "not-a-uuid", 123, :symbol, [] ].each do |invalid|
        expect { cache.fetch(invalid) { title } }.to raise_error(ArgumentError)
        expect { cache.write(invalid, title) }.to raise_error(ArgumentError)
        expect { cache.cached(invalid) }.to raise_error(ArgumentError)
        expect { cache.delete(invalid) }.to raise_error(ArgumentError)
      end
      expect(cache.size).to eq(0)
    end
  end

  describe "#write・#delete・#clear" do
    it "write は、保持する（既にあれば置き換え、取得時刻を更新する）" do
      cache.write(user_id, title)
      advance(500)
      cache.write(user_id, "dummy-newer-title")
      advance(500) # 最初の write から 1000 秒、置き換えから 500 秒

      expect(cache.cached(user_id)).to eq("dummy-newer-title")
    end

    it "write は、空の文字列・文字列でない値を拒否する" do
      [ nil, "", "   ", 1, :title, [] ].each do |invalid|
        expect { cache.write(user_id, invalid) }.to raise_error(ArgumentError, /title/)
      end
    end

    it "delete は、そのアカウントの値を破棄する。次の fetch は取得処理を呼ぶ。無ければ何もしない（冪等）" do
      cache.write(user_id, title)

      expect(cache.delete(user_id)).to be_nil
      expect(cache.delete(user_id)).to be_nil

      fetcher, calls = counting("dummy-refetched-title")
      expect(cache.fetch(user_id, &fetcher)).to eq("dummy-refetched-title")
      expect(calls.size).to eq(1)
    end

    it "clear は、すべてのアカウントの値を破棄する" do
      cache.write(user_id, title)
      cache.write(other_user_id, title)

      cache.clear

      expect(cache.size).to eq(0)
    end

    it "cached は、取得処理を呼ばず、保持している値（無い・失効していれば nil）だけを返す" do
      expect(cache.cached(user_id)).to be_nil
      cache.write(user_id, title)
      expect(cache.cached(user_id)).to eq(title)
    end
  end

  describe "メモリの上限（失効した値は残らない）" do
    it "失効した値は、読み出しのとき捨てる" do
      cache.write(user_id, title)
      advance(600)

      cache.cached(user_id)

      expect(cache.size).to eq(0)
    end

    it "読まれないまま失効した値も、別のアカウントの書き込みのときに、まとめて捨てる（際限なく増えない）" do
      Array.new(50) { SecureRandom.uuid }.each { |id| cache.write(id, title) }
      expect(cache.size).to eq(50)

      advance(700)
      cache.write(user_id, title)

      expect(cache.size).to eq(1)
    end
  end

  describe "永続化しない（DB・ログ・Rails.cache）" do
    it "保持しても、DB のどの表にも、チャンネル名が現れない（全表の全列を走査する）" do
      create(:user)
      cache.write(user_id, title)
      cache.fetch(other_user_id) { "dummy-second-channel-title-must-not-appear" }

      connection = ActiveRecord::Base.connection
      dump = (connection.tables - %w[ schema_migrations ar_internal_metadata ]).map do |table|
        connection.select_all("SELECT * FROM #{connection.quote_table_name(table)}").to_a.to_s
      end.join("\n")

      expect(dump).not_to include("must-not-appear")
    end

    it "Rails.cache（アプリケーションのキャッシュのストア）を使わない" do
      expect(Rails).not_to receive(:cache)

      cache.write(user_id, title)
      cache.fetch(other_user_id) { title }
      cache.cached(user_id)
      cache.delete(user_id)
    end

    it "ログに、チャンネル名もアカウントの識別子も出さない" do
      output = capture_logs do
        cache.write(user_id, title)
        cache.fetch(other_user_id) { title }
        cache.cached(user_id)
        cache.delete(user_id)
        advance(700)
        cache.cached(other_user_id)
        cache.inspect
      end

      expect(output).not_to include(title)
      expect(output).not_to include(user_id)
      expect(output).not_to include(other_user_id)
    end

    it "inspect・to_s・pretty_inspect に、チャンネル名もアカウントの識別子も出さない" do
      cache.write(user_id, title)

      [ cache.inspect, cache.to_s, cache.pretty_inspect ].each do |text|
        expect(text).not_to include(title)
        expect(text).not_to include(user_id)
      end
      expect(cache.inspect).to eq("#<ChannelNameCache size=1>")
    end

    it "保持している値を、一覧・ハッシュとして取り出す口を持たない（取り出せるのは、アカウントを指定した 1 件だけ）" do
      expect(cache).not_to respond_to(:to_h)
      expect(cache).not_to respond_to(:to_a)
      expect(cache).not_to respond_to(:each)
      expect(cache).not_to respond_to(:values)
    end
  end

  describe "プロセスで共有する実体（shared）" do
    it "同じ実体を返す。時計は実時計（SystemClock）" do
      expect(described_class.shared).to be_equal(described_class.shared)
      expect(described_class.shared).to be_a(described_class)
    end
  end

  describe "スレッドセーフ" do
    it "同じアカウントを同時に fetch しても、取得処理は 1 回（共通枠の消費を重ねない）。全員が同じ値を得る" do
      calls = Queue.new
      gate = Queue.new
      results = Queue.new
      threads = Array.new(12) do
        Thread.new do
          gate.pop
          results << cache.fetch(user_id) do
            calls << true
            sleep 0.05
            title
          end
        end
      end
      12.times { gate << true }
      threads.each(&:join)

      expect(calls.size).to eq(1)
      expect(Array.new(results.size) { results.pop }.uniq).to eq([ title ])
    end

    it "別々のアカウントの fetch は、互いに待たない（並行して取得できる）" do
      started = Queue.new
      release = Queue.new
      first = Thread.new { cache.fetch(user_id) { started << :first && release.pop && "dummy-first-title" } }
      started.pop # first が取得処理の中にいる

      second = Thread.new { cache.fetch(other_user_id) { "dummy-second-title" } }
      finished = second.join(2) # first が解放を待つ間に、second が終わる

      expect(finished).not_to be_nil
      release << true
      first.join
      expect(cache.cached(user_id)).to eq("dummy-first-title")
      expect(cache.cached(other_user_id)).to eq("dummy-second-title")
    end

    it "多数のスレッドが write・fetch・delete・cached を同時に呼んでも、例外にならず、他のアカウントの値と混ざらない" do
      ids = Array.new(6) { SecureRandom.uuid }
      errors = Queue.new
      threads = Array.new(12) do |index|
        Thread.new do
          100.times do |round|
            id = ids.fetch((index + round) % ids.size)
            expected = "dummy-title-of-#{id}"
            case round % 4
            when 0 then cache.write(id, expected)
            when 1 then cache.fetch(id) { expected }
            when 2 then cache.delete(id)
            else
              seen = cache.cached(id)
              errors << [ id, seen ] unless seen.nil? || seen == expected
            end
          end
        rescue StandardError => error
          errors << error
        end
      end
      threads.each(&:join)

      expect(errors.size).to eq(0)
    end
  end

  describe "検査の対象外の動作" do
    it "ChannelNameCache は、HTTP・YouTube・台帳を知らない（取得処理は、呼び出し側が渡す）" do
      source = Rails.root.join("app/services/channel_name_cache.rb").read

      expect(source).not_to match(/YouTubeGateway|QuotaLedger|ExternalHttp|Net::HTTP/)
    end
  end
end
