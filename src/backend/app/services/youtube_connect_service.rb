require "base64"
require "digest"

# YouTube 接続（段階的な認可）の手続き（issue #11。requirements.md 7.2・7.3・8.4・10.5・23.1・25.4・28.1・28.2。
# src/contracts/http-api.md 3 章 connect/start・connect/callback・recheck）。HTTP・Cookie・セッションを知らない（コントローラが、それらを扱う）。
#
#   start(user:, redirect_uri:)         認可の開始。state・PKCE の検証子を作り、YouTube の認可 URL を組み立てる
#                                       （スコープは youtube の 1 種のみ・offline・consent・login_hint = ログイン中の Google の識別子 sub）。
#                                       state・検証子は、コントローラが bl_oauth（暗号化・短命の Cookie。用途 connect・アカウント識別子つき）に入れる
#   complete(user:, payload:, ...)      認可の完了（コールバック）。次の順に確かめ、結果（Completion）を返す
#                                         1. ログイン中のセッションのアカウントと、bl_oauth の状態・アカウントが一致する。state が一致する（不一致は不成立）
#                                         2. error パラメータ（access_denied は scope_denied、他は unverifiable）。コードがある
#                                         3. 進行中の配信が無い（7.4。あれば、再接続を受け付けない）
#                                         4. コードをトークンへ交換する（Google）。付与されたスコープに youtube が含まれない -> scope_denied /
#                                            更新トークンが無い -> no_refresh_token
#                                         5. 接続時の確認（YouTubeGateway#probe_channel。共通枠から支出。交換で得たアクセストークンで呼ぶ）
#                                            チャンネルが無い -> no_channel / 確認不能（共通枠の枯渇・一時的な失敗）-> unverifiable /
#                                            ライブ配信が有効 -> connected / 有効でない -> live_not_enabled
#                                       成立（connected・live_not_enabled）: 更新トークンを暗号化して保存し（TokenVault）、接続の行を作成または更新し、
#                                         保存済みの配信用ストリームの識別子を破棄する（10.5。成立のたびに）。1 つのトランザクション。チャンネル名はメモリに置く
#                                       不成立: 受け取ったトークンを保存せず破棄する。既存の接続が無い場合に限り、Google 側でも失効させる
#                                         （既存の接続があるときは、同じ付与を共有するため失効させない）。既存の接続の状態・トークン・ストリームの識別子は変更しない
#                                       想定外の例外（DB の失敗など）: トークンを受け取ったあと、成立（保存）しないまま例外になったときも、同じく破棄する
#                                         （更新トークンが、保存も失効もされずに、Google 側に残らない）。保存が済んだあとの例外では、失効させない。例外は握りつぶさず伝える
#   recheck(user:, now:)                再確認。接続が無ければ not_connected。認可失効は、再確認せず revoked のまま返す。
#                                       接続済み・ライブ未有効のとき、チャンネルとライブの有効を再確認し、connected と live_not_enabled を更新する。
#                                       トークンの更新が恒久的に失敗した・権限が不足していれば認可失効にする。確認不能は、状態を変えない
#   channel_title(user)                 チャンネル名（GET /api/state?with_channel=1）。最長 10 分のメモリのキャッシュ。取得に失敗しても例外にせず nil
#                                       （失敗を記録する）。失敗は短時間（config/youtube_connect.yml）だけ覚え、その間は YouTube を呼ばない
#                                       （障害中の再読み込みが、共通枠を使い切らない）。空・空白だけのチャンネル名も、取得できなかったものとして扱う。状態を変えない
#   broadcast_in_progress?(user)        進行中の配信（終了していない配信）があるか
#
# 確認（probe_channel）の失敗は、型付きの例外の disposition（YouTubeErrors）の接続状態に従って扱う: ライブ未有効・制限中（チャンネルの閉鎖・停止を含む）は
# live_not_enabled、権限の不足・更新トークンの無効は認可失効（接続時は scope_denied）、それ以外は確認不能。
# YouTube への呼び出しは、すべて窓口（YouTubeGateway）を通す（共通枠から記帳される）。窓口は、トランザクションの外で呼ぶ
# （確認は、成立の更新のトランザクションより前に済ませる）。接続の行ロックを持ったまま、TokenVault を呼ばない
# （アカウントごとの排他との順序で、デッドロックし得るため）。Google 側の失効は、YouTube API ではなく Google のトークンの失効の口で、台帳に記帳しない。
#
# 時刻は引数 now で受け取る。トークン・コード・state・検証子・チャンネル名を、ログ・例外・inspect に出さない
# （ログに出すのは、内部のアカウント識別子と、結果・理由の符号だけ）。想定外の例外（DB の失敗など）は、握りつぶさずに伝える。
class YouTubeConnectService
  LOG_TAG = "[youtube_connect]".freeze
  # bl_oauth の用途（OAuthStateCookie::PURPOSES）
  OAUTH_PURPOSE = "connect".freeze
  # bl_oauth の形（state・nonce・検証子）を満たすための値。ID トークンを使わないので、照合しない・認可 URL に載せない
  UNUSED_NONCE = "unused".freeze
  # 利用者が同意画面で拒否・取り消したときに、Google が戻り先に付ける error の値
  DENIED_ERROR = "access_denied".freeze
  # 空白だけのチャンネル名（全角の空白・改行しない空白を含む Unicode の空白）
  BLANK_TITLE = /\A[[:space:]]*\z/
  private_constant :BLANK_TITLE

  CR = Contract::ConnectResult
  CS = Contract::YoutubeConnectionState
  private_constant :CR, :CS

  # 接続が成立した結果（接続状態 connected・live_not_enabled）
  SUCCESS_RESULTS = [ CR::CONNECTED, CR::LIVE_NOT_ENABLED ].freeze

  # 認可の開始の結果。inspect に値を出さない（認可 URL に state を含む）
  Start = Data.define(:authorization_url, :state, :nonce, :code_verifier) do
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

  # 認可の完了の結果。result は契約の列挙 connect_result の値、reason は不成立の理由の符号（ログ用。応答に出さない。成立のとき nil）
  Completion = Data.define(:result, :reason) do
    def success?
      SUCCESS_RESULTS.include?(result)
    end
  end

  # 再確認の結果。outcome は :checked（確認できた。または認可失効のまま）・:not_connected・:unverifiable。state は接続状態（契約の列挙）
  Recheck = Data.define(:outcome, :state) do
    def checked?
      outcome == :checked
    end

    def not_connected?
      outcome == :not_connected
    end

    def unverifiable?
      outcome == :unverifiable
    end
  end

  # 接続時の確認・再確認の結果。kind は :connected・:live_not_enabled・:no_channel・:revoked・:unverifiable・:not_connected。
  # channel_title は、確認できたときだけ。チャンネル名なので、inspect に出さない
  Verdict = Data.define(:kind, :channel_title, :reason) do
    def inspect
      "#<#{self.class.name} kind=#{kind} reason=#{reason.inspect} [FILTERED]>"
    end

    def to_s
      inspect
    end

    # pp・pretty_inspect も、同じ表記にする（Data の既定の pretty_print は、メンバーの値を、そのまま出す）
    def pretty_print(printer)
      printer.text(inspect)
    end
  end
  private_constant :Verdict

  # 1 回の完了（complete）の途中の印。受け取ったトークンを保存したか。保存したあとは、例外になっても、トークンを失効させない。
  # 呼び出しごとに作る（サービスの状態にしない。同じサービスを複数のスレッドが使っても、混ざらない）
  Attempt = Struct.new(:saved)
  private_constant :Attempt

  # 現在の環境（AppEnvironment）の実装で組み立てる（Google は ExternalServices、YouTube は YouTubeServices。開発・テストは疑似、本番は実物）
  def self.current
    youtube = YouTubeServices.current
    new(oidc: ExternalServices.current.google_oidc, token_vault: youtube.token_vault, youtube_gateway: youtube.youtube_gateway)
  end

  # oidc は GoogleOidcClient か FakeGoogleOidc、token_vault は TokenVault、youtube_gateway は YouTubeGateway か FakeYouTubeGateway、
  # channel_names は ChannelNameCache（既定はプロセスで共有するもの）
  def initialize(oidc:, token_vault:, youtube_gateway:, channel_names: ChannelNameCache.shared, logger: Rails.logger)
    require_interface!(oidc, "oidc", %i[ youtube_authorization_url exchange_youtube_code revoke youtube_scope ])
    require_interface!(token_vault, "token_vault", %i[ store ])
    require_interface!(youtube_gateway, "youtube_gateway", %i[ probe_channel ])
    require_interface!(channel_names, "channel_names", %i[ fetch write delete ])

    @oidc = oidc
    @vault = token_vault
    @youtube = youtube_gateway
    @channel_names = channel_names
    @logger = logger
  end

  # 進行中の配信（終了していない配信）があるか。あれば、接続・再接続を受け付けない（7.4）
  def broadcast_in_progress?(user)
    Broadcast.owned_by(persisted_user!(user)).where.not(state: Contract::BroadcastState::ENDED).exists?
  end

  # 認可の開始。redirect_uri は、公開オリジンの /api/youtube/connect/callback
  def start(user:, redirect_uri:)
    account = persisted_user!(user)
    state = SecureRandom.urlsafe_base64(LoginProcedure::STATE_BYTES)
    code_verifier = SecureRandom.urlsafe_base64(LoginProcedure::VERIFIER_BYTES)
    authorization_url = @oidc.youtube_authorization_url(
      state: state, code_challenge: code_challenge_for(code_verifier), redirect_uri: redirect_uri, login_hint: account.google_sub
    )
    Start.new(authorization_url: authorization_url, state: state, nonce: UNUSED_NONCE, code_verifier: code_verifier)
  end

  # 認可の完了（コールバック）。user は、ログイン中のセッションのアカウント（無ければ nil）。payload は bl_oauth の状態
  # （OAuthStateCookie::Payload。用途 connect。無効・無しなら nil）。code・state・error は、コールバックのクエリの値
  # （無ければ nil。文字列でない値も来うる）。redirect_uri は、認可の開始と同じ値（コードの交換に要る）
  def complete(user:, payload:, code:, state:, error:, redirect_uri:, now:)
    check_completion_arguments!(user, payload, redirect_uri, now)

    refusal = refusal_before_exchange(user, payload, code, state, error)
    return failure(user, refusal.first, refusal.last) if refusal
    return failure(user, CR::UNVERIFIABLE, :broadcast_in_progress) if broadcast_in_progress?(user)

    grant = @oidc.exchange_youtube_code(code: code, code_verifier: payload.code_verifier, redirect_uri: redirect_uri)
    judge_discarding_unsaved(user, grant, now)
  rescue GoogleOidc::AuthenticationFailed => exchange_failure
    failure(user, CR::UNVERIFIABLE, :"exchange_#{exchange_failure.reason}")
  end

  # 再確認。user は保存済みのアカウント
  def recheck(user:, now:)
    account = persisted_user!(user)
    Preconditions.time!(now, "now")

    connection = YoutubeConnection.owned_by(account).take
    return Recheck.new(outcome: :not_connected, state: CS::NOT_CONNECTED) if connection.nil?
    return Recheck.new(outcome: :checked, state: CS::REVOKED) if connection.state == CS::REVOKED

    apply_recheck(account, connection, verify(connection, nil), now)
  end

  # チャンネル名。キャッシュがあれば、YouTube を呼ばない。取得に失敗しても例外にせず nil（失敗を記録し、一定の秒数だけ失敗を覚えて、その間は YouTube を呼ばない）。
  # 接続が無い・認可失効なら nil（YouTube を呼ばない）。状態を変えない（読み取りだけ。GET の副作用なし）
  def channel_title(user)
    account = persisted_user!(user)
    connection = YoutubeConnection.owned_by(account).take
    return nil if connection.nil? || connection.state == CS::REVOKED

    @channel_names.fetch(account.id) { title_from(account, connection) }
  end

  # 部品（トークンを持つもの）を出さない
  def inspect
    "#<#{self.class.name}>"
  end

  private

  # --- 認可の完了 ---

  # コードを交換する前に拒否する理由（[結果, 理由の符号]。無ければ nil）。トークンを受け取る前なので、失効は要らない
  def refusal_before_exchange(user, payload, code, state, error)
    return [ CR::UNVERIFIABLE, :not_logged_in ] if user.nil?
    return [ CR::UNVERIFIABLE, :state_cookie_invalid ] if payload.nil?
    return [ CR::UNVERIFIABLE, :account_mismatch ] unless payload.user_id == user.id
    return [ CR::UNVERIFIABLE, :state_mismatch ] unless state_matches?(payload.state, state)
    return authorization_refusal(error) unless error.nil?
    return [ CR::UNVERIFIABLE, :code_missing ] unless code.is_a?(String) && !code.strip.empty?

    [ CR::UNVERIFIABLE, :code_too_long ] if code.length > LoginProcedure::CODE_MAX_LENGTH
  end

  # Google が戻り先に付けた error。利用者の拒否・取り消し（access_denied）は権限の拒否、それ以外は確認不能
  def authorization_refusal(error)
    error == DENIED_ERROR ? [ CR::SCOPE_DENIED, :authorization_denied ] : [ CR::UNVERIFIABLE, :authorization_error ]
  end

  def state_matches?(expected, given)
    given.is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(expected, given)
  end

  # 受け取ったトークンは、保存（成立）しない限り、必ず破棄する。不成立の確定も、想定外の例外（DB の失敗など）も、ここの 1 か所で破棄する
  # （ensure。例外は握りつぶさず、そのまま伝える）。保存が済んだあと（attempt.saved）の例外では、破棄しない（保存した更新トークンを無効にしない）
  def judge_discarding_unsaved(user, grant, now)
    attempt = Attempt.new(false)
    judge(user, grant, now, attempt)
  ensure
    discard_grant(user, grant) unless attempt.saved
  end

  # 交換で得た付与を判定する（7.2 の表）。権限 -> 更新トークン -> 接続時の確認の順
  def judge(user, grant, now, attempt)
    return failure(user, CR::SCOPE_DENIED, :youtube_scope_not_granted) unless grant.scope?(@oidc.youtube_scope)
    return failure(user, CR::NO_REFRESH_TOKEN, :refresh_token_missing) unless grant.refresh_token?

    verdict = verify(nil, grant.access_token)
    case verdict.kind
    when :connected, :live_not_enabled then establish(user, grant, verdict, now, attempt)
    when :no_channel then failure(user, CR::NO_CHANNEL, verdict.reason)
    when :revoked then failure(user, CR::SCOPE_DENIED, verdict.reason)
    else failure(user, CR::UNVERIFIABLE, verdict.reason)
    end
  end

  # 接続の成立。更新トークンの保存・状態・ストリームの識別子の破棄は、1 つのトランザクション。保存が済んだら印を付ける（以降は、トークンを破棄しない）。
  # チャンネル名は、確定したあとでメモリに置く
  def establish(user, grant, verdict, now, attempt)
    persist_connection(user, grant, verdict.kind, now)
    attempt.saved = true
    remember_channel_title(user, verdict.channel_title)

    result = verdict.kind == :connected ? CR::CONNECTED : CR::LIVE_NOT_ENABLED
    @logger.info("#{LOG_TAG} completed #{account_field(user)} result=#{result}")
    Completion.new(result: result, reason: nil)
  end

  # TokenVault#store は、接続が無ければ作り（接続済み）、あれば暗号文だけを置き換える（状態・ストリームの識別子・時刻は変えない）。
  # したがって、保存のあとで、状態（認可失効のままだと TokenRevoked が続く）・時刻・ストリームの識別子を、必ず更新する。
  # 保存の前に、接続の行をロックしない（TokenVault は、アカウントごとの排他のあとで、行をロックする。逆の順序は、デッドロックし得る）
  def persist_connection(user, grant, kind, now)
    ApplicationRecord.transaction do
      connection = @vault.store(user_id: user.id, refresh_token: grant.refresh_token, now: now)
      apply_state!(connection, kind)
      connection.update!(connected_at: now, last_verified_at: now)
      connection.discard_stream! if StreamReplacementPolicy.discard?(trigger: StreamReplacementPolicy::YOUTUBE_CONNECTED)
    end
  end

  def apply_state!(connection, kind)
    kind == :connected ? connection.mark_connected! : connection.mark_live_not_enabled!
  end

  # 受け取ったトークンを保存しない（破棄する）。既存の接続が無ければ、Google 側でも失効させる。
  # 既存の接続があれば、同じ付与（同じ利用者・同じクライアント）を共有するため、失効させない（既存のトークンも失効してしまう）。
  # 失効の失敗は、結果（または伝わる例外）を変えない（記録する）。失効は、YouTube API ではなく Google のトークンの失効の口（台帳に記帳しない）
  def discard_grant(user, grant)
    return if YoutubeConnection.owned_by(user).exists?

    @oidc.revoke(token: grant.refresh_token || grant.access_token)
  rescue YouTubeErrors::Base => error
    @logger.warn("#{LOG_TAG} revoke failed #{account_field(user)} #{error.message}")
  end

  def failure(user, result, reason)
    @logger.warn("#{LOG_TAG} failed #{account_field(user)} result=#{result} reason=#{reason}")
    Completion.new(result: result, reason: reason)
  end

  # --- 再確認 ---

  def apply_recheck(user, connection, verdict, now)
    case verdict.kind
    when :connected, :live_not_enabled then rechecked(user, connection, verdict, now)
    when :revoked then revoked(user, connection)
    when :not_connected then Recheck.new(outcome: :not_connected, state: CS::NOT_CONNECTED)
    else recheck_unverifiable(user, connection, verdict)
    end
  end

  def rechecked(user, connection, verdict, now)
    ApplicationRecord.transaction do
      apply_state!(connection, verdict.kind)
      connection.update!(last_verified_at: now)
    end
    remember_channel_title(user, verdict.channel_title)

    state = verdict.kind == :connected ? CS::CONNECTED : CS::LIVE_NOT_ENABLED
    @logger.info("#{LOG_TAG} rechecked #{account_field(user)} state=#{state}")
    Recheck.new(outcome: :checked, state: state)
  end

  # トークンの更新が恒久的に失敗した（TokenVault が認可失効にしている）・権限が不足している。認可失効にする（再接続を促す）
  def revoked(user, connection)
    connection.mark_revoked!
    @logger.warn("#{LOG_TAG} rechecked #{account_field(user)} state=#{CS::REVOKED}")
    Recheck.new(outcome: :checked, state: CS::REVOKED)
  end

  # チャンネルが見つからない・共通枠の枯渇・一時的な失敗。状態を変えない
  def recheck_unverifiable(user, connection, verdict)
    @logger.warn("#{LOG_TAG} recheck unverifiable #{account_field(user)} reason=#{verdict.reason}")
    Recheck.new(outcome: :unverifiable, state: connection.state)
  end

  # --- チャンネル名 ---

  # キャッシュに無いときの取得。チャンネル名が得られなければ nil（失敗は一定の秒数だけ覚える。チャンネル名としてはキャッシュされない）。理由を記録する
  def title_from(user, connection)
    verdict = verify(connection, nil)
    return verdict.channel_title if verdict.channel_title

    @logger.warn("#{LOG_TAG} channel title unavailable #{account_field(user)} reason=#{verdict.reason}")
    nil
  end

  # 確認できたチャンネル名を、メモリに置く。分からないとき（チャンネルの閉鎖など）は、前のチャンネル名を捨てる（古い名前を残さない）
  def remember_channel_title(user, title)
    @channel_names.delete(user.id)
    @channel_names.write(user.id, title) if title
  end

  # --- 接続時の確認 ---

  # 接続時の確認・再確認。connection が無いとき（接続の成立前）は、交換で得た access_token で呼ぶ（TokenVault を使わない）。
  # 窓口は、トランザクションの外で呼ぶ。失敗は、結果（Verdict）にする: 型付きの例外は disposition の接続状態に従い、
  # 復号できない暗号文・未接続（接続の解除との競合）は、確認不能・未接続
  def verify(connection, access_token)
    verdict_for_probe(@youtube.probe_channel(connection, access_token: access_token))
  rescue YouTubeErrors::Base => error
    verdict_for_error(error)
  rescue TokenVault::Undecryptable
    Verdict.new(kind: :unverifiable, channel_title: nil, reason: :undecryptable)
  rescue TokenVault::NotConnected
    Verdict.new(kind: :not_connected, channel_title: nil, reason: :not_connected)
  end

  def verdict_for_probe(probe)
    return Verdict.new(kind: :no_channel, channel_title: nil, reason: :channel_not_found) if probe.no_channel?

    # 空・空白だけのチャンネル名は、取得できなかったものとして扱う（接続は成立のまま。キャッシュの保持の検査で、例外にしない）
    usable = usable_title?(probe.channel_title)
    Verdict.new(
      kind: probe.live_not_enabled? ? :live_not_enabled : :connected, channel_title: usable ? probe.channel_title : nil,
      reason: usable ? nil : :channel_title_blank
    )
  end

  # 保持してよいチャンネル名か（文字列で、空・空白だけでない。全角の空白などだけのものも除く）
  def usable_title?(title)
    title.is_a?(String) && !title.strip.empty? && !title.match?(BLANK_TITLE)
  end

  # 窓口は、チャンネルの一覧取得の側の失敗（channelClosed など）を、結果にせず例外のまま伝える。disposition の接続状態に従う
  def verdict_for_error(error)
    kind =
      case error.disposition.connection_state
      when CS::LIVE_NOT_ENABLED then :live_not_enabled
      when CS::REVOKED then :revoked
      else :unverifiable
      end
    Verdict.new(kind: kind, channel_title: nil, reason: error_reason(error))
  end

  # 例外のクラス名から作る、理由の符号（YouTubeErrors::Transient -> :transient）。メッセージ・応答の本文を使わない
  def error_reason(error)
    error.class.name.demodulize.underscore.to_sym
  end

  # --- 部品 ---

  def code_challenge_for(code_verifier)
    Base64.urlsafe_encode64(Digest::SHA256.digest(code_verifier), padding: false)
  end

  # ログに出す、アカウントの項目（内部のアカウント識別子だけ。ログインしていなければ none）
  def account_field(user)
    "user_id=#{user ? user.id : 'none'}"
  end

  def check_completion_arguments!(user, payload, redirect_uri, now)
    raise ArgumentError, "user must be a persisted User or nil" unless user.nil? || (user.is_a?(User) && user.persisted?)
    unless payload.nil? || (payload.is_a?(OAuthStateCookie::Payload) && payload.purpose == OAUTH_PURPOSE)
      raise ArgumentError, "payload must be nil or the state of a connect (OAuthStateCookie::Payload with the connect purpose)"
    end
    raise ArgumentError, "redirect_uri must be a non-empty String" unless redirect_uri.is_a?(String) && !redirect_uri.strip.empty?

    Preconditions.time!(now, "now")
  end

  def persisted_user!(user)
    raise ArgumentError, "user must be a persisted User" unless user.is_a?(User) && user.persisted?

    user
  end

  def require_interface!(object, name, methods)
    missing = methods.reject { |method| object.respond_to?(method) }
    raise ArgumentError, "#{name} must respond to #{missing.join(', ')}" unless missing.empty?
  end
end
