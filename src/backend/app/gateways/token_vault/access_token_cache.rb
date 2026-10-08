class TokenVault
  # アクセストークンのメモリ上のキャッシュ（issue #10。requirements.md 7.3）。プロセス内にだけ置く（永続化しない）。スレッドセーフ。
  #
  #   fetch        期限の margin_seconds 前までは使い回す（now < 期限 - margin_seconds）。過ぎたら nil（呼び出し側が更新する）。
  #                過ぎたトークンは、取り出すときに捨てる（メモリに残さない）
  #   put          アカウントのトークンを置く（複製して凍結する）
  #   delete       そのアカウントのトークンを捨てる。clear はすべて
  #   synchronize  アカウントごとの排他。同じアカウントの更新（Google への通信）を 1 回にまとめる。別のアカウントは並行できる
  #
  # プロセスで 1 つを共有する（要求ごとに作る TokenVault が、同じキャッシュを使う。YouTubeServices が渡す）。
  # 時刻は引数で受け取る（実時計を読まない）。トークンを、inspect・to_s・pretty_inspect に出さない（アカウントの識別子も出さない）。
  class AccessTokenCache
    # 1 件。トークンは秘密なので、inspect に出さない
    class Entry
      attr_reader :token, :expires_at

      def initialize(token, expires_at)
        @token = token
        @expires_at = expires_at
        freeze
      end

      def inspect
        "#<#{self.class.name} [FILTERED]>"
      end

      def to_s
        inspect
      end
    end
    private_constant :Entry

    def initialize
      @mutex = Mutex.new
      @entries = {}
      @user_locks = {}
    end

    # now で有効なトークン（なければ nil）。期限の margin_seconds 前からは無効
    def fetch(user_id, now:, margin_seconds:)
      key = key!(user_id)
      Preconditions.time!(now, "now")
      Preconditions.integer!(margin_seconds, "margin_seconds", min: 0)

      @mutex.synchronize do
        entry = @entries[key]
        next nil if entry.nil?
        next entry.token if now < entry.expires_at - margin_seconds

        @entries.delete(key)
        nil
      end
    end

    def put(user_id, token, expires_at:)
      key = key!(user_id)
      raise ArgumentError, "token must be a non-empty String" unless token.is_a?(String) && !token.empty?

      Preconditions.time!(expires_at, "expires_at")
      entry = Entry.new(token.dup.freeze, expires_at)
      @mutex.synchronize { @entries[key] = entry }
      nil
    end

    def delete(user_id)
      key = key!(user_id)
      @mutex.synchronize { @entries.delete(key) }
      nil
    end

    def clear
      @mutex.synchronize { @entries.clear }
      nil
    end

    def size
      @mutex.synchronize { @entries.size }
    end

    # アカウントごとの排他の中でブロックを実行し、ブロックの値を返す。同じ線のなかでの入れ子は、ThreadError（再入しない）
    def synchronize(user_id, &block)
      key = key!(user_id)
      lock = @mutex.synchronize { @user_locks[key] ||= Mutex.new }
      lock.synchronize(&block)
    end

    # トークン・アカウントの識別子を出さない
    def inspect
      "#<#{self.class.name} size=#{size}>"
    end

    private

    def key!(user_id)
      raise ArgumentError, "user_id must be a non-empty String" unless user_id.is_a?(String) && !user_id.empty?

      user_id
    end
  end
end
