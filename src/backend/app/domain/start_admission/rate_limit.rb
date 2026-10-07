# frozen_string_literal: true

module StartAdmission
  # 受付要求の頻度の判定結果（requirements.md 8 章「受付要求の頻度」・9.2 の順 2）。
  # 計数（アカウントごと・直近の 1 時間・上限は設定 intake_rate_per_hour）は、アプリケーションのプロセス内で、呼び出し側が行う。
  # この型は、その結果を、判定へ渡す。
  #   exceeded  上限を超えているか
  #   retry_at  超えているとき、頻度の枠が空く時刻（Time）。超えていなければ nil
  class RateLimit < Data.define(:exceeded, :retry_at)
    class << self
      # 上限を超えていない。
      def within_limit
        new(exceeded: false, retry_at: nil)
      end

      # 上限を超えている。retry_at に、頻度の枠が空く時刻を渡す。
      def exceeded_until(retry_at)
        new(exceeded: true, retry_at: retry_at)
      end
    end

    def initialize(exceeded:, retry_at:)
      Preconditions.boolean!(exceeded, "exceeded")
      if exceeded
        Preconditions.time!(retry_at, "retry_at")
      elsif !retry_at.nil?
        raise ArgumentError, "retry_at must be nil when exceeded is false"
      end
      super(exceeded: exceeded, retry_at: retry_at&.dup&.freeze)
    end

    def exceeded?
      exceeded
    end
  end
end
