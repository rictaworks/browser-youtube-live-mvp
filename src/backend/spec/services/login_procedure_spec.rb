require "rails_helper"
require "support/model_support"
require "support/google_oidc_support"
require "support/log_capture"

# ログインの手続き LoginProcedure（issue #8。requirements.md 7.1・23.1・28.1）。HTTP・Cookie・セッションを知らない。
#   start     認可の開始: state・nonce・PKCE の検証子（S256 の challenge）を作り、認可 URL を組み立てる
#   complete  認可の完了（コールバック）: state の照合 → コードの交換と ID トークンの検証 → sub でアカウントを特定（保留中なら作らない）
#             → 最終ログイン時刻の更新。結果は :logged_in・:registration_held・:failed（理由の符号つき）
RSpec.describe LoginProcedure do
  include GoogleOidcSupport

  let(:now) { Time.utc(2026, 10, 8, 3, 0, 0) }
  let(:secret) { "dummy-secret-key-base-for-login-procedure-0001" }
  let(:fake) { FakeGoogleOidc.new(secret: secret) }
  let(:registry) { AccountRegistry.new(secret: secret) }
  let(:procedure) { described_class.new(oidc: fake, registry: registry) }
  let(:callback_uri) { "https://app.example.test/api/auth/callback" }

  # 開始から、疑似の認可画面での選択までを再現して、コールバックの入力（保管した状態・コード・state）を作る
  def begin_login(sub: "dev-user-1")
    started = procedure.start(redirect_uri: callback_uri)
    challenge = Rack::Utils.parse_query(URI.parse(started.authorization_url).query).fetch("code_challenge")
    code = fake.issue_code(sub: sub, nonce: started.nonce, code_challenge: challenge, redirect_uri: callback_uri, now: now)
    payload = OAuthStateCookie::Payload.new(state: started.state, nonce: started.nonce, code_verifier: started.code_verifier, purpose: "login", user_id: nil)
    [ started, payload, code ]
  end

  def complete(payload:, code:, state:, error: nil, redirect: callback_uri, at: now, using: procedure)
    using.complete(payload: payload, code: code, state: state, error: error, redirect_uri: redirect, now: at)
  end

  describe "#start" do
    let(:started) { procedure.start(redirect_uri: callback_uri) }
    let(:query) { Rack::Utils.parse_query(URI.parse(started.authorization_url).query) }

    it "認可 URL と、state・nonce・PKCE の検証子を返す。URL の state・nonce・redirect_uri は、返した値と同じ" do
      expect(query.fetch("state")).to eq(started.state)
      expect(query.fetch("nonce")).to eq(started.nonce)
      expect(query.fetch("redirect_uri")).to eq(callback_uri)
    end

    it "PKCE: code_challenge は検証子の SHA-256（S256）の base64url。method は S256" do
      expect(query.fetch("code_challenge_method")).to eq("S256")
      expect(query.fetch("code_challenge")).to eq(s256_challenge(started.code_verifier))
    end

    it "state・nonce は 32 バイトの乱数（base64url 43 文字）。検証子は 64 バイトの乱数（86 文字。RFC 7636 の 43〜128 文字）" do
      expect(started.state).to match(/\A[A-Za-z0-9_-]{43}\z/)
      expect(started.nonce).to match(/\A[A-Za-z0-9_-]{43}\z/)
      expect(started.code_verifier).to match(/\A[A-Za-z0-9_-]{86}\z/)
    end

    it "呼ぶたびに、新しい state・nonce・検証子（再利用しない）" do
      values = Array.new(50) { procedure.start(redirect_uri: callback_uri) }

      expect(values.map(&:state).uniq.size).to eq(50)
      expect(values.map(&:nonce).uniq.size).to eq(50)
      expect(values.map(&:code_verifier).uniq.size).to eq(50)
    end

    it "state・nonce・検証子は、互いに別の値" do
      expect([ started.state, started.nonce, started.code_verifier ].uniq.size).to eq(3)
    end

    it "乱数は SecureRandom から（推測できる値を使わない）" do
      allow(SecureRandom).to receive(:urlsafe_base64).and_call_original

      started

      expect(SecureRandom).to have_received(:urlsafe_base64).with(32).twice
      expect(SecureRandom).to have_received(:urlsafe_base64).with(64).once
    end

    it "認可 URL の組み立ては、ゲートウェイ（oidc）に任せる" do
      oidc = instance_double(FakeGoogleOidc)
      allow(oidc).to receive(:authorization_url).and_return("https://accounts.example.test/auth?x=1")

      result = described_class.new(oidc: oidc, registry: registry).start(redirect_uri: callback_uri)

      expect(result.authorization_url).to eq("https://accounts.example.test/auth?x=1")
      expect(oidc).to have_received(:authorization_url).with(
        state: result.state, nonce: result.nonce, code_challenge: s256_challenge(result.code_verifier), redirect_uri: callback_uri
      )
    end

    it "redirect_uri が空・文字列でなければ ArgumentError" do
      [ nil, "", "  ", 1 ].each do |bad|
        expect { procedure.start(redirect_uri: bad) }.to raise_error(ArgumentError, /redirect_uri/)
      end
    end

    it "検証子・state を inspect に出さない" do
      expect(started.inspect).not_to include(started.code_verifier)
      expect(started.inspect).not_to include(started.state)
      expect(started.inspect).not_to include(started.nonce)
    end
  end

  describe "#complete（成功）" do
    it "新しいアカウント: :logged_in。アカウントが作られ、最終ログイン時刻は now" do
      _started, payload, code = begin_login

      result = complete(payload: payload, code: code, state: payload.state)

      expect(result.status).to eq(:logged_in)
      expect(result.logged_in?).to be(true)
      expect(result.user).to be_persisted
      expect(result.user.google_sub).to eq("dev-user-1")
      expect(result.user.last_login_at).to eq(now)
      expect(result.reason).to be_nil
    end

    it "登録済みのアカウント: :logged_in。同じアカウントで、最終ログイン時刻が now へ更新される" do
      user = create(:user, google_sub: "dev-user-1", last_login_at: now - 10.days)
      _started, payload, code = begin_login

      result = complete(payload: payload, code: code, state: payload.state)

      expect(result.status).to eq(:logged_in)
      expect(result.user.id).to eq(user.id)
      expect(User.find(user.id).last_login_at).to eq(now)
      expect(User.count).to eq(1)
    end

    it "メール・氏名などを保存しない（アカウントの行は sub・作成時刻・最終ログイン時刻だけ）" do
      _started, payload, code = begin_login

      complete(payload: payload, code: code, state: payload.state)

      expect(User.first.attributes.keys).to match_array(%w[ id google_sub created_at last_login_at ])
    end

    it "ゲートウェイへ、保管した検証子・nonce と、同じ redirect_uri・now を渡す" do
      oidc = instance_double(FakeGoogleOidc)
      allow(oidc).to receive(:authenticate).and_return(GoogleOidc::Identity.new(sub: "dev-user-2"))
      _started, payload, code = begin_login

      described_class.new(oidc: oidc, registry: registry).complete(payload: payload, code: code, state: payload.state, error: nil, redirect_uri: callback_uri, now: now)

      expect(oidc).to have_received(:authenticate).with(code: code, code_verifier: payload.code_verifier, nonce: payload.nonce, redirect_uri: callback_uri, now: now)
    end

    it "3 つの疑似アカウントのどれでも、それぞれ別のアカウントでログインできる" do
      subs = %w[ dev-user-1 dev-user-2 dev-user-3 ].map do |sub|
        _started, payload, code = begin_login(sub: sub)
        complete(payload: payload, code: code, state: payload.state).user.google_sub
      end

      expect(subs).to eq(%w[ dev-user-1 dev-user-2 dev-user-3 ])
      expect(User.count).to eq(3)
    end
  end

  describe "#complete（state の照合）" do
    it "保管した状態が無い（cookie が無い・期限切れ・改ざん）: :failed（state_cookie_invalid）。コードを交換しない" do
      oidc = instance_double(FakeGoogleOidc)
      allow(oidc).to receive(:authenticate)

      result = described_class.new(oidc: oidc, registry: registry).complete(payload: nil, code: "dummy-code", state: "dummy-state", error: nil, redirect_uri: callback_uri, now: now)

      expect(result.status).to eq(:failed)
      expect(result.reason).to eq(:state_cookie_invalid)
      expect(oidc).not_to have_received(:authenticate)
      expect(User.count).to eq(0)
    end

    {
      "state が違う" => "dummy-other-state",
      "state が空" => "",
      "state が無い（nil）" => nil,
      "state が配列" => [ "x" ],
      "state がハッシュ" => { "a" => "b" },
      "state の前後に空白" => :padded
    }.each do |label, value|
      it "#{label}: :failed（state_mismatch）。コードを交換しない・アカウントを作らない" do
        oidc = instance_double(FakeGoogleOidc)
        allow(oidc).to receive(:authenticate)
        _started, payload, code = begin_login
        given = value == :padded ? " #{payload.state} " : value

        result = described_class.new(oidc: oidc, registry: registry).complete(payload: payload, code: code, state: given, error: nil, redirect_uri: callback_uri, now: now)

        expect(result.status).to eq(:failed)
        expect(result.reason).to eq(:state_mismatch)
        expect(oidc).not_to have_received(:authenticate)
        expect(User.count).to eq(0)
      end
    end

    it "state の比較は、定数時間（ActiveSupport::SecurityUtils.secure_compare）" do
      _started, payload, code = begin_login
      allow(ActiveSupport::SecurityUtils).to receive(:secure_compare).and_call_original

      complete(payload: payload, code: code, state: payload.state)

      expect(ActiveSupport::SecurityUtils).to have_received(:secure_compare).with(payload.state, payload.state)
    end

    it "別のログインの state（他のブラウザの state）では通らない" do
      _first, first_payload, first_code = begin_login
      _second, second_payload, = begin_login

      result = complete(payload: first_payload, code: first_code, state: second_payload.state)

      expect(result.reason).to eq(:state_mismatch)
    end
  end

  describe "#complete（認可の拒否・コードの欠落）" do
    [ "access_denied", "", "server_error", [ "access_denied" ], { "a" => "b" } ].each do |error|
      it "error パラメータ（#{error.inspect}）: :failed（authorization_denied）。コードを交換しない" do
        oidc = instance_double(FakeGoogleOidc)
        allow(oidc).to receive(:authenticate)
        _started, payload, code = begin_login

        result = described_class.new(oidc: oidc, registry: registry).complete(payload: payload, code: code, state: payload.state, error: error, redirect_uri: callback_uri, now: now)

        expect(result.status).to eq(:failed)
        expect(result.reason).to eq(:authorization_denied)
        expect(oidc).not_to have_received(:authenticate)
      end
    end

    it "state が違えば、error パラメータがあっても state_mismatch（改ざんを先に検出する）" do
      _started, payload, code = begin_login

      result = complete(payload: payload, code: code, state: "dummy-other-state", error: "access_denied")

      expect(result.reason).to eq(:state_mismatch)
    end

    [ nil, "", "  ", 123, [ "x" ], { "a" => "b" } ].each do |bad|
      it "コードが #{bad.inspect}: :failed（code_missing）" do
        _started, payload, = begin_login

        result = complete(payload: payload, code: bad, state: payload.state)

        expect(result.reason).to eq(:code_missing)
      end
    end

    it "コードが長すぎる（#{described_class::CODE_MAX_LENGTH + 1} 文字）: :failed（code_too_long）。交換しない" do
      oidc = instance_double(FakeGoogleOidc)
      allow(oidc).to receive(:authenticate)
      _started, payload, = begin_login

      result = described_class.new(oidc: oidc, registry: registry).complete(
        payload: payload, code: "a" * (described_class::CODE_MAX_LENGTH + 1), state: payload.state, error: nil, redirect_uri: callback_uri, now: now
      )

      expect(result.reason).to eq(:code_too_long)
      expect(oidc).not_to have_received(:authenticate)
    end
  end

  describe "#complete（認証の失敗）" do
    it "PKCE の検証子が違う（別のブラウザで開始した）: :failed（pkce_mismatch）" do
      _started, payload, code = begin_login
      other = OAuthStateCookie::Payload.new(state: payload.state, nonce: payload.nonce, code_verifier: "dummy-other-code-verifier-0123456789-abcdefghijklmnopqrstuvwxyz", purpose: "login", user_id: nil)

      result = complete(payload: other, code: code, state: payload.state)

      expect(result.status).to eq(:failed)
      expect(result.reason).to eq(:pkce_mismatch)
      expect(User.count).to eq(0)
    end

    it "nonce が違う: :failed（nonce_mismatch）" do
      _started, payload, code = begin_login
      other = OAuthStateCookie::Payload.new(state: payload.state, nonce: "dummy-other-nonce", code_verifier: payload.code_verifier, purpose: "login", user_id: nil)

      expect(complete(payload: other, code: code, state: payload.state).reason).to eq(:nonce_mismatch)
    end

    it "ゲートウェイの失敗の理由が、そのまま :failed の理由になる（トークンエンドポイントの拒否・ID トークンの検証の失敗 など）" do
      %i[ token_exchange_rejected token_endpoint_unreachable signature_invalid expired issuer_invalid jwks_unavailable ].each do |reason|
        oidc = instance_double(FakeGoogleOidc)
        allow(oidc).to receive(:authenticate).and_raise(GoogleOidc::AuthenticationFailed.new(reason))
        _started, payload, code = begin_login

        result = described_class.new(oidc: oidc, registry: registry).complete(payload: payload, code: code, state: payload.state, error: nil, redirect_uri: callback_uri, now: now)

        expect(result.status).to eq(:failed)
        expect(result.reason).to eq(reason)
        expect(result.user).to be_nil
      end
      expect(User.count).to eq(0)
    end

    it "想定外の例外は、握りつぶさずに伝える（:failed に丸めない）" do
      oidc = instance_double(FakeGoogleOidc)
      allow(oidc).to receive(:authenticate).and_raise(NoMethodError)
      _started, payload, code = begin_login

      expect { described_class.new(oidc: oidc, registry: registry).complete(payload: payload, code: code, state: payload.state, error: nil, redirect_uri: callback_uri, now: now) }
        .to raise_error(NoMethodError)
    end
  end

  describe "#complete（再登録の保留）" do
    it "削除から間もない sub: :registration_held。アカウントを作らない・user は nil" do
      registry.record_hold(google_sub: "dev-user-1", now: now - 1.hour)
      _started, payload, code = begin_login

      result = complete(payload: payload, code: code, state: payload.state)

      expect(result.status).to eq(:registration_held)
      expect(result.held?).to be(true)
      expect(result.user).to be_nil
      expect(result.reason).to be_nil
      expect(User.count).to eq(0)
    end

    it "保留が明けた（次の JST 03:00）あとは、:logged_in" do
      registry.record_hold(google_sub: "dev-user-1", now: Time.utc(2026, 10, 7, 4, 0, 0)) # JST 2026-10-07 13:00（利用日 2026-10-07）
      _started, payload, code = begin_login

      held = complete(payload: payload, code: code, state: payload.state, at: Time.utc(2026, 10, 7, 17, 59, 59)) # JST 02:59:59
      expect(held.status).to eq(:registration_held)

      fresh_code = fake.issue_code(sub: "dev-user-1", nonce: payload.nonce, code_challenge: s256_challenge(payload.code_verifier), redirect_uri: callback_uri, now: Time.utc(2026, 10, 7, 18, 0, 0))
      allowed = complete(payload: payload, code: fresh_code, state: payload.state, at: Time.utc(2026, 10, 7, 18, 0, 0)) # JST 03:00:00
      expect(allowed.status).to eq(:logged_in)
    end

    it "保留中の別の sub は、ログインできる" do
      registry.record_hold(google_sub: "dev-user-1", now: now - 1.hour)
      _started, payload, code = begin_login(sub: "dev-user-2")

      expect(complete(payload: payload, code: code, state: payload.state).status).to eq(:logged_in)
    end
  end

  describe "ログ" do
    it "失敗は理由の符号だけ、成功は内部のアカウント識別子だけ。state・コード・検証子・nonce・sub を出さない" do
      started, payload, code = begin_login

      failure_output = capture_logs { complete(payload: payload, code: code, state: "dummy-other-state") }
      success_output = capture_logs { complete(payload: payload, code: code, state: payload.state) }

      expect(failure_output).to include("[login]")
      expect(failure_output).to include("reason=state_mismatch")
      expect(success_output).to include("[login] completed user_id=#{User.first.id}")
      [ failure_output, success_output ].each do |output|
        [ started.state, started.nonce, started.code_verifier, code, "dev-user-1", "dummy-other-state" ].each do |secret_value|
          expect(output).not_to include(secret_value)
        end
      end
    end

    it "保留のログは、保留とだけ出す（sub・要約値を出さない）" do
      registry.record_hold(google_sub: "dev-user-1", now: now - 1.hour)
      _started, payload, code = begin_login

      output = capture_logs { complete(payload: payload, code: code, state: payload.state) }

      expect(output).to include("[login] registration held")
      expect(output).not_to include("dev-user-1")
      expect(output).not_to include(registry.digest("dev-user-1"))
    end
  end

  describe "引数の検査（呼び出しの誤りは ArgumentError）" do
    it "now が Time でない" do
      _started, payload, code = begin_login

      expect { complete(payload: payload, code: code, state: payload.state, at: "2026-10-08") }.to raise_error(ArgumentError, /now/)
    end

    it "redirect_uri が空" do
      _started, payload, code = begin_login

      expect { complete(payload: payload, code: code, state: payload.state, redirect: "") }.to raise_error(ArgumentError, /redirect_uri/)
    end

    it "保管した状態が、OAuthStateCookie::Payload でない・用途が login でない" do
      _started, payload, code = begin_login
      connect = OAuthStateCookie::Payload.new(state: payload.state, nonce: payload.nonce, code_verifier: payload.code_verifier, purpose: "connect", user_id: "7c9d1e2f-3a4b-4c5d-8e6f-0a1b2c3d4e5f")

      expect { complete(payload: { state: payload.state }, code: code, state: payload.state) }.to raise_error(ArgumentError, /payload/)
      expect { complete(payload: connect, code: code, state: payload.state) }.to raise_error(ArgumentError, /payload/)
    end
  end
end
