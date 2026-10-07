# 割り当て台帳（requirements.md 8.4・14 章・15 章・20.1 の quota_days・quota_entries・broadcasts の予約列）。
#
# YouTube Data API の 1 日の割り当て（太平洋時間の割り当て日ごと）を、システム全体で管理する。
# 規則（配信に使える上限・予約・枠の取り崩し・共通枠・移し替え・解放）は、Domain Core の QuotaPolicy（#5）。
# このサービスは、台帳の行（quota_days）と配信の行（broadcasts）を、FOR UPDATE で確保して、規則を適用し、永続化する。
# 並行する要求に対して、上限を超えて予約しない・二重に計上しない・予約中が負にならない、を、DB のロックで保証する
# （アプリケーションの変数での判定に頼らない。予約中が負にならないことは、ロジックで保証し、DB の CHECK 制約は最後の砦）。
#
#   day             台帳の 1 日（QuotaPolicy::Day）の読み取り。行を作らない
#   reserve!        受理の時に、配信 1 本分の予約（550 = 準備・確認枠 340 + 終了・清算枠 210）を計上する
#   spend!          配信に関する API 呼び出しの実費を、当該配信の予約の該当する枠から支出し、明細を記帳する
#   spend_common!   配信に属さない呼び出し（接続時の確認・再確認・チャンネル名の取得）を、共通枠（500）から支出する
#   carry_over!     割り当て日をまたいだ配信の予約の残額を、新しい割り当て日へ移す（spend! が、必要なときに内部で行う）
#   release!        予約の残額を解放する（清算状態が終端に達した時点で、呼び出し側が呼ぶ）
#   mark_exhausted! 割り当て超過の印を付ける（YouTube が、台帳の計上に反して、割り当て超過を返した日）
#
# どのメソッドも、トランザクションの内側で使える。呼び出し側のトランザクションがあれば参加し、無ければ自分で開く
# （SAVEPOINT を作らない。requires_new を使わない）。呼び出し側がトランザクションを巻き戻せば、台帳の変更も取り消される。
# 行ロックの順序は、配信の行 → 台帳の行（割り当て日の昇順）で、すべてのメソッドで同じ（デッドロックを避ける）。
# 呼び出しの時刻（now）の既定は、呼び出しの時点の時刻。テストでは、時刻を引数で渡す。
# 台帳の明細（quota_entries）には、呼び出しの種別（method）だけを残す。トークン・配信キー・タイトルを残さない（Arguments）。
module QuotaLedger
  # 予約の前提を満たさない配信（reserve!）。予約は、受理の時に 1 回だけ、状態 reserved の配信に対して行う。
  # 呼び出し側の誤りであり、予約の拒否（上限を超える・超過の日）とは区別する。メッセージは、識別子と符号だけ。
  class NotReservable < StandardError; end

  class << self
    # 割り当て日の台帳の 1 日（QuotaPolicy::Day。不変の値）。行が無い日は、すべて 0・超過の印なし。読み取りは、行を作らない。
    def day(quota_date)
      Arguments.quota_date!(quota_date)

      row = QuotaDay.find_by(quota_date: quota_date)
      return Rows.day_value(row) if row

      QuotaPolicy::Day.new(quota_date: quota_date, used_units: 0, reserved_units: 0, common_used_units: 0)
    end

    # 配信 1 本分の予約（550 = 準備・確認枠 340 + 終了・清算枠 210）を、割り当て日 quota_date の台帳へ計上する。
    # 当該割り当て日の「配信の使用済み + 予約中 + 新規の予約」が、配信に使える上限（daily_total - 共通枠 - 安全余裕）を超える日、
    # または、割り当て超過の印（mark_exhausted!）がある日は、予約しない（false。台帳も配信も変えない）。
    #
    # 受理（配信レコードの作成）と同一のトランザクションの中で呼ぶ（呼び出し側の責務。#12。14 章・27 章「整合性」）。
    # 配信は、保存済みで、状態 reserved・予約の枠が 0・0 のもの（作成してから、このメソッドで予約する）。
    # そうでない配信は QuotaLedger::NotReservable（呼び出し側の誤り。二重の予約で台帳を過大に計上しないため）。
    #
    # 成功したら、台帳の予約中を 550 増やし、配信の準備・確認枠（340）・終了・清算枠（210）・割り当て日を設定する（true）。
    # units は、固定の予約額（QuotaPolicy::RESERVATION_UNITS）だけを受け付ける（枠の内訳は固定値）。daily_total は、設定 daily_quota_units。
    def reserve!(broadcast, quota_date:, daily_total:, units: QuotaPolicy::RESERVATION_UNITS)
      Arguments.broadcast!(broadcast)
      Arguments.quota_date!(quota_date)
      Arguments.reservation_units!(units)
      Arguments.daily_total!(daily_total)

      with_locked_broadcast(broadcast) do |locked|
        check_reservable!(locked)
        place_reservation(locked, Rows.lock_day!(quota_date), daily_total)
      end
    end

    # 配信の予約の bucket（:prep 準備・確認枠・:settle 終了・清算枠。文字列でもよい）から、実費 units を支出する。
    # 使用済みへ記帳し、同額を、予約中と配信の枠から取り崩し、明細（呼び出しの種別 method・実費・結果 result・枠・時刻）を 1 件記帳する。
    # 呼び出しが失敗（result: "error"）でも、実費を記帳する。
    #
    # 当該配信の予約の、該当する枠に残額が足りないときは、支出しない（false。台帳・配信・明細を変えない）。
    # 準備・確認枠が足りなくても、終了・清算枠から取り崩さない（終了と清算に必要な支出が、それ以前の支出で不足しないため）。
    # 呼び出し側は、これを、準備の失敗・確認の見送りとして扱う。終了・清算枠は、bucket: :settle の支出だけが使う。
    # 割り当て超過の印がある日にも、進行中の配信の記帳は続けられる。予約を持たない配信（予約前・解放済み）への支出は、断られる（false）。
    #
    # 割り当て日をまたいだ配信は、またいだ後の最初の支出の時点で、予約の残額を、now の割り当て日へ移してから記帳する（carry_over!）。
    # now が、配信の予約の割り当て日より前なら（時計のずれ）、後戻りさせず、予約の割り当て日に記帳する。
    # method は、呼び出しの種別だけ（"liveBroadcasts.insert" の形。Arguments::METHOD_PATTERN）。タイトル・トークン・配信キーの形は ArgumentError。
    def spend!(broadcast, method:, units:, bucket:, result:, now: Time.current)
      Arguments.broadcast!(broadcast)
      kind = Arguments.call_kind!(method)
      Arguments.units!(units)
      pool = Arguments.bucket!(bucket)
      outcome = Arguments.result!(result)
      Arguments.now!(now)

      with_locked_broadcast(broadcast) do |locked|
        move_reservation!(locked, UsageCalendar.quota_date(now))
        book_spend(locked, kind: kind, units: units, bucket: pool, result: outcome, now: now)
      end
    end

    # 配信に属さない呼び出し（接続時の確認・再確認・チャンネル名の取得）の実費を、共通枠（500）から支出する。
    # 台帳の割り当て日 quota_date の共通枠の使用済みを増やし、明細（枠 common・配信なし）を 1 件記帳する（true）。
    # 共通枠の残額が足りないときは、支出しない（false）。当該割り当て日の終わりまで、これらの操作を受け付けない（8.4）。
    # result の既定は "ok"（失敗した呼び出しは "error" を渡す。実費を記帳する）。
    def spend_common!(method:, units:, quota_date:, result: "ok", now: Time.current)
      kind = Arguments.call_kind!(method)
      Arguments.units!(units)
      Arguments.quota_date!(quota_date)
      outcome = Arguments.result!(result)
      Arguments.now!(now)

      ApplicationRecord.transaction do
        book_common_spend(Rows.lock_day!(quota_date), kind: kind, units: units, result: outcome, now: now)
      end
    end

    # 割り当て日をまたいだ配信の予約の残額を、割り当て日 quota_date（新しい割り当て日）へ移す。
    # 旧い割り当て日の予約中から残額を引き、新しい割り当て日の予約中へ足す（予約中が負にならない）。使用済み・共通枠は移さない。
    # 新しい割り当て日の空きは検査しない（進行中の配信の終了・清算に必要な額を、取り上げないため）。
    #
    # 移したら true。すでに quota_date の予約（false）、残額が無い予約（false。移すものが無い）は、何も変えない（冪等）。
    # quota_date が、予約の割り当て日より前なら ArgumentError（後戻りさせない）。
    # 通常は、spend! が、またいだ後の最初の支出の時点で、内部で呼ぶ。
    def carry_over!(broadcast, quota_date:)
      Arguments.broadcast!(broadcast)
      Arguments.quota_date!(quota_date)

      with_locked_broadcast(broadcast) do |locked|
        if quota_date < locked.quota_date
          raise ArgumentError, "quota_date #{quota_date} is earlier than the reservation quota date #{locked.quota_date} of broadcast #{locked.id}"
        end

        move_reservation!(locked, quota_date)
      end
    end

    # 配信の予約の残額（準備・確認枠と終了・清算枠の合計）を、台帳の予約中から引いて、解放する。配信の枠は 0・0 になる。
    # 解放したら true。残額が無い配信（予約前・解放済み）は false（何も変えない。冪等。二重に解放しない）。
    #
    # 呼ぶのは、清算状態が終端（不要・清算済み・清算不能）に達した時点（requirements.md 8.4・10.4。呼び出し側の責務）。
    # 配信レコードの終了時点では呼ばない（YouTube 資源があれば、終了の時点の清算状態は「未清算」で、清算のための支出が、まだ要るため）。
    # このメソッドは、配信の状態・清算状態を検査しない。
    def release!(broadcast)
      Arguments.broadcast!(broadcast)

      with_locked_broadcast(broadcast) { |locked| release_reservation(locked) }
    end

    # 割り当て超過の印を付ける（YouTube が、台帳の計上に反して、割り当て超過を返した日）。当該割り当て日の終わりまで、
    # 新規の予約を受け付けない（reserve! が false）。進行中の配信の記帳・解放は、続けられる（8.4）。
    # 行が無ければ作る。冪等。1 つの upsert 文で行う。
    def mark_exhausted!(quota_date:)
      Arguments.quota_date!(quota_date)

      QuotaDay.upsert_all(
        [ { quota_date: quota_date, exhausted: true } ],
        unique_by: :quota_date,
        on_duplicate: Arel.sql("exhausted = true")
      )
      Rails.logger.warn("quota_ledger exhausted quota_date=#{quota_date}")
      true
    end

    private

    # 配信の行を FOR UPDATE で確保して（台帳の行より先。すべてのメソッドで同じ順序）、ブロックを実行し、ブロックの値を返す。
    # 呼び出し側のトランザクションがあれば参加し、無ければ自分で開く。終わったら、呼び出し側のメモリ上の配信へ、
    # 確保した行の予約の列を反映する（変更済みの印は付けない。判定が false のときも、DB の行の現在の値になる）。
    def with_locked_broadcast(broadcast)
      locked = nil
      result = ApplicationRecord.transaction do
        locked = Rows.lock_broadcast!(broadcast)
        yield locked
      end

      Rows.sync!(broadcast, locked, %w[ prep_reserved_units settle_reserved_units quota_date ])
      result
    end

    def check_reservable!(locked)
      unless locked.state == Contract::BroadcastState::RESERVED
        raise NotReservable, "not_reservable broadcast_id=#{locked.id} state=#{locked.state}"
      end
      return unless locked.prep_reserved_units.positive? || locked.settle_reserved_units.positive?

      raise NotReservable,
            "not_reservable broadcast_id=#{locked.id} already_holds prep=#{locked.prep_reserved_units} settle=#{locked.settle_reserved_units}"
    end

    # 規則を適用し、予約できれば、台帳の行と配信の行へ保存する（true）。できなければ、何も書かず、理由をログへ出す（false）。
    def place_reservation(locked, day_row, daily_total)
      outcome = QuotaPolicy.reserve(Rows.day_value(day_row), daily_total: daily_total)
      unless outcome.granted?
        log_refusal("reserve", outcome.reason, broadcast_id: locked.id, quota_date: day_row.quota_date, units: QuotaPolicy::RESERVATION_UNITS)
        return false
      end

      Rows.store_day!(day_row, outcome.day)
      Rows.store_reservation!(locked, outcome.reservation)
      true
    end

    # 配信の予約から支出できれば、台帳・配信の枠・明細へ保存する（true）。できなければ、何も書かず、理由をログへ出す（false）。
    def book_spend(locked, kind:, units:, bucket:, result:, now:)
      day_row = Rows.lock_day!(locked.quota_date)
      outcome = QuotaPolicy.spend(Rows.reservation_value(locked), bucket: bucket, units: units, day: Rows.day_value(day_row))
      unless outcome.granted?
        log_refusal("spend", outcome.reason, broadcast_id: locked.id, quota_date: day_row.quota_date, bucket: bucket, units: units, method: kind)
        return false
      end

      Rows.store_day!(day_row, outcome.day)
      Rows.store_reservation!(locked, outcome.reservation)
      QuotaEntry.create!(quota_day: day_row, broadcast: locked, method: kind, units: units, result: result, bucket: bucket.to_s, called_at: now)
      true
    end

    # 共通枠から支出できれば、台帳・明細へ保存する（true）。できなければ、何も書かず、理由をログへ出す（false）。
    def book_common_spend(day_row, kind:, units:, result:, now:)
      outcome = QuotaPolicy.spend_common(Rows.day_value(day_row), units: units)
      unless outcome.granted?
        log_refusal("spend_common", outcome.reason, quota_date: day_row.quota_date, units: units, method: kind)
        return false
      end

      Rows.store_day!(day_row, outcome.day)
      QuotaEntry.create!(quota_day: day_row, method: kind, units: units, result: result, bucket: Arguments::COMMON_BUCKET, called_at: now)
      true
    end

    # 配信の予約の残額を、target_date（新しい割り当て日）へ移す。移したら true。
    #   target_date が、予約の割り当て日と同じか前（時計のずれ）: 移さない（後戻りさせない）
    #   予約の残額が無い: 移さない（移すものが無い。割り当て日も変えない）
    # 台帳の行は、割り当て日の昇順に確保する（旧い日 → 新しい日。デッドロックを避ける）。
    def move_reservation!(locked, target_date)
      return false unless target_date > locked.quota_date

      reservation = Rows.reservation_value(locked)
      return false if reservation.remaining_units.zero?

      from_row = Rows.lock_day!(locked.quota_date)
      to_row = Rows.lock_day!(target_date)
      carried = QuotaPolicy.carry_over(reservation, from: Rows.day_value(from_row), to: Rows.day_value(to_row))

      Rows.store_day!(from_row, carried.from)
      Rows.store_day!(to_row, carried.to)
      Rows.store_reservation!(locked, carried.reservation)
      Rails.logger.info(
        "quota_ledger carried broadcast_id=#{locked.id} from=#{from_row.quota_date} to=#{to_row.quota_date} units=#{reservation.remaining_units}"
      )
      true
    end

    # 配信の予約の残額を解放できれば true。残額が無ければ false（何も書かない）。
    def release_reservation(locked)
      reservation = Rows.reservation_value(locked)
      return false if reservation.remaining_units.zero?

      day_row = Rows.lock_day!(locked.quota_date)
      outcome = QuotaPolicy.release(reservation, day: Rows.day_value(day_row))

      Rows.store_day!(day_row, outcome.day)
      Rows.store_reservation!(locked, outcome.reservation)
      true
    end

    # 拒否の記録。何が・どの配信で・なぜ。識別子・日付・数・符号だけ（配信のタイトル・トークン・配信キーを含まない）。
    def log_refusal(operation, reason, **fields)
      details = fields.map { |name, value| "#{name}=#{value}" }.join(" ")
      Rails.logger.warn("quota_ledger refused operation=#{operation} reason=#{reason} #{details}")
    end
  end
end
