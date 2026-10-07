# frozen_string_literal: true

# 保持期間（requirements.md 20.3）。いつ消去・削除・失効させるかを、時刻から算出する純粋な関数。
#
#   RetentionPolicy.expires_at(subject: :sessions, reference_at: last_used_at)   # => 最終利用から 30 日後
#   RetentionPolicy.cutoff(subject: :health_samples, now: now)                   # => now の 30 日前（これ以前の標本を削除）
#
# 対象（SUBJECTS）・期間・起点（期間は、契約の limits.json の retention の日数。30 日は 30 × 24 時間）
#   youtube_broadcast_id  配信の終了から 30 日（起点 ended_at）。未清算・清算不能のまま消去する場合は、配信用ストリームの識別子も破棄する
#   health_samples        健全性の標本。30 日（起点 sampled_at）
#   broadcast_events      配信の出来事。30 日（起点 occurred_at）
#   relay_tickets         接続チケット。失効から 1 日（起点 expires_at）
#   sessions              セッション。最終利用から 30 日（起点 last_used_at）
#   stream_id             ストリーム識別子。最後の確認から 30 日（起点 stream_verified_at）。過ぎたら消去する
#
# 期限ちょうどの時刻は、失効として扱う（now >= 期限。cutoff 以前の起点は失効している）。
# 再登録の保留（7.4）は、削除時点の利用日の終わりまで。失効の判定は、利用日（日付）を引数で受け取って行い、
# #5 の UsageCalendar を参照しない（利用日の算出は、呼び出し側が、時刻から行って渡す）。
#
# 15 章の関数との対応: なし（20.3 の保持期間）。副作用は実行しない。
class RetentionPolicy
  RETENTION = Contract::Limits::RETENTION

  # 対象 => 保持の日数
  DAYS = {
    youtube_broadcast_id: RETENTION.fetch("youtube_broadcast_id_days_after_end"),
    health_samples: RETENTION.fetch("health_samples_days"),
    broadcast_events: RETENTION.fetch("broadcast_events_days"),
    relay_tickets: RETENTION.fetch("relay_ticket_days_after_expiry"),
    sessions: RETENTION.fetch("session_days_after_last_use"),
    stream_id: RETENTION.fetch("stream_id_days_after_last_verified")
  }.freeze

  SUBJECTS = DAYS.keys.freeze

  # 対象 => 保持の秒数
  PERIOD_SECONDS = DAYS.transform_values { |days| days * LifecycleTimeUnits::SECONDS_PER_DAY }.freeze

  SS = Contract::SettlementState
  private_constant :SS

  NO_DIRECTIVES = [].freeze
  private_constant :NO_DIRECTIVES

  private_class_method :new

  class << self
    # 保持の秒数。
    def period_seconds(subject)
      check_subject!(subject)

      PERIOD_SECONDS.fetch(subject)
    end

    # 起点の時刻から、失効の時刻（起点 + 期間）。
    def expires_at(subject:, reference_at:)
      LifecycleChecks.time!(reference_at, "reference_at")

      reference_at + period_seconds(subject)
    end

    # now で、失効しているか（now が失効の時刻以降）。
    def expired?(subject:, reference_at:, now:)
      LifecycleChecks.time!(now, "now")

      now >= expires_at(subject: subject, reference_at: reference_at)
    end

    # now から、削除の基準の時刻（now - 期間）。起点がこの時刻以前のものが、失効している（一括の削除の条件に使う）。
    def cutoff(subject:, now:)
      LifecycleChecks.time!(now, "now")

      now - period_seconds(subject)
    end

    # 全対象の、削除の基準の時刻。
    def cutoffs(now:)
      LifecycleChecks.time!(now, "now")

      SUBJECTS.to_h { |subject| [ subject, cutoff(subject: subject, now: now) ] }.freeze
    end

    # 再登録の保留が失効したか。保留は、削除時点の利用日の終わりまで。usage_date（現在の利用日）が、保留の利用日より後なら失効。
    def registration_hold_expired?(hold_usage_date:, usage_date:)
      LifecycleChecks.date!(hold_usage_date, "hold_usage_date")
      LifecycleChecks.date!(usage_date, "usage_date")

      usage_date > hold_usage_date
    end

    # 終了した配信の、YouTube の配信識別子の消去（終了から 30 日）。消去するときの指示を返す。
    #   erase_youtube_broadcast_id  配信の識別子を消去する
    #   discard_stream_id           未清算・清算不能のまま消去するときだけ、配信用ストリームの識別子も破棄する（10.5・20.3。
    #                               破棄するかは、取り替えの規則 StreamReplacementPolicy に従う）
    # 終了していない・すでに消去済み・期限の前は、指示なし。
    def broadcast_id_erasure(broadcast:, now:)
      LifecycleChecks.kind!(broadcast, BroadcastSnapshot, "broadcast")
      LifecycleChecks.time!(now, "now")
      return NO_DIRECTIVES unless broadcast.ended? && broadcast.youtube_resource?
      return NO_DIRECTIVES unless expired?(subject: :youtube_broadcast_id, reference_at: broadcast.ended_at, now: now)

      directives = [ Directive.of(:erase_youtube_broadcast_id) ]
      directives << Directive.of(:discard_stream_id) if discard_stream_on_erasure?(broadcast)
      directives.freeze
    end

    private

    def check_subject!(subject)
      return if SUBJECTS.include?(subject)

      raise ArgumentError, "subject must be one of #{SUBJECTS.inspect}, got #{subject.inspect}"
    end

    # 未清算・清算不能のまま消去するか（清算済み・不要は、取り替えのトリガーにしない）。
    def discard_stream_on_erasure?(broadcast)
      unsettled = [ SS::PENDING, SS::ABANDONED ].include?(broadcast.settlement_state)
      unsettled && StreamReplacementPolicy.discard?(trigger: StreamReplacementPolicy::UNSETTLED_IDENTIFIER_ERASED)
    end
  end
end
