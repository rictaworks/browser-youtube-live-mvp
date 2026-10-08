# bot 判定（reCAPTCHA v3）の検証（issue #8。requirements.md 9.1・9.2・28.1。src/contracts/http-api.md 1.8）。
#
# 利用者のブラウザが得たトークンを、サーバー側で siteverify に照会し、次を検証して、:pass・:fail・:indeterminate を返す
# （#5 の StartAdmission の bot_verdict。:pass 以外は拒否する）。
#   success          真
#   action           期待する行為名と一致（login・youtube_connect・broadcast_start）
#   hostname         公開オリジンのホストと一致（発行元。大文字・小文字は区別しない）
#   challenge_ts     有効期限 2 分以内（時計のずれは 30 秒まで許す）
#   score            設定 bot_score_threshold 以上（判定のたびに、現在の設定を読む）
# 判定できない場合は :indeterminate（受理側へ倒さない。9.3）。
#   - 到達できない・タイムアウト・TLS の失敗・5xx など 200 以外・解釈できない応答（JSON でない・形が違う）
#   - error-codes が空でない応答（success の値によらず。検証そのものが完了していない）
#   - 無料枠の超過を示す応答（siteverify は無料枠を超えると fail open で success: true・score: 0.9・"Over free quota." を返す。
#     success: true をそのまま通さない）
# トークンが無い・長すぎる・文字列でないときは :fail（外部サービスを呼ばない）。
#
# Google は新規の実装に CreateAssessment（fail closed）を推奨するが、Cloud の認証情報が要る（requirements.md 29.4 に無い）ため、
# 本 issue では siteverify（RECAPTCHA_SECRET_KEY）を使う。
#
# IP アドレスを siteverify へ送らない（remoteip を付けない。requirements.md 28.2）。トークン・秘密鍵をログ・例外に出さない。
# 応答の自由な文字列（error-codes など）も、ログへ出さない。出すのは、判定・理由の符号・行為名・スコア・閾値だけ。
# 時刻は引数 now で受け取る（実時計を読まない）。通信は ExternalHttp（接続 3 秒・読み取り 5 秒）。
class RecaptchaVerifier
  ACTIONS = %w[ login youtube_connect broadcast_start ].freeze
  # reCAPTCHA の応答（トークン）の有効期限（秒）。https://developers.google.com/recaptcha/docs/verify
  TOKEN_MAX_AGE_SECONDS = 120
  # challenge_ts が now より先でもよい範囲（秒。時計のずれ）
  CLOCK_SKEW_SECONDS = 30
  # トークンの長さの上限（文字）。v3 のトークンは 2,000 文字前後
  TOKEN_MAX_LENGTH = 4096
  QUOTA_MESSAGE = /over\s+free\s+quota/i
  LOG_TAG = "[recaptcha]".freeze

  # 判定。verdict は :pass・:fail・:indeterminate、reason は理由の符号。score・threshold は、そこまで進んだときだけ（無ければ nil）
  Assessment = Data.define(:verdict, :reason, :score, :threshold)

  # 判定の途中で結論が出た（内部の早期の終了）
  class Concluded < StandardError
    attr_reader :assessment

    def initialize(assessment)
      @assessment = assessment
      super("concluded")
    end
  end
  private_constant :Concluded

  # 呼び出しの引数の検査（疑似の FakeRecaptchaVerifier と共通）。誤りは ArgumentError
  def self.check_call!(expected_action:, hostname:, now:)
    raise ArgumentError, "expected_action must be one of: #{ACTIONS.join(', ')}" unless ACTIONS.include?(expected_action)
    raise ArgumentError, "hostname must be a non-empty String" unless hostname.is_a?(String) && !hostname.strip.empty?
    raise ArgumentError, "now must be a Time" unless now.is_a?(Time)
  end

  # settings_source は、呼ぶと現在の設定（Settings）を返すもの。判定のたびに呼ぶ（管理画面の変更を、次の判定から反映する）
  def initialize(secret:, endpoint:, settings_source:, http: ExternalHttp.new, logger: Rails.logger)
    raise ArgumentError, "secret must be a non-empty String" unless secret.is_a?(String) && !secret.strip.empty?
    raise ArgumentError, "endpoint must be an https URL" unless endpoint.is_a?(String) && endpoint.start_with?("https://")
    raise ArgumentError, "settings_source must respond to call" unless settings_source.respond_to?(:call)

    @secret = secret
    @endpoint = endpoint
    @settings_source = settings_source
    @http = http
    @logger = logger
  end

  # :pass・:fail・:indeterminate
  def verify(token:, expected_action:, hostname:, now:)
    assess(token: token, expected_action: expected_action, hostname: hostname, now: now).verdict
  end

  # 判定と理由。ログに、判定・理由・行為名・スコア・閾値を出す
  def assess(token:, expected_action:, hostname:, now:)
    self.class.check_call!(expected_action: expected_action, hostname: hostname, now: now)

    result =
      begin
        evaluate(token, expected_action, hostname, now)
      rescue Concluded => concluded
        concluded.assessment
      end
    log(result, expected_action)
    result
  end

  # 秘密鍵を出さない
  def inspect
    "#<#{self.class.name}>"
  end

  private

  def evaluate(token, expected_action, hostname, now)
    check_token!(token)
    body = fetch_verification(token)
    check_quota!(body)
    check_error_codes!(body)
    check_success!(body)
    check_action!(body, expected_action)
    check_hostname!(body, hostname)
    check_challenge_ts!(body, now)
    check_score!(body)
  end

  def conclude!(verdict, reason, score: nil, threshold: nil)
    raise Concluded.new(Assessment.new(verdict: verdict, reason: reason, score: score, threshold: threshold))
  end

  # トークンが無い・文字列でない・長すぎる。外部サービスを呼ばない
  def check_token!(token)
    conclude!(:fail, :token_missing) unless token.is_a?(String) && !token.strip.empty?
    conclude!(:fail, :token_too_long) if token.length > TOKEN_MAX_LENGTH
  end

  # siteverify に照会する。送るのは secret と response（トークン）だけ。到達できない・200 以外・JSON でない・オブジェクトでない応答は、判定不能
  def fetch_verification(token)
    response = @http.post_form(@endpoint, form: { secret: @secret, response: token })
    conclude!(:indeterminate, :http_status) unless response.status == 200

    body = response.json
    conclude!(:indeterminate, :invalid_response) unless body.is_a?(Hash)

    body
  rescue ExternalHttp::Failure => failure
    conclude!(:indeterminate, failure_reason(failure))
  end

  # ExternalHttp::Failure の符号を、判定の理由へ対応づける。応答が読めない（大きすぎる・JSON でない）は invalid_response、それ以外は unreachable
  def failure_reason(failure)
    %i[ response_too_large invalid_json ].include?(failure.reason) ? :invalid_response : :unreachable
  end

  # 無料枠の超過（fail open の応答）。応答のどこにあっても（キー・値の文字列を再帰的に見る）判定不能
  def check_quota!(body)
    conclude!(:indeterminate, :quota_exceeded) if mentions_quota?(body)
  end

  def mentions_quota?(value)
    case value
    when String then QUOTA_MESSAGE.match?(value)
    when Array then value.any? { |item| mentions_quota?(item) }
    when Hash then value.any? { |key, item| mentions_quota?(key) || mentions_quota?(item) }
    else false
    end
  end

  def check_error_codes!(body)
    return unless body.key?("error-codes")

    codes = body.fetch("error-codes")
    conclude!(:indeterminate, :invalid_response) unless codes.is_a?(Array) && codes.all?(String)
    conclude!(:indeterminate, :error_codes) unless codes.empty?
  end

  def check_success!(body)
    success = body["success"]
    conclude!(:indeterminate, :invalid_response) unless [ true, false ].include?(success)
    conclude!(:fail, :verification_failed) unless success
  end

  def check_action!(body, expected_action)
    conclude!(:fail, :action_mismatch) unless body["action"] == expected_action
  end

  def check_hostname!(body, hostname)
    actual = body["hostname"]
    conclude!(:fail, :hostname_mismatch) unless actual.is_a?(String) && actual.casecmp?(hostname)
  end

  def check_challenge_ts!(body, now)
    issued_at = parse_time(body["challenge_ts"])
    conclude!(:indeterminate, :challenge_ts_invalid) if issued_at.nil?

    age = now - issued_at
    conclude!(:fail, :token_expired) if age > TOKEN_MAX_AGE_SECONDS
    conclude!(:indeterminate, :challenge_ts_in_future) if age < -CLOCK_SKEW_SECONDS
  end

  def parse_time(value)
    return nil unless value.is_a?(String)

    Time.iso8601(value)
  rescue ArgumentError
    nil
  end

  # スコアを、現在の設定の閾値と比べる。閾値と同じなら合格
  def check_score!(body)
    score = body["score"]
    conclude!(:indeterminate, :score_invalid) unless score.is_a?(Numeric) && score.to_f.finite? && score.between?(0, 1)

    threshold = current_threshold
    conclude!(:fail, :low_score, score: score, threshold: threshold) if score < threshold

    Assessment.new(verdict: :pass, reason: :ok, score: score, threshold: threshold)
  end

  def current_threshold
    settings = @settings_source.call
    raise ArgumentError, "settings_source must return a Settings" unless settings.is_a?(Settings)

    settings.bot_score_threshold
  end

  def log(result, expected_action)
    parts = [ LOG_TAG, "verdict=#{result.verdict}", "reason=#{result.reason}", "action=#{expected_action}" ]
    parts << "score=#{result.score}" unless result.score.nil?
    parts << "threshold=#{result.threshold}" unless result.threshold.nil?
    message = parts.join(" ")
    result.verdict == :pass ? @logger.info(message) : @logger.warn(message)
  end
end
