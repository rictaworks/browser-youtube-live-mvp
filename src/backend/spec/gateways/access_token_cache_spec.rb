require "rails_helper"
require "pp"

# アクセストークンのメモリ上のキャッシュ（issue #10。requirements.md 7.3）。プロセス内にだけ置く（永続化しない）。スレッドセーフ。
#   fetch        有効期限の margin 秒前までは使い回す（now < 期限 - margin）。過ぎたら nil（呼び出し側が更新する）
#   synchronize  アカウントごとの排他（同じアカウントの更新を 1 回にまとめる。別のアカウントは並行できる）
# トークンを inspect に出さない。
RSpec.describe TokenVault::AccessTokenCache do
  let(:cache) { described_class.new }
  let(:now) { Time.utc(2026, 10, 8, 3, 0, 0) }
  let(:user_id) { "7f2b8c1e-0000-4000-8000-000000000001" }
  let(:other_user_id) { "7f2b8c1e-0000-4000-8000-000000000002" }

  describe "#fetch と #put" do
    it "入れる前は nil" do
      expect(cache.fetch(user_id, now: now, margin_seconds: 60)).to be_nil
    end

    it "入れたトークンを、期限の margin 秒前まで返す。ちょうど margin 秒前（now = 期限 - margin）からは nil" do
      cache.put(user_id, "ya29.dummy-1", expires_at: now + 3600)

      [ [ 0, "ya29.dummy-1" ], [ 3538, "ya29.dummy-1" ], [ 3539, "ya29.dummy-1" ], [ 3540, nil ], [ 3541, nil ], [ 3600, nil ], [ 7200, nil ] ].each do |elapsed, expected|
        expect(cache.fetch(user_id, now: now + elapsed, margin_seconds: 60)).to eq(expected), "elapsed=#{elapsed}"
      end
    end

    it "margin_seconds が 0 なら、期限（ちょうど）の前まで返す" do
      cache.put(user_id, "ya29.dummy-1", expires_at: now + 100)

      expect(cache.fetch(user_id, now: now + 99, margin_seconds: 0)).to eq("ya29.dummy-1")
      expect(cache.fetch(user_id, now: now + 100, margin_seconds: 0)).to be_nil
    end

    it "アカウントごとに分かれる" do
      cache.put(user_id, "ya29.dummy-1", expires_at: now + 3600)
      cache.put(other_user_id, "ya29.dummy-2", expires_at: now + 3600)

      expect(cache.fetch(user_id, now: now, margin_seconds: 60)).to eq("ya29.dummy-1")
      expect(cache.fetch(other_user_id, now: now, margin_seconds: 60)).to eq("ya29.dummy-2")
    end

    it "同じアカウントへ入れ直すと、置き換わる" do
      cache.put(user_id, "ya29.dummy-1", expires_at: now + 3600)
      cache.put(user_id, "ya29.dummy-2", expires_at: now + 7200)

      expect(cache.fetch(user_id, now: now + 3600, margin_seconds: 60)).to eq("ya29.dummy-2")
    end

    it "入れたトークンを、呼び出し側の文字列の変更から守る（複製して凍結する）" do
      token = +"ya29.dummy-1"
      cache.put(user_id, token, expires_at: now + 3600)
      token << "-mutated"

      expect(cache.fetch(user_id, now: now, margin_seconds: 60)).to eq("ya29.dummy-1")
      expect(cache.fetch(user_id, now: now, margin_seconds: 60)).to be_frozen
    end

    it "期限が切れたトークンは、取り出すときに捨てる（メモリに残さない）" do
      cache.put(user_id, "ya29.dummy-1", expires_at: now + 3600)

      cache.fetch(user_id, now: now + 3600, margin_seconds: 60)

      expect(cache.size).to eq(0)
    end

    it "引数の検査: アカウント識別子・トークンは空でない文字列、期限・now は Time、margin は 0 以上の整数" do
      expect { cache.put("", "x", expires_at: now) }.to raise_error(ArgumentError, /user_id/)
      expect { cache.put(user_id, "", expires_at: now) }.to raise_error(ArgumentError, /token/)
      expect { cache.put(user_id, "x", expires_at: "later") }.to raise_error(ArgumentError, /expires_at/)
      expect { cache.fetch(nil, now: now, margin_seconds: 60) }.to raise_error(ArgumentError, /user_id/)
      expect { cache.fetch(user_id, now: "now", margin_seconds: 60) }.to raise_error(ArgumentError, /now/)
      expect { cache.fetch(user_id, now: now, margin_seconds: -1) }.to raise_error(ArgumentError, /margin_seconds/)
      expect { cache.fetch(user_id, now: now, margin_seconds: 1.5) }.to raise_error(ArgumentError, /margin_seconds/)
    end
  end

  describe "#delete と #clear と #size" do
    it "delete は、そのアカウントのトークンだけを捨てる。無くても例外にしない" do
      cache.put(user_id, "ya29.dummy-1", expires_at: now + 3600)
      cache.put(other_user_id, "ya29.dummy-2", expires_at: now + 3600)

      cache.delete(user_id)
      cache.delete(user_id)

      expect(cache.fetch(user_id, now: now, margin_seconds: 60)).to be_nil
      expect(cache.fetch(other_user_id, now: now, margin_seconds: 60)).to eq("ya29.dummy-2")
      expect(cache.size).to eq(1)
    end

    it "clear は、すべて捨てる" do
      cache.put(user_id, "ya29.dummy-1", expires_at: now + 3600)
      cache.put(other_user_id, "ya29.dummy-2", expires_at: now + 3600)

      cache.clear

      expect(cache.size).to eq(0)
    end
  end

  describe "#synchronize（アカウントごとの排他）" do
    it "ブロックの値を返す。ブロックが例外で終わっても、排他を解放する" do
      expect(cache.synchronize(user_id) { :value }).to eq(:value)
      expect { cache.synchronize(user_id) { raise "boom" } }.to raise_error("boom")
      expect(cache.synchronize(user_id) { :again }).to eq(:again)
    end

    it "同じアカウントのブロックは、同時に 1 つだけ動く" do
      running = 0
      max_running = 0
      guard = Mutex.new
      threads = Array.new(6) do
        Thread.new do
          cache.synchronize(user_id) do
            guard.synchronize do
              running += 1
              max_running = [ max_running, running ].max
            end
            sleep 0.02
            guard.synchronize { running -= 1 }
          end
        end
      end
      threads.each(&:join)

      expect(max_running).to eq(1)
    end

    it "別のアカウントのブロックは、並行して動ける（互いを待たない）" do
      both_inside = Queue.new
      release = Queue.new
      first = Thread.new do
        cache.synchronize(user_id) do
          both_inside << :first
          release.pop
        end
      end
      second = Thread.new do
        cache.synchronize(other_user_id) do
          both_inside << :second
          release.pop
        end
      end

      entered = Array.new(2) { Timeout.timeout(5) { both_inside.pop } }
      2.times { release << :go }
      [ first, second ].each(&:join)

      expect(entered).to contain_exactly(:first, :second)
    end
  end

  describe "スレッドセーフ" do
    it "多くのスレッドが同時に入れ・取り出し・捨てても、壊れない（例外にならず、最後の状態が一貫する）" do
      threads = Array.new(16) do |index|
        Thread.new do
          50.times do |round|
            id = format("7f2b8c1e-0000-4000-8000-%012d", (index + round) % 4)
            cache.put(id, "ya29.dummy-#{index}-#{round}", expires_at: now + 3600)
            cache.fetch(id, now: now, margin_seconds: 60)
            cache.delete(id) if round % 7 == 0
          end
        end
      end

      expect { threads.each(&:join) }.not_to raise_error
      expect(cache.size).to be <= 4
    end
  end

  describe "#inspect" do
    it "トークンを出さない（inspect・to_s・pretty_inspect）" do
      cache.put(user_id, "ya29.dummy-must-not-appear", expires_at: now + 3600)

      [ cache.inspect, cache.to_s, cache.pretty_inspect ].each do |text|
        expect(text).not_to include("ya29.dummy-must-not-appear")
        expect(text).not_to include(user_id)
      end
      expect(cache.inspect).to eq("#<TokenVault::AccessTokenCache size=1>")
    end
  end
end
