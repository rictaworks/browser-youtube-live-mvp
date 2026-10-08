# 疑似の外部サービス（FakeGoogleOidc・FakeRecaptchaVerifier）の共通の守り（issue #8）。
# 疑似は、開発・テストのためだけにある。本番では、構築しようとした時点で例外にする（本番で疑似が使われることを、構造で防ぐ）。
# 使う実装の選択は、環境の判定（AppEnvironment#external_services）で行う（ExternalServices）。環境変数では決めない。
module FakeServices
  # 疑似を使えない環境（本番）で、構築しようとした。メッセージは、環境の名前だけ
  class NotAllowedError < StandardError; end

  # environment は AppEnvironment。疑似を使う環境（development・test）でなければ NotAllowedError
  def self.verify_environment!(environment)
    return if environment.external_services == :fake

    raise NotAllowedError, "fake external services are not allowed in the #{environment.name} environment"
  end
end
