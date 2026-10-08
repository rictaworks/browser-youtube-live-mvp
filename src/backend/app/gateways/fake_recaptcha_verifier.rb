# 疑似の bot 判定（issue #8）。開発・テストのみ。RecaptchaVerifier と同じ使い方（verify・assess）で、外部サービスを呼ばない。
#
#   トークン dev-pass           :pass
#   トークン dev-fail           :fail
#   トークン dev-indeterminate  :indeterminate
#   それ以外（空・文字列でないものを含む）  :fail
#
# フロントエンドは、開発・テストでサイトキーが空のときだけ、dev-pass を送る（src/frontend/lib/recaptcha）。
# 本番では構築できない（FakeServices.verify_environment!）。行為名・ホスト・時刻は、判定に使わず、引数の形だけ検査する。
class FakeRecaptchaVerifier
  # トークンと判定の対応（開発・テスト用の取り決め）
  TOKENS = { "dev-pass" => :pass, "dev-fail" => :fail, "dev-indeterminate" => :indeterminate }.freeze
  # 取り決めに無いトークンの判定（疑似でも、合格・判定不能へ倒さない）
  UNKNOWN_TOKEN_VERDICT = :fail

  def initialize(environment: AppEnvironment.current)
    FakeServices.verify_environment!(environment)
  end

  def verify(token:, expected_action:, hostname:, now:)
    assess(token: token, expected_action: expected_action, hostname: hostname, now: now).verdict
  end

  def assess(token:, expected_action:, hostname:, now:)
    RecaptchaVerifier.check_call!(expected_action: expected_action, hostname: hostname, now: now)

    verdict = token.is_a?(String) ? TOKENS.fetch(token, UNKNOWN_TOKEN_VERDICT) : UNKNOWN_TOKEN_VERDICT
    RecaptchaVerifier::Assessment.new(verdict: verdict, reason: :fake, score: nil, threshold: nil)
  end

  def inspect
    "#<#{self.class.name}>"
  end
end
