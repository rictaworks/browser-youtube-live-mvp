module QuotaLedger
  # QuotaLedger の公開メソッドの引数の検査。違反は ArgumentError（黙って変換しない・既定値で補わない）。
  #
  # メッセージは ASCII で、型の名前と範囲だけを載せる。呼び出しの種別（method）の値は、載せない
  # （種別の欄に、タイトル・トークン・配信キーが誤って渡されても、例外のメッセージ・ログへ出さないため）。
  module Arguments
    # 呼び出しの種別（quota_entries.method）の形。YouTube の API のメソッド名（"liveBroadcasts.insert" など）を想定した、
    # 英字で始まり、英数字・アンダースコア・ピリオドだけの、64 文字までの識別子。
    # 空白・日本語・山括弧・ハイフン・スラッシュを含む文字列（タイトル・配信キー・トークンの形）は、通さない
    # （台帳の明細に、トークン・配信キー・タイトルを残さない。issue #9。requirements.md 6.1・7.3・10.1）。
    METHOD_PATTERN = /\A[A-Za-z][A-Za-z0-9_.]{0,63}\z/

    # 配信の予約から支出する枠（準備・確認枠・終了・清算枠）。共通枠は、spend_common! だけが使う
    BUCKETS = QuotaPolicy::BUCKETS.map(&:to_s).freeze

    # 共通枠（配信に属さない呼び出し）の、明細の枠の符号（quota_entries.bucket。DB の CHECK 制約の符号）
    COMMON_BUCKET = "common".freeze

    class << self
      # 保存済みの Broadcast。
      def broadcast!(broadcast)
        Preconditions.kind!(broadcast, Broadcast, "broadcast")
        raise ArgumentError, "broadcast must be persisted" unless broadcast.persisted?

        broadcast
      end

      # 割り当て日（時刻を持たない Date）。
      def quota_date!(quota_date)
        Preconditions.date!(quota_date, "quota_date")
      end

      # 支出の額（1 以上の整数）。
      def units!(units)
        Preconditions.integer!(units, "units", min: 1)
      end

      # 予約額。固定の予約額（QuotaPolicy::RESERVATION_UNITS）だけを受け付ける（枠の内訳は固定値で、設定値にしない。8.4）。
      def reservation_units!(units)
        Preconditions.integer!(units, "units")
        return units if units == QuotaPolicy::RESERVATION_UNITS

        raise ArgumentError, "units must be the fixed reservation (#{QuotaPolicy::RESERVATION_UNITS}), got #{units}"
      end

      # 1 日の割り当て（設定 daily_quota_units。0 以上の整数）。
      def daily_total!(daily_total)
        Preconditions.integer!(daily_total, "daily_total", min: 0)
      end

      # 呼び出しの種別。METHOD_PATTERN を満たす文字列。
      def call_kind!(method)
        return method if method.is_a?(String) && METHOD_PATTERN.match?(method)

        detail = method.is_a?(String) ? "String of length #{method.length}" : method.class.to_s
        raise ArgumentError, "method must be a call kind (a letter, then letters, digits, underscores or dots; at most 64 characters), got #{detail}"
      end

      # 支出する枠。:prep・:settle（文字列でもよい）。QuotaPolicy が受け取るシンボルを返す。共通枠（common）は拒否する。
      def bucket!(bucket)
        name = bucket.is_a?(Symbol) ? bucket.to_s : bucket
        return name.to_sym if name.is_a?(String) && BUCKETS.include?(name)

        raise ArgumentError, "bucket must be one of #{BUCKETS.inspect} (the common bucket is spent by spend_common!), got #{bucket.class}"
      end

      # 呼び出しの結果。"ok"・"error"（シンボルでもよい）。明細の result 列の符号を返す。
      def result!(result)
        name = result.is_a?(Symbol) ? result.to_s : result
        return name if name.is_a?(String) && QuotaEntry::RESULTS.include?(name)

        raise ArgumentError, "result must be one of #{QuotaEntry::RESULTS.inspect}, got #{result.class}"
      end

      # 呼び出しの時刻。
      def now!(now)
        Preconditions.time!(now, "now")
      end
    end
  end
end
