# frozen_string_literal: true

# 開始受付判定（requirements.md 9 章・15 章「開始受付判定」）。
#
# 入力（アカウントの現況・入力・設定値・時刻）だけから、受理（Admission::Accepted）または拒否（Admission::Rejected）を返す。
# 判定は 9.2 の順 0〜13 で行い、最初に該当した理由で拒否する。利用者自身の状態に起因し、再試行しても解消しない理由を、
# システム都合の一時的な理由より先に返す（「満員です」と案内された利用者が、実際には当日の利用枠を消費済みで、再試行が無駄になることを防ぐ）。
#
#   順 0  入力が検証を満たさない                          入力不備（不備のある項目を、すべて返す）
#   順 1  セッションが無効                                未ログイン
#   順 2  受付要求の頻度が上限を超える                    頻度超過
#   順 3  bot 判定が不合格、または判定不能                bot 判定（:pass 以外は拒否。判定不能を受理側へ倒さない）
#   順 4〜13  アカウントの現況による判定                  StartAdmission::StateRules（進行中の配信・接続状態・利用枠・開始試行・
#                                                         受付停止・転送量の予算・同時配信数・API 割り当て）
#
# 順 0〜3 は、アカウントの現況を参照する前に判定する。さらに、bot 判定（外部サービスの呼び出し）は、順 0〜2 を通過した要求に限る。
# そのため、bot_verdict と snapshot は遅延評価（呼び出すと値を返す関数）で受け取る。
#   順 0〜2 で拒否するとき   bot_verdict も snapshot も、一度も呼ばない
#   順 3 で拒否するとき      snapshot を、一度も呼ばない
# （現況の開示と、外部サービスの呼び出しを、正当な要求に限るため。9.2）
#
# 引数（すべてキーワード）
#   input         StartAdmission::Input（タイトル・公開範囲・子ども向けの申告）
#   session_valid true / false。セッションが有効か
#   rate_limit    StartAdmission::RateLimit。受付要求の頻度の判定結果（計数は、呼び出し側のプロセス内）
#   bot_verdict   呼ぶと :pass・:fail・:indeterminate を返す関数。:pass 以外は拒否する
#   snapshot      呼ぶと AccountSnapshot を返す関数。判定の時刻の利用日・暦月・割り当て日の現況であること（違えば StaleSnapshot）
#   settings      Settings（制限値・受付停止）
#   now           判定の時刻（Time）
#
# 例外（呼び出し側の誤りを、拒否でも受理でもなく例外にする。フォールバックしない）
#   ArgumentError   引数の型違い。bot_verdict の戻り値が想定外。snapshot の戻り値が AccountSnapshot でない
#   StaleSnapshot   現況の利用日・暦月・割り当て日が、判定の時刻のものでない
#   （bot_verdict・snapshot の呼び出しが投げた例外は、そのまま伝える。握りつぶさず、受理もしない）
module StartAdmission
  # bot 判定の結果（遅延評価の関数の戻り値）
  BOT_VERDICTS = %i[pass fail indeterminate].freeze

  # 現況が、判定の時刻の利用日・暦月・割り当て日のものでない（古い現況で判定しない）。
  class StaleSnapshot < ArgumentError; end

  class << self
    def decide(input:, session_valid:, rate_limit:, bot_verdict:, snapshot:, settings:, now:)
      check_arguments!(input, session_valid, rate_limit, bot_verdict, snapshot, settings, now)

      early = early_rejection(input, session_valid, rate_limit, bot_verdict, now)
      return early if early

      account = load_snapshot(snapshot, now)
      reason = StateRules.first_violation(account, settings)
      return reject(reason, now, rate_limit) if reason

      accept(settings, now)
    end

    private

    def check_arguments!(input, session_valid, rate_limit, bot_verdict, snapshot, settings, now)
      Preconditions.kind!(input, Input, "input")
      Preconditions.boolean!(session_valid, "session_valid")
      Preconditions.kind!(rate_limit, RateLimit, "rate_limit")
      Preconditions.callable!(bot_verdict, "bot_verdict")
      Preconditions.callable!(snapshot, "snapshot")
      Preconditions.kind!(settings, Settings, "settings")
      Preconditions.time!(now, "now")
    end

    # 順 0〜3。現況（snapshot）を参照しない。bot 判定は、順 0〜2 を通過したときだけ呼ぶ。
    def early_rejection(input, session_valid, rate_limit, bot_verdict, now)
      invalid_fields = input.invalid_fields
      return reject(Contract::RejectionReason::INVALID_INPUT, now, rate_limit, invalid_fields) unless invalid_fields.empty?
      return reject(Contract::RejectionReason::NOT_LOGGED_IN, now, rate_limit) unless session_valid
      return reject(Contract::RejectionReason::RATE_LIMITED, now, rate_limit) if rate_limit.exceeded?
      return reject(Contract::RejectionReason::BOT_CHECK_FAILED, now, rate_limit) unless bot_passed?(bot_verdict)

      nil
    end

    def bot_passed?(provider)
      verdict = provider.call
      raise ArgumentError, "bot_verdict must return one of #{BOT_VERDICTS.inspect}, got #{verdict.class}" unless BOT_VERDICTS.include?(verdict)

      verdict == :pass
    end

    # 現況を 1 回だけ呼び、型と日付（利用日・暦月・割り当て日）を検査して返す。
    def load_snapshot(provider, now)
      account = provider.call
      raise ArgumentError, "snapshot must return an AccountSnapshot, got #{account.class}" unless account.is_a?(AccountSnapshot)

      check_fresh!(account, now)
      account
    end

    def check_fresh!(account, now)
      expected = {
        usage_date: UsageCalendar.usage_date(now),
        month_key: UsageCalendar.month_key(now),
        quota_date: UsageCalendar.quota_date(now)
      }
      actual = { usage_date: account.usage_date, month_key: account.month_key, quota_date: account.quota_day.quota_date }
      stale = expected.reject { |name, value| actual.fetch(name) == value }
      return if stale.empty?

      details = stale.map { |name, value| "#{name} expected #{value} got #{actual.fetch(name)}" }.join(", ")
      raise StaleSnapshot, "snapshot is not for the time of the decision: #{details}"
    end

    def reject(reason, now, rate_limit, fields = [])
      Admission::Rejected.for(reason, retry_at: RetryAt.for(reason, now: now, rate_limit: rate_limit), fields: fields)
    end

    def accept(settings, now)
      Admission::Accepted.new(
        usage_date: UsageCalendar.usage_date(now),
        quota_date: UsageCalendar.quota_date(now),
        reservation_units: QuotaPolicy::RESERVATION_UNITS,
        limits: Admission::AppliedLimits.from_settings(settings)
      )
    end
  end
end
