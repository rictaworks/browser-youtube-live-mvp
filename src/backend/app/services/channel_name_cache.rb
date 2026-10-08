# チャンネル名のメモリ保持（issue #11。requirements.md 7.2・28.2。src/contracts/http-api.md 2.3 の channel_title）。
#
# アカウント画面の表示のために取得したチャンネル名を、取得から最長 10 分（契約 retention.channel_title_memory_max_minutes）、
# このプロセスのメモリにだけ保持して、YouTube の再取得（共通枠の消費）を省く。永続化しない
# （DB・ログ・Rails.cache・ファイルへ書かない。チャンネル名は個人情報に近い。28.2）。
#
# 取得に失敗したとき（取得処理が nil を返したとき。チャンネルが無い・一時的な失敗・共通枠の枯渇など）も、その結果を短時間だけ覚える
# （否定キャッシュ）。覚えている間は、取得処理（YouTube の呼び出し）を呼ばず、nil を返す。失敗した呼び出しも、共通枠（全員で共有する
# 500 ユニット）から 1〜2 ユニットを消費する。覚えないと、障害中の再読み込みや、チャンネルを削除した利用者の連打で、共通枠を使い切れてしまう。
# 覚える秒数は config/youtube_connect.yml（成功の保持より短い）。チャンネル名と同じく、永続化しない・アカウントごと・delete で消える。
#
#   fetch(user_id) { 取得処理 }  キャッシュがあれば返す（取得処理を呼ばない）。失敗を覚えている間は nil を返す（取得処理を呼ばない）。
#                                無ければ取得処理を呼び、値を保持して返す。取得処理が nil を返したとき（取得に失敗）は、nil を返し、失敗を覚える。
#                                例外は、そのまま伝え、保持も、失敗の記録もしない
#   cached(user_id)              保持しているチャンネル名（無い・失効していれば nil。失敗の記録は nil）。取得処理を呼ばない
#   write(user_id, title)        保持する（接続の成立・再確認で、チャンネル名が分かったとき。既にあれば（失敗の記録も）置き換え、取得時刻を更新する）
#   delete(user_id)              破棄する（チャンネル名も、失敗の記録も。接続の解除・アカウント削除・再接続）
#   clear                        すべて破棄する
#
# 失効: 取得（write）の時刻から ttl_seconds（既定・最長 600 秒 = 10 分）。失敗の記録は、記録から failure_ttl_seconds（設定ファイル）。
# ちょうどその秒数の後から失効する。読み出しで寿命は延びない。時計は注入する（実時計を読まない。テストで時刻を進められる）。
# スレッドセーフ: 1 つの Mutex で、保持した値の読み書きを守る。同じアカウントの fetch は、アカウントごとの排他で 1 回にまとめる
# （同時に画面を開いても、取得処理（YouTube の呼び出し）は 1 回）。別のアカウントは、互いに待たない。
# アカウント単位で分離する（鍵は、OwnerScope が検証した、小文字の UUID。nil・空・UUID でない値は ArgumentError）。
#
# 失効した値は、読み出しのときと、書き込みのときに捨てる（際限なく増えない）。
# チャンネル名・アカウントの識別子を、inspect・to_s・pretty_inspect・ログに出さない。保持している値を、一覧として取り出す口を持たない。
class ChannelNameCache
  # 保持してよい最長の秒数（契約の保持期間の 10 分）
  MAX_TTL_SECONDS = Contract::Limits::RETENTION.fetch("channel_title_memory_max_minutes") * 60
  # 設定ファイル（config/youtube_connect.yml）の名前
  CONFIG_NAME = :youtube_connect

  # 保持している 1 件。title は凍結した複製（失敗の記録は nil）。チャンネル名なので、inspect に出さない
  Entry = Data.define(:title, :expires_at) do
    def inspect
      "#<#{self.class.name} [FILTERED]>"
    end

    def to_s
      inspect
    end

    # pp・pretty_inspect も、同じ表記にする（Data の既定の pretty_print は、メンバーの値を、そのまま出す）
    def pretty_print(printer)
      printer.text(inspect)
    end
  end
  private_constant :Entry

  SHARED_LOCK = Mutex.new
  private_constant :SHARED_LOCK

  # このプロセスで、1 つのキャッシュ（Puma の 1 プロセスにつき 1 つ。実時計を使う）。永続化しない
  def self.shared
    SHARED_LOCK.synchronize { @shared ||= new }
  end

  # 失敗を覚える秒数の既定（config/youtube_connect.yml の channel_title_failure_cache_seconds）。コードに直書きしない
  def self.default_failure_ttl_seconds
    Rails.application.config_for(CONFIG_NAME).fetch(:channel_title_failure_cache_seconds)
  end

  attr_reader :ttl_seconds, :failure_ttl_seconds

  # clock は、呼び出すと現在の時刻（Time）を返すもの。ttl_seconds・failure_ttl_seconds は 1 以上 600 以下の整数（最長 10 分を超えられない）
  def initialize(clock: SystemClock.method(:now), ttl_seconds: MAX_TTL_SECONDS, failure_ttl_seconds: self.class.default_failure_ttl_seconds)
    @clock = Preconditions.callable!(clock, "clock")
    @ttl_seconds = Preconditions.integer!(ttl_seconds, "ttl_seconds", min: 1, max: MAX_TTL_SECONDS)
    @failure_ttl_seconds = Preconditions.integer!(failure_ttl_seconds, "failure_ttl_seconds", min: 1, max: MAX_TTL_SECONDS)
    @entries = {}
    @key_locks = {}
    @mutex = Mutex.new
  end

  # キャッシュがあれば返す。失敗を覚えている間は nil。無ければ、取得処理（ブロック）を呼び、チャンネル名を保持して返す
  def fetch(user_id, &fetcher)
    raise ArgumentError, "a block that fetches the channel title is required" if fetcher.nil?

    key = key!(user_id)
    known = lookup(key)
    return known.title if known

    lock_for(key).synchronize do
      # 待っているあいだに、別のスレッドが取得していれば（成功も失敗も）、それを使う（取得処理は 1 回）
      known = lookup(key)
      known ? known.title : fetch_and_store(key, &fetcher)
    end
  end

  # 保持しているチャンネル名（無い・失効していれば nil。失敗の記録は nil）
  def cached(user_id)
    lookup(key!(user_id))&.title
  end

  # チャンネル名を保持する（取得の時刻から ttl_seconds）。失敗の記録があれば置き換える
  def write(user_id, title)
    store(key!(user_id), title!(title), @ttl_seconds)
    nil
  end

  # そのアカウントの値（チャンネル名も、失敗の記録も）を破棄する。無ければ何もしない
  def delete(user_id)
    key = key!(user_id)
    @mutex.synchronize { @entries.delete(key) }
    nil
  end

  # すべてのアカウントの値を破棄する
  def clear
    @mutex.synchronize { @entries.clear }
    nil
  end

  # 保持している件数（失敗の記録を含む。失効していても、まだ捨てていないものを含む）
  def size
    @mutex.synchronize { @entries.size }
  end

  # チャンネル名・アカウントの識別子を出さない。ロックを取らない（例外の途中でも、呼べる）
  def inspect
    "#<#{self.class.name} size=#{@entries.size}>"
  end

  private

  def key!(user_id)
    OwnerScope.owner_id!(user_id)
  end

  # 失効していない 1 件（チャンネル名または失敗の記録）。失効していれば、捨てて nil
  def lookup(key)
    @mutex.synchronize do
      entry = @entries[key]
      next nil if entry.nil?
      next entry if current_time < entry.expires_at

      @entries.delete(key)
      nil
    end
  end

  # 取得処理を呼ぶ。nil は取得の失敗として覚える（nil を返す）。文字列なら保持して返す
  def fetch_and_store(key)
    value = yield
    return remember_failure(key) if value.nil?

    title = title!(value)
    store(key, title, @ttl_seconds)
    title
  end

  def remember_failure(key)
    store(key, nil, @failure_ttl_seconds)
    nil
  end

  def store(key, title, ttl_seconds)
    @mutex.synchronize do
      now = current_time
      purge_expired(now)
      @entries[key] = Entry.new(title: title, expires_at: now + ttl_seconds)
    end
  end

  # 失効した値と、使われていないアカウントごとの排他を捨てる（@mutex を持って呼ぶ）。
  # 排他は、値が無く、誰も持っていないものだけ。捨てた排他を取り直した別のスレッドと、取得処理が重なることがあるが、重なっても害は無い
  # （取得処理が 2 回になるだけ）
  def purge_expired(now)
    @entries.delete_if { |_key, entry| now >= entry.expires_at }
    @key_locks.delete_if { |key, lock| !@entries.key?(key) && !lock.locked? }
  end

  def lock_for(key)
    @mutex.synchronize { @key_locks[key] ||= Mutex.new }
  end

  # 保持するチャンネル名。空でない文字列。凍結した複製にする（呼び出し側が書き換えられない）。値は、例外に載せない
  def title!(value)
    raise ArgumentError, "title must be a non-empty String" unless value.is_a?(String) && !value.strip.empty?

    value.dup.freeze
  end

  def current_time
    now = @clock.call
    raise ArgumentError, "clock must return a Time" unless now.is_a?(Time)

    now
  end
end
