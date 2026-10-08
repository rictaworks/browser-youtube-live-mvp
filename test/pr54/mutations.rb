# 変異の確認用（PR 54 のテスト。mutation_check.sh が、backend コンテナの /tmp へ複写して、rspec の -r で読み込む）。
# 環境変数 MUTATION の名前で、アプリケーションの 1 か所を壊し、該当するスペックが落ちる（スペックが、その仕様を守っている）ことを確かめる。
# アプリケーションのファイルは書き換えない（実行中のプロセスの中で、メソッドを差し替えるだけ）。
#
# 書き方の注意
#   - class_eval のブロックの中の定数は、ブロックを書いた場所（このモジュール）から探される。対象のクラスの定数は、修飾して書く
#     （例: Contract::ConnectResult::UNVERIFIABLE・Dev::GoogleConnectController::FIELD_ORDER）。private_constant の定数は const_get で取る。
#     書き損じると NameError になり、スペックが「落ちた」ことになってしまうため、mutation_check.sh は、定義の誤りを示す例外
#     （uninitialized constant など）が出力にあれば、失敗として扱う。
#   - このファイルは、rspec の -r で、Rails の読み込みより前に読まれる。クラスの参照は、メソッドの中（before(:suite) で呼ばれる時点）で行う。
module MutationCatalog
  def self.apply(name)
    method_name = "mutate_#{name}"
    raise "unknown mutation: #{name}" unless respond_to?(method_name)

    public_send(method_name)
  end

  # 何も壊さない（基準。変異なしで、スペックが緑であることを確かめる）
  def self.mutate_baseline
    nil
  end

  # ============================================================
  # YouTubeConnectService: 認可の完了（コールバック）
  # ============================================================

  # state を照合しない
  def self.mutate_service_state_unchecked
    YouTubeConnectService.class_eval do
      private

      def state_matches?(_expected, _given)
        true
      end
    end
  end

  # bl_oauth のアカウントと、ログイン中のセッションのアカウントの一致を確かめない
  def self.mutate_service_account_unchecked
    YouTubeConnectService.class_eval do
      private

      def refusal_before_exchange(user, payload, code, state, error)
        unverifiable = Contract::ConnectResult::UNVERIFIABLE
        return [ unverifiable, :not_logged_in ] if user.nil?
        return [ unverifiable, :state_cookie_invalid ] if payload.nil?
        return [ unverifiable, :state_mismatch ] unless state_matches?(payload.state, state)
        return authorization_refusal(error) unless error.nil?
        return [ unverifiable, :code_missing ] unless code.is_a?(String) && !code.strip.empty?

        [ unverifiable, :code_too_long ] if code.length > LoginProcedure::CODE_MAX_LENGTH
      end
    end
  end

  # 戻り先の error パラメータを見ない
  def self.mutate_service_error_param_ignored
    YouTubeConnectService.class_eval do
      private

      def refusal_before_exchange(user, payload, code, state, _error)
        unverifiable = Contract::ConnectResult::UNVERIFIABLE
        return [ unverifiable, :not_logged_in ] if user.nil?
        return [ unverifiable, :state_cookie_invalid ] if payload.nil?
        return [ unverifiable, :account_mismatch ] unless payload.user_id == user.id
        return [ unverifiable, :state_mismatch ] unless state_matches?(payload.state, state)
        return [ unverifiable, :code_missing ] unless code.is_a?(String) && !code.strip.empty?

        [ unverifiable, :code_too_long ] if code.length > LoginProcedure::CODE_MAX_LENGTH
      end
    end
  end

  # 利用者の拒否（access_denied）を、権限の拒否ではなく確認不能にする
  def self.mutate_service_denied_as_unverifiable
    YouTubeConnectService.class_eval do
      private

      def authorization_refusal(_error)
        [ Contract::ConnectResult::UNVERIFIABLE, :authorization_error ]
      end
    end
  end

  # コードの長さの上限を見ない
  def self.mutate_service_code_length_unchecked
    YouTubeConnectService.class_eval do
      private

      def refusal_before_exchange(user, payload, code, state, error)
        unverifiable = Contract::ConnectResult::UNVERIFIABLE
        return [ unverifiable, :not_logged_in ] if user.nil?
        return [ unverifiable, :state_cookie_invalid ] if payload.nil?
        return [ unverifiable, :account_mismatch ] unless payload.user_id == user.id
        return [ unverifiable, :state_mismatch ] unless state_matches?(payload.state, state)
        return authorization_refusal(error) unless error.nil?

        [ unverifiable, :code_missing ] unless code.is_a?(String) && !code.strip.empty?
      end
    end
  end

  # 進行中の配信があっても、コールバックで再接続を受け付ける（開始側の確認は、そのまま）
  def self.mutate_service_broadcast_in_progress_ignored
    YouTubeConnectService.class_eval do
      alias_method :original_broadcast_in_progress?, :broadcast_in_progress?

      def broadcast_in_progress?(user)
        return false if caller_locations(1, 1).first.base_label == "complete"

        original_broadcast_in_progress?(user)
      end
    end
  end

  # 付与の判定（権限 -> 更新トークン -> 接続時の確認）の一部を省く。skip_scope: 権限を見ない / skip_refresh: 更新トークンを見ない
  def self.define_judge(skip_scope: false, skip_refresh: false)
    YouTubeConnectService.class_eval do
      define_method(:judge) do |user, grant, now, attempt|
        result = Contract::ConnectResult
        return failure(user, result::SCOPE_DENIED, :youtube_scope_not_granted) unless skip_scope || grant.scope?(@oidc.youtube_scope)
        return failure(user, result::NO_REFRESH_TOKEN, :refresh_token_missing) unless skip_refresh || grant.refresh_token?

        verdict = verify(nil, grant.access_token)
        case verdict.kind
        when :connected, :live_not_enabled then establish(user, grant, verdict, now, attempt)
        when :no_channel then failure(user, result::NO_CHANNEL, verdict.reason)
        when :revoked then failure(user, result::SCOPE_DENIED, verdict.reason)
        else failure(user, result::UNVERIFIABLE, verdict.reason)
        end
      end
      private :judge
    end
  end

  def self.mutate_service_scope_unchecked
    define_judge(skip_scope: true)
  end

  def self.mutate_service_refresh_token_unchecked
    define_judge(skip_refresh: true)
  end

  # ============================================================
  # YouTubeConnectService: 不成立のときのトークンの扱い
  # ============================================================

  # 既存の接続があっても、受け取ったトークンを Google 側で失効させる（同じ付与を共有する既存のトークンも、失効してしまう）
  def self.mutate_service_revoke_with_existing
    YouTubeConnectService.class_eval do
      private

      def discard_grant(user, grant)
        @oidc.revoke(token: grant.refresh_token || grant.access_token)
      rescue YouTubeErrors::Base => error
        @logger.warn("[youtube_connect] revoke failed #{account_field(user)} #{error.message}")
      end
    end
  end

  # 既存の接続が無くても、Google 側で失効させない
  def self.mutate_service_revoke_never
    YouTubeConnectService.class_eval do
      private

      def discard_grant(_user, _grant)
        nil
      end
    end
  end

  # 更新トークンがあっても、アクセストークンだけを失効させる（更新トークンが残る）
  def self.mutate_service_revokes_access_token_only
    YouTubeConnectService.class_eval do
      private

      def discard_grant(user, grant)
        return if YoutubeConnection.owned_by(user).exists?

        @oidc.revoke(token: grant.access_token)
      rescue YouTubeErrors::Base => error
        @logger.warn("[youtube_connect] revoke failed #{account_field(user)} #{error.message}")
      end
    end
  end

  # 不成立なのに、受け取った更新トークンを保存する
  def self.mutate_service_failure_stores_token
    YouTubeConnectService.class_eval do
      alias_method :original_judge_discarding_unsaved, :judge_discarding_unsaved
      private :original_judge_discarding_unsaved

      private

      def judge_discarding_unsaved(user, grant, now)
        @vault.store(user_id: user.id, refresh_token: grant.refresh_token, now: Time.current) if grant.refresh_token?
        original_judge_discarding_unsaved(user, grant, now)
      end
    end
  end

  # ============================================================
  # YouTubeConnectService: 成立の保存
  # ============================================================

  # 保存済みの配信用ストリームの識別子を、成立のたびに破棄しない（10.5）
  def self.mutate_service_stream_not_discarded
    YouTubeConnectService.class_eval do
      private

      def persist_connection(user, grant, kind, now)
        ApplicationRecord.transaction do
          connection = @vault.store(user_id: user.id, refresh_token: grant.refresh_token, now: now)
          apply_state!(connection, kind)
          connection.update!(connected_at: now, last_verified_at: now)
        end
      end
    end
  end

  # 成立の状態（connected・live_not_enabled）を、接続の行へ反映しない（認可失効のままになる）
  def self.mutate_service_state_not_applied
    YouTubeConnectService.class_eval do
      private

      def apply_state!(_connection, _kind)
        nil
      end
    end
  end

  # 保存・状態・ストリームの識別子の破棄を、1 つのトランザクションにしない
  def self.mutate_service_not_atomic
    YouTubeConnectService.class_eval do
      private

      def persist_connection(user, grant, kind, now)
        connection = @vault.store(user_id: user.id, refresh_token: grant.refresh_token, now: now)
        apply_state!(connection, kind)
        connection.update!(connected_at: now, last_verified_at: now)
        connection.discard_stream! if StreamReplacementPolicy.discard?(trigger: StreamReplacementPolicy::YOUTUBE_CONNECTED)
      end
    end
  end

  # TokenVault を呼ぶ前に、接続の行をロックする（TokenVault は、アカウントごとの排他のあとで行をロックする。逆の順序は、デッドロックし得る）
  def self.mutate_service_lock_before_store
    YouTubeConnectService.class_eval do
      private

      def persist_connection(user, grant, kind, now)
        ApplicationRecord.transaction do
          YoutubeConnection.owned_by(user).lock.take
          connection = @vault.store(user_id: user.id, refresh_token: grant.refresh_token, now: now)
          apply_state!(connection, kind)
          connection.update!(connected_at: now, last_verified_at: now)
          connection.discard_stream! if StreamReplacementPolicy.discard?(trigger: StreamReplacementPolicy::YOUTUBE_CONNECTED)
        end
      end
    end
  end

  # 接続時の確認（YouTube の呼び出し）を、トランザクションの中で行う
  def self.mutate_service_probe_inside_transaction
    YouTubeConnectService.class_eval do
      alias_method :original_judge, :judge
      private :original_judge

      private

      def judge(user, grant, now, attempt)
        ApplicationRecord.transaction { original_judge(user, grant, now, attempt) }
      end
    end
  end

  # ============================================================
  # YouTubeConnectService: 確認の失敗の扱い・再確認・チャンネル名
  # ============================================================

  # 型付きの例外の disposition（接続状態）を見ず、すべて確認不能にする
  def self.mutate_service_disposition_ignored
    YouTubeConnectService.class_eval do
      private

      def verdict_for_error(error)
        YouTubeConnectService.const_get(:Verdict).new(kind: :unverifiable, channel_title: nil, reason: error_reason(error))
      end
    end
  end

  # 認可失効の接続も、再確認で YouTube を呼ぶ
  def self.mutate_service_recheck_probes_revoked
    YouTubeConnectService.class_eval do
      def recheck(user:, now:)
        account = persisted_user!(user)
        Preconditions.time!(now, "now")

        connection = YoutubeConnection.owned_by(account).take
        return YouTubeConnectService::Recheck.new(outcome: :not_connected, state: Contract::YoutubeConnectionState::NOT_CONNECTED) if connection.nil?

        apply_recheck(account, connection, verify(connection, nil), now)
      end
    end
  end

  # チャンネル名のメモリ保持を使わず、毎回 YouTube を呼ぶ
  def self.mutate_service_channel_title_uncached
    YouTubeConnectService.class_eval do
      def channel_title(user)
        account = persisted_user!(user)
        connection = YoutubeConnection.owned_by(account).take
        return nil if connection.nil? || connection.state == Contract::YoutubeConnectionState::REVOKED

        title_from(account, connection)
      end
    end
  end

  # 認可失効の接続でも、チャンネル名のために YouTube を呼ぶ
  def self.mutate_service_channel_title_revoked_probed
    YouTubeConnectService.class_eval do
      def channel_title(user)
        account = persisted_user!(user)
        connection = YoutubeConnection.owned_by(account).take
        return nil if connection.nil?

        @channel_names.fetch(account.id) { title_from(account, connection) }
      end
    end
  end

  # チャンネル名の取得（読み取り）が、接続の状態を変える
  def self.mutate_service_channel_title_changes_state
    YouTubeConnectService.class_eval do
      private

      def title_from(user, connection)
        verdict = verify(connection, nil)
        connection.mark_revoked! if verdict.kind == :revoked
        return verdict.channel_title if verdict.channel_title

        @logger.warn("[youtube_connect] channel title unavailable #{account_field(user)} reason=#{verdict.reason}")
        nil
      end
    end
  end

  # 空・空白だけのチャンネル名を、使えないものとして扱わない（キャッシュの保持の検査で ArgumentError になり、保存したあとに 500 になる）
  def self.mutate_service_blank_title_unchecked
    YouTubeConnectService.class_eval do
      private

      def usable_title?(_title)
        true
      end
    end
  end

  # 受け取ったトークンの破棄を、想定外の例外のときに行わない（ensure を使わない。不成立の確定のときだけ破棄する）
  def self.mutate_service_unsaved_token_kept_on_error
    YouTubeConnectService.class_eval do
      private

      def judge_discarding_unsaved(user, grant, now)
        attempt = YouTubeConnectService.const_get(:Attempt).new(false)
        completion = judge(user, grant, now, attempt)
        discard_grant(user, grant) unless attempt.saved
        completion
      end
    end
  end

  # 認可の開始の結果（Start）の pp・pretty_inspect が、Data の既定の表記（state・検証子をそのまま出す）に戻る
  def self.mutate_service_start_pretty_print_default
    YouTubeConnectService::Start.class_eval do
      def pretty_print(printer)
        Data.instance_method(:pretty_print).bind_call(self, printer)
      end
    end
  end

  # 確認の結果（Verdict）の pp・pretty_inspect が、Data の既定の表記（チャンネル名をそのまま出す）に戻る
  def self.mutate_service_verdict_pretty_print_default
    YouTubeConnectService.const_get(:Verdict).class_eval do
      def pretty_print(printer)
        Data.instance_method(:pretty_print).bind_call(self, printer)
      end
    end
  end

  # ============================================================
  # ChannelNameCache: メモリ保持（最長 10 分・永続化しない・アカウントごと）
  # ============================================================

  # 期限が切れない
  def self.mutate_cache_ttl_ignored
    ChannelNameCache.class_eval do
      private

      def lookup(key)
        @mutex.synchronize { @entries[key] }
      end
    end
  end

  # ちょうど期限の時刻でも、まだ有効とする（境界の誤り）
  def self.mutate_cache_ttl_off_by_one
    ChannelNameCache.class_eval do
      private

      def lookup(key)
        @mutex.synchronize do
          entry = @entries[key]
          next nil if entry.nil?
          next entry if current_time <= entry.expires_at

          nil
        end
      end
    end
  end

  # 読み出しのたびに、寿命が延びる（チャンネル名も、失敗の記録も）
  def self.mutate_cache_read_extends_life
    ChannelNameCache.class_eval do
      private

      def lookup(key)
        @mutex.synchronize do
          entry = @entries[key]
          next nil if entry.nil?
          next nil if current_time >= entry.expires_at

          refreshed = entry.with(expires_at: current_time + (entry.title.nil? ? @failure_ttl_seconds : @ttl_seconds))
          @entries[key] = refreshed
          refreshed
        end
      end
    end
  end

  # 寿命の上限（10 分）を検査しない
  def self.mutate_cache_ttl_max_unchecked
    ChannelNameCache.class_eval do
      def initialize(clock: SystemClock.method(:now), ttl_seconds: 600, failure_ttl_seconds: 60)
        @clock = clock
        @ttl_seconds = ttl_seconds
        @failure_ttl_seconds = failure_ttl_seconds
        @entries = {}
        @key_locks = {}
        @mutex = Mutex.new
      end
    end
  end

  # すべてのアカウントが 1 つの鍵を共有する
  def self.mutate_cache_shared_key
    ChannelNameCache.class_eval do
      private

      def key!(user_id)
        OwnerScope.owner_id!(user_id)
        "shared-key"
      end
    end
  end

  # アプリケーションのキャッシュのストア（Rails.cache）へも書く
  def self.mutate_cache_uses_rails_cache
    ChannelNameCache.class_eval do
      alias_method :original_store, :store
      private :original_store

      private

      def store(key, title, ttl_seconds)
        Rails.cache.write("channel_title:#{key}", title)
        original_store(key, title, ttl_seconds)
      end
    end
  end

  # チャンネル名を、ログへ出す
  def self.mutate_cache_logs_title
    ChannelNameCache.class_eval do
      alias_method :original_store, :store
      private :original_store

      private

      def store(key, title, ttl_seconds)
        Rails.logger.info("channel title stored title=#{title}")
        original_store(key, title, ttl_seconds)
      end
    end
  end

  # 同じアカウントの取得を 1 回にまとめない（同時に画面を開くと、YouTube の呼び出しが重なる）
  def self.mutate_cache_no_single_flight
    ChannelNameCache.class_eval do
      def fetch(user_id, &fetcher)
        raise ArgumentError, "a block that fetches the channel title is required" if fetcher.nil?

        key = key!(user_id)
        known = lookup(key)
        return known.title if known

        fetch_and_store(key, &fetcher)
      end
    end
  end

  # 取得の失敗を覚えない（障害中の再読み込み・チャンネルを削除した利用者の連打が、毎回 YouTube を呼ぶ）
  def self.mutate_cache_failure_not_cached
    ChannelNameCache.class_eval do
      private

      def remember_failure(_key)
        nil
      end
    end
  end

  # 失敗を覚える時間が、チャンネル名の保持（10 分）と同じ長さになる（設定の 60 秒を使わない）
  def self.mutate_cache_failure_ttl_too_long
    ChannelNameCache.class_eval do
      private

      def remember_failure(key)
        store(key, nil, @ttl_seconds)
        nil
      end
    end
  end

  # 保持している 1 件（Entry）の pp・pretty_inspect が、Data の既定の表記（メンバーの値をそのまま出す）に戻る
  def self.mutate_cache_entry_pretty_print_default
    ChannelNameCache.const_get(:Entry).class_eval do
      def pretty_print(printer)
        Data.instance_method(:pretty_print).bind_call(self, printer)
      end
    end
  end

  # ============================================================
  # RecheckGate・RateLimiter#peek: 次に再確認できる時刻
  # ============================================================

  # 時刻を求めるたびに、再確認の回数を消費する
  def self.mutate_gate_consumes
    RecheckGate.class_eval do
      private

      def rate_limited_until(account)
        limiter.check(RateLimitPolicy.recheck, account).retry_at
      end
    end
  end

  # peek が計数する
  def self.mutate_peek_consumes
    RateLimiter.class_eval do
      def peek_all(rules)
        hit_all(rules)
      end
    end
  end

  # 共通枠の枯渇を見ない
  def self.mutate_gate_quota_ignored
    RecheckGate.class_eval do
      private

      def quota_exhausted_until(_now)
        nil
      end
    end
  end

  # 割り当て日を、固定の時差（太平洋標準時 -8 時間）で求める（夏時間で 1 時間ずれる）
  def self.mutate_gate_fixed_offset
    RecheckGate.class_eval do
      private

      def quota_exhausted_until(now)
        day = QuotaLedger.day((now.utc - (8 * 3600)).to_date)
        return nil if QuotaPolicy.spend_common(day, units: probe_units).granted?

        UsageCalendar.next_quota_date_start(now)
      end
    end
  end

  # 2 つの制限のうち、早い方を返す（遅い方を返すべき）
  def self.mutate_gate_earliest_wins
    RecheckGate.class_eval do
      def next_allowed_at(user)
        account = OwnerScope.owner_id!(user)
        now = current_time

        earliest = [ rate_limited_until(account), quota_exhausted_until(now) ].compact.min
        earliest && UsageCalendar.to_jst(earliest)
      end
    end
  end

  # ============================================================
  # Api::YoutubeController
  # ============================================================

  # 頻度制限をしない（connect/start の IP 単位・recheck のアカウント単位）
  def self.mutate_controller_rate_limit_skipped
    Api::YoutubeController.class_eval do
      private

      def enforce_rate_limit!(*)
        nil
      end
    end
  end

  # bot 判定をしない
  def self.mutate_controller_bot_skipped
    Api::YoutubeController.class_eval do
      private

      def verify_bot!(_token)
        nil
      end
    end
  end

  # 判定不能（検証サービスに届かない場合）を、受理側へ倒す
  def self.mutate_controller_bot_indeterminate_passes
    Api::YoutubeController.class_eval do
      private

      def verify_bot!(token)
        verdict = gateways.recaptcha_verifier.verify(
          token: token, expected_action: Api::YoutubeController::RECAPTCHA_ACTION, hostname: public_hostname, now: current_time
        )
        raise Api::Error::BotCheckFailed.new(reason: verdict) if verdict == :fail
      end
    end
  end

  # connect/start が、進行中の配信を確かめない
  def self.mutate_controller_start_ignores_broadcast
    YouTubeConnectService.class_eval do
      alias_method :original_broadcast_in_progress?, :broadcast_in_progress?

      def broadcast_in_progress?(user)
        return false if caller_locations(1, 1).first.base_label == "connect_start"

        original_broadcast_in_progress?(user)
      end
    end
  end

  # コールバックで、bl_oauth を失効させない（state の再利用を防げない）
  def self.mutate_controller_oauth_cookie_kept
    Api::YoutubeController.class_eval do
      private

      def open_oauth_state
        oauth_state_cookie.open(
          cookies[OAuthStateCookie::NAME], expected_purpose: YouTubeConnectService::OAUTH_PURPOSE, now: current_time
        )
      rescue OAuthStateCookie::InvalidCookie
        nil
      end
    end
  end

  # 接続の測定イベントを記録しない
  def self.mutate_controller_event_not_recorded
    Api::YoutubeController.class_eval do
      private

      def record_connect_event(_completion)
        nil
      end
    end
  end

  # 不成立も、成立（connect_completed）として記録する
  def self.mutate_controller_failure_recorded_as_completed
    Api::YoutubeController.class_eval do
      private

      def record_connect_event(completion)
        UsageRecorder.record(user_id: current_user&.id, type: Contract::UsageEventType::CONNECT_COMPLETED, reason_code: completion.result)
      end
    end
  end

  # ログインしていない要求（匿名）でも、測定イベントを記録する（Cookie の無い GET で、測定イベントの表を埋められる）
  def self.mutate_controller_anonymous_event_recorded
    Api::YoutubeController.class_eval do
      private

      def started_by_current_user?(_payload)
        true
      end

      def record_connect_event(completion)
        type = completion.success? ? Contract::UsageEventType::CONNECT_COMPLETED : Contract::UsageEventType::CONNECT_FAILED
        UsageRecorder.record(user_id: current_user&.id, type: type, reason_code: completion.result)
      end
    end
  end

  # ログイン中なら、有効な bl_oauth（開始した接続）が無い要求でも、測定イベントを記録する
  def self.mutate_controller_event_without_flow
    Api::YoutubeController.class_eval do
      private

      def started_by_current_user?(_payload)
        !current_user.nil?
      end
    end
  end

  # ほかのアカウントの bl_oauth を使った要求でも、測定イベントを記録する
  def self.mutate_controller_event_account_unchecked
    Api::YoutubeController.class_eval do
      private

      def started_by_current_user?(payload)
        !current_user.nil? && !payload.nil?
      end
    end
  end

  # 再確認の応答に、チャンネル名を載せる（契約では常に null）
  def self.mutate_controller_title_exposed
    Api::YoutubeController.class_eval do
      private

      def youtube_view(state)
        { state: state, channel_title: "dummy-exposed-channel-title", can_recheck_at: recheck_gate.next_allowed_at(current_user)&.ceil&.iso8601 }
      end
    end
  end

  # 次に再確認できる時刻を返さない
  def self.mutate_controller_can_recheck_at_missing
    Api::YoutubeController.class_eval do
      private

      def youtube_view(state)
        { state: state, channel_title: nil, can_recheck_at: nil }
      end
    end
  end

  # コールバックの戻り先が、公開オリジンではなく、バックエンドのホストになる
  def self.mutate_controller_callback_redirect_backend_host
    Api::BaseController.class_eval do
      private

      def redirect_to_public(path)
        redirect_to "#{request.base_url}#{path}", allow_other_host: true, status: :found
      end
    end
  end

  # ============================================================
  # GoogleOidcClient（実物）: YouTube の認可 URL・コードの交換・失効
  # ============================================================

  # 認可 URL のクエリを組み立て直す。add: 足す項目 / drop: 外す項目
  def self.define_authorization_url(add: {}, drop: [])
    GoogleOidcClient.class_eval do
      define_method(:youtube_authorization_url) do |state:, code_challenge:, redirect_uri:, login_hint:|
        # 引数の検査（空・文字列でないと ArgumentError）は、本物と同じに残す。落ちた理由が、壊した項目だけになるように
        params = {
          client_id: @client_id, redirect_uri: non_blank!(redirect_uri, "redirect_uri"), response_type: "code", scope: @youtube_scope,
          state: non_blank!(state, "state"), code_challenge: non_blank!(code_challenge, "code_challenge"),
          code_challenge_method: GoogleOidcClient::CODE_CHALLENGE_METHOD, access_type: GoogleOidcClient::YOUTUBE_ACCESS_TYPE,
          prompt: GoogleOidcClient::YOUTUBE_PROMPT, login_hint: non_blank!(login_hint, "login_hint")
        }.merge(add).except(*drop)
        uri = URI.parse(@authorization_endpoint)
        uri.query = URI.encode_www_form(params)
        uri.to_s
      end
    end
  end

  # 過去の付与を混ぜる（include_granted_scopes）
  def self.mutate_oidc_include_granted_scopes
    define_authorization_url(add: { include_granted_scopes: "true" })
  end

  # 同意画面を毎回出さない（prompt なし。更新トークンが返らない場合がある）
  def self.mutate_oidc_prompt_missing
    define_authorization_url(drop: [ :prompt ])
  end

  # オフラインのアクセスを求めない（更新トークンが返らない）
  def self.mutate_oidc_access_type_missing
    define_authorization_url(drop: [ :access_type ])
  end

  # スコープを広げる（youtube の 1 種だけにする）
  def self.mutate_oidc_scope_widened
    define_authorization_url(add: { scope: "https://www.googleapis.com/auth/youtube openid email profile" })
  end

  # ID トークン用の nonce を付ける（この認可は ID トークンを使わない）
  def self.mutate_oidc_nonce_added
    define_authorization_url(add: { nonce: "dummy-nonce" })
  end

  # ログイン中のアカウントの選択を促す login_hint を付けない
  def self.mutate_oidc_login_hint_missing
    define_authorization_url(drop: [ :login_hint ])
  end

  # コードの交換のフォームから項目を外す。drop: 外す項目
  def self.define_token_form(drop)
    GoogleOidcClient.class_eval do
      define_method(:request_tokens) do |code, code_verifier, redirect_uri|
        form = {
          code: code, client_id: @client_id, client_secret: @client_secret, redirect_uri: redirect_uri,
          grant_type: "authorization_code", code_verifier: code_verifier
        }.except(*drop)
        response = @http.post_form(@token_endpoint, form: form)
        rejected!(response.status) unless response.status == 200

        body = response.json
        failed!(:token_response_invalid) unless body.is_a?(Hash)

        body
      rescue ExternalHttp::Failure
        failed!(:token_endpoint_unreachable)
      end
      private :request_tokens
    end
  end

  # PKCE の検証子を送らない
  def self.mutate_oidc_verifier_not_sent
    define_token_form([ :code_verifier ])
  end

  # クライアントの秘密値を送らない
  def self.mutate_oidc_secret_not_sent
    define_token_form([ :client_secret ])
  end

  # 受け取ったトークンを、Google へ失効の依頼をせずに、失効したことにする
  def self.mutate_oidc_revoke_noop
    GoogleOidcClient.class_eval do
      def revoke(token:)
        token.nil? ? nil : :revoked
      end
    end
  end

  # 応答に scope が無いとき、youtube が付与されたものとみなす
  def self.mutate_oidc_missing_scope_assumed_granted
    GoogleOidcClient.class_eval do
      private

      def grant_from(body)
        scope = body["scope"]
        failed!(:token_response_invalid) unless scope.nil? || scope.is_a?(String)

        scopes = scope.to_s.split
        scopes = [ @youtube_scope ] if scopes.empty?
        OAuthGrant.new(access_token: body["access_token"], refresh_token: body["refresh_token"], scopes: scopes, expires_in: body["expires_in"])
      rescue ArgumentError
        failed!(:token_response_invalid)
      end
    end
  end

  # ============================================================
  # FakeGoogleOidc: 疑似のコードの交換（本物と同じ検証をすること）
  # ============================================================

  # PKCE を照合しない
  def self.mutate_fake_pkce_unchecked
    FakeGoogleOidc.class_eval do
      private

      def verify_youtube_payload!(payload, _code_verifier, redirect_uri, now)
        failed!(:code_expired) if payload.fetch("exp") <= now.to_i
        failed!(:redirect_uri_mismatch) unless same?(payload.fetch("redirect_uri"), redirect_uri)
      end
    end
  end

  # 戻り先を照合しない
  def self.mutate_fake_redirect_unchecked
    FakeGoogleOidc.class_eval do
      private

      def verify_youtube_payload!(payload, code_verifier, _redirect_uri, now)
        failed!(:code_expired) if payload.fetch("exp") <= now.to_i
        failed!(:pkce_mismatch) unless same?(payload.fetch("challenge"), s256(code_verifier))
      end
    end
  end

  # コードの有効期限を見ない
  def self.mutate_fake_expiry_unchecked
    FakeGoogleOidc.class_eval do
      private

      def verify_youtube_payload!(payload, code_verifier, redirect_uri, _now)
        failed!(:redirect_uri_mismatch) unless same?(payload.fetch("redirect_uri"), redirect_uri)
        failed!(:pkce_mismatch) unless same?(payload.fetch("challenge"), s256(code_verifier))
      end
    end
  end

  # ============================================================
  # Dev::GoogleConnectController: 疑似の同意画面（開発・テストのみ）
  # ============================================================

  # 認可の要求のパラメータを検査しない
  def self.mutate_dev_consent_unvalidated
    Dev::GoogleConnectController.class_eval do
      private

      def validated_values!(_oidc)
        Dev::GoogleConnectController::FIELD_ORDER.to_h { |name| [ name, params[name] ] }
      end
    end
  end

  # 任意の戻り先を受け付ける（オープンリダイレクト）
  def self.mutate_dev_open_redirect
    Dev::GoogleConnectController.class_eval do
      alias_method :original_valid_value?, :valid_value?

      private

      def valid_value?(name, value, oidc)
        return value.is_a?(String) if name == "redirect_uri"

        original_valid_value?(name, value, oidc)
      end
    end
  end

  # 付けてはいけない項目（include_granted_scopes・nonce）を許す
  def self.mutate_dev_forbidden_fields_allowed
    Dev::GoogleConnectController.class_eval do
      private

      def validated_values!(oidc)
        values = Dev::GoogleConnectController::FIELD_ORDER.to_h { |name| [ name, params[name] ] }
        invalid = Dev::GoogleConnectController::FIELD_ORDER.reject { |name| valid_value?(name, values.fetch(name), oidc) }
        raise Api::Error::InvalidInput.new(fields: invalid, reason: :authorize_params_invalid) unless invalid.empty?

        values
      end
    end
  end

  # 失敗を、疑似の YouTube へ注入しない（チャンネルなし・ライブ未有効・確認不能の選択肢が、成立してしまう）
  def self.mutate_dev_choose_no_injection
    Dev::GoogleConnectController.class_eval do
      private

      def inject_failure(_scenario)
        nil
      end
    end
  end

  # 実物の Google が選ばれていても、画面を出す
  def self.mutate_dev_available_with_real_oidc
    Dev::GoogleConnectController.class_eval do
      private

      def fake_oidc!
        ExternalServices.current.google_oidc
      end
    end
  end

  # ============================================================
  # ログのフィルタ（config/initializers/filter_parameter_logging.rb）
  # ============================================================

  # login_hint を、ログから除くパラメータの一覧から外す（開発の疑似の同意画面の要求のログに、疑似のアカウントの識別子が出る）
  def self.mutate_filter_login_hint_missing
    Rails.application.config.filter_parameters.reject! { |entry| entry == :login_hint }
  end
end

RSpec.configure do |config|
  config.before(:suite) { MutationCatalog.apply(ENV.fetch("MUTATION")) }
end
