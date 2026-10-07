# 日次の利用枠と開始試行（requirements.md 8.1・8.2・14 章・27 章「整合性」・20.1 の daily_usages）。
#
# 利用日ごと（アカウント × 利用日で一意の行）に、利用枠の消費数・開始試行の計上数・追加の付与数を持つ。
# 利用枠・開始試行の上限は、設定値（既定: 利用枠 1 回・開始試行 3 回。#5 の Settings）。
#
#   remaining / attempts_remaining   読み取り。行が無ければ 0 件として扱う（行を作らない）
#   ensure_for!                      行の取得・作成（upsert）。行を FOR UPDATE で確保して返す。受理（#12）が使う
#   consume!                         利用枠の消費（8.1）。確定待ちからライブへの遷移と、同一のトランザクションで呼ぶ（14 章）
#   count_attempt!                   開始試行の計上（8.2）。準備の開始と、同一のトランザクションで呼ぶ（14 章）
#   grant_extra!                     追加の 1 回の付与と、開始試行の計数の 0 への復帰（管理画面の手動リセット。8.1）
#
# 消費・計上は、トランザクションの内側で使える。呼び出し側のトランザクションがあれば参加し、無ければ自分で開く
# （SAVEPOINT を作らない。requires_new を使わない）。呼び出し側がトランザクションを巻き戻せば、消費・計上も取り消される。
# 行ロックの順序は、利用枠の行 → 配信の行（受理が、利用枠の行を先に確保するのと同じ）。
#
# 消費・計上の判定（残りがあるか・すでに数えたか）は、行ロックを取ったうえで行い、書き込みの前に済ませる。
# したがって、例外（利用枠が無い・上限）になったとき、途中まで書いた変更が残らない（呼び出し側が例外を受けて続行しても）。
module DailyAllowance
  # 利用枠が無い利用日の消費（consume!）。黙って成功させない。メッセージは、識別子と数だけ。
  class AllowanceExhausted < StandardError; end

  # 開始試行が上限に達した利用日の計上（count_attempt!）。メッセージは、識別子と数だけ。
  class AttemptLimitReached < StandardError; end

  class << self
    # 利用枠の残り。設定の利用枠 + 追加の付与 - 消費数。下限 0。行が無ければ 0 件として扱う（行を作らない）。
    def remaining(user_id:, usage_date:, settings:)
      Preconditions.kind!(settings, Settings, "settings")

      allowance_left(find_usage(user_id, usage_date), settings)
    end

    # 開始試行の残り。設定の上限 - 計上数。下限 0。行が無ければ 0 件として扱う（行を作らない）。
    def attempts_remaining(user_id:, usage_date:, settings:)
      Preconditions.kind!(settings, Settings, "settings")

      attempts_left(find_usage(user_id, usage_date), settings)
    end

    # アカウントと利用日の行を、無ければ作り（INSERT ... ON CONFLICT DO NOTHING。同時の作成と競合しない）、
    # FOR UPDATE で確保して返す。ロックは、呼び出し側のトランザクションが終わるまで続く
    # （同じアカウント・利用日の受理を、直列にするため。受理のトランザクションの中で呼ぶ）。
    def ensure_for!(user_id:, usage_date:)
      owner = OwnerScope.owner_id!(user_id)
      Preconditions.date!(usage_date, "usage_date")

      ApplicationRecord.transaction do
        DailyUsage.insert_all([ { user_id: owner, usage_date: usage_date } ], unique_by: %i[ user_id usage_date ])
        DailyUsage.owned_by(owner).lock.find_by!(usage_date: usage_date)
      end
    end

    # 利用枠を 1 消費する。配信の daily_usage_id が指す利用日（受理時の利用日。JST 03:00 をまたいでも変わらない）の消費数を 1 増やし、
    # 配信の allowance_consumed を立てる。確定待ちからライブへの遷移と、同一のトランザクションの中で呼ぶ（呼び出し側の責務）。
    #
    # 戻り値: 今回の呼び出しで消費したら true。この配信が、すでに消費済みなら false（二重に消費しない。冪等）。
    # 利用枠が無い（設定の利用枠 + 追加の付与 - 消費数 が 0 以下）ときは、DailyAllowance::AllowanceExhausted（何も変えない）。
    # settings を省くと、呼び出しのたびに SettingsStore.current で読む（キャッシュしない）。
    def consume!(broadcast, settings: SettingsStore.current)
      check_arguments!(broadcast, settings)

      with_locked_usage(broadcast, :allowance_consumed) { |locked, usage| consume_locked!(locked, usage, settings) }
    end

    # 開始試行を 1 計上する。配信の daily_usage_id が指す利用日の計上数を 1 増やし、配信の attempt_counted を立てる。
    # 準備の開始と、同一のトランザクションの中で呼ぶ（呼び出し側の責務）。
    #
    # 戻り値: 今回の呼び出しで計上したら true。この配信が、すでに計上済みなら false（同じ配信で二重に計上しない。冪等）。
    # 計上数が上限（設定 attempt_limit）に達しているときは、DailyAllowance::AttemptLimitReached（何も変えない）。
    # settings を省くと、呼び出しのたびに SettingsStore.current で読む（キャッシュしない）。
    def count_attempt!(broadcast, settings: SettingsStore.current)
      check_arguments!(broadcast, settings)

      with_locked_usage(broadcast, :attempt_counted) { |locked, usage| count_attempt_locked!(locked, usage, settings) }
    end

    # 追加の 1 回を付与し、開始試行の計数を 0 に戻す（管理画面の手動リセット。8.1）。消費数は変えない。
    # 行が無ければ、追加 1・試行 0・消費 0 で作る。1 つの upsert 文で行う（アカウントと利用日の一意制約と競合しない）。
    # 更新後の行を返す。
    def grant_extra!(user_id:, usage_date:)
      owner = OwnerScope.owner_id!(user_id)
      Preconditions.date!(usage_date, "usage_date")

      result = DailyUsage.upsert_all(
        [ { user_id: owner, usage_date: usage_date, extra_grants: 1, attempt_count: 0, consumed_count: 0 } ],
        unique_by: %i[ user_id usage_date ],
        on_duplicate: Arel.sql("extra_grants = daily_usages.extra_grants + 1, attempt_count = 0"),
        returning: %w[ id ]
      )
      DailyUsage.owned_by(owner).find(result.first.fetch("id"))
    end

    private

    # 行が無ければ、未保存の 0 件の行（DB の既定値）として扱う。行は作らない。
    def find_usage(user_id, usage_date)
      owner = OwnerScope.owner_id!(user_id)
      Preconditions.date!(usage_date, "usage_date")

      DailyUsage.owned_by(owner).find_by(usage_date: usage_date) || DailyUsage.new
    end

    def allowance_left(usage, settings)
      [ settings.daily_allowance + usage.extra_grants - usage.consumed_count, 0 ].max
    end

    def attempts_left(usage, settings)
      [ settings.attempt_limit - usage.attempt_count, 0 ].max
    end

    def check_arguments!(broadcast, settings)
      Preconditions.kind!(broadcast, Broadcast, "broadcast")
      raise ArgumentError, "broadcast must be persisted" unless broadcast.persisted?

      Preconditions.kind!(settings, Settings, "settings")
    end

    # 利用枠の行 → 配信の行の順に、FOR UPDATE で確保して（受理と同じ順序）、ブロックを実行し、ブロックの値を返す。
    # 呼び出し側のトランザクションがあれば参加し、無ければ自分で開く。終わったら、呼び出し側のメモリ上の配信へ、
    # 確保した行の印（flag）を反映する（変更済みの印は付けない）。
    def with_locked_usage(broadcast, flag)
      locked = nil
      result = ApplicationRecord.transaction do
        usage = DailyUsage.owned_by(broadcast.user_id).lock.find(broadcast.daily_usage_id)
        locked = lock_broadcast!(broadcast, usage)
        yield locked, usage
      end

      sync_flag(broadcast, locked, flag)
      result
    end

    # 配信の行を確保する（利用枠の行のあと）。配信が指す利用枠の行が、確保した行と同じであること。
    def lock_broadcast!(broadcast, usage)
      locked = Broadcast.owned_by(broadcast.user_id).lock.find(broadcast.id)
      raise ArgumentError, "daily_usage_id of broadcast #{locked.id} changed during the call" unless locked.daily_usage_id == usage.id

      locked
    end

    # 判定（すでに消費済みか・利用枠があるか）は、書き込みの前にすべて済ませる。
    def consume_locked!(locked, usage, settings)
      return false if locked.allowance_consumed

      left = allowance_left(usage, settings)
      if left < 1
        raise AllowanceExhausted, "allowance_exhausted broadcast_id=#{locked.id} usage_date=#{usage.usage_date} remaining=#{left}"
      end

      usage.update_columns(consumed_count: usage.consumed_count + 1)
      locked.update_columns(allowance_consumed: true)
      true
    end

    def count_attempt_locked!(locked, usage, settings)
      return false if locked.attempt_counted

      left = attempts_left(usage, settings)
      if left < 1
        raise AttemptLimitReached, "attempt_limit_reached broadcast_id=#{locked.id} usage_date=#{usage.usage_date} remaining=#{left}"
      end

      usage.update_columns(attempt_count: usage.attempt_count + 1)
      locked.update_columns(attempt_counted: true)
      true
    end

    # 呼び出し側のメモリ上の配信へ、DB の行の印を反映する（変更済みの印は付けない）。
    def sync_flag(broadcast, locked, column)
      broadcast.assign_attributes(column => locked.public_send(column))
      broadcast.clear_attribute_changes([ column.to_s ])
    end
  end
end
