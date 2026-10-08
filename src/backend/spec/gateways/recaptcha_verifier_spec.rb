require "rails_helper"
require "support/external_http_support"
require "support/log_capture"

# bot 判定の検証 RecaptchaVerifier（issue #8。requirements.md 9.1・9.2・28.1。src/contracts/http-api.md 1.8）。
# siteverify の応答の success・action（一致）・hostname（公開オリジンのホストと一致）・challenge_ts（有効期限 2 分）・
# score（設定 bot_score_threshold 以上）を検証し、:pass・:fail・:indeterminate を返す（#5 の StartAdmission の bot_verdict）。
# 到達できない・タイムアウト・5xx・解釈できない応答は :indeterminate（受理側へ倒さない）。
# error-codes が空でない応答・無料枠の超過（fail open の success: true・score: 0.9・"Over free quota."）も :indeterminate。
# 実際の reCAPTCHA は呼ばない（WebMock）。
RSpec.describe RecaptchaVerifier do
  let(:endpoint) { ExternalServices.config.fetch(:recaptcha).fetch(:siteverify_endpoint) }
  let(:secret) { "dummy-recaptcha-secret-key" }
  let(:token) { "dummy-recaptcha-token-0123456789" }
  let(:now) { Time.utc(2026, 10, 8, 3, 0, 0) }
  let(:hostname) { "app.example.test" }
  let(:threshold_holder) { { value: 0.5 } }
  let(:settings_source) { -> { Settings.defaults.with(bot_score_threshold: threshold_holder.fetch(:value)) } }
  let(:verifier) { described_class.new(secret: secret, endpoint: endpoint, settings_source: settings_source) }

  # siteverify の応答（正常）。overrides の値が :omit のキーは、含めない
  def siteverify_body(overrides = {})
    body = {
      "success" => true,
      "score" => 0.9,
      "action" => "login",
      "challenge_ts" => (now - 5).utc.iso8601,
      "hostname" => hostname
    }.merge(overrides.transform_keys(&:to_s))
    body.reject { |_key, value| value == :omit }
  end

  def stub_siteverify(body: siteverify_body, status: 200, raw: nil)
    stub_request(:post, endpoint).to_return(status: status, body: raw || JSON.generate(body), headers: { "Content-Type" => "application/json" })
  end

  def assess(action: "login", host: hostname, at: now, token_value: token)
    verifier.assess(token: token_value, expected_action: action, hostname: host, now: at)
  end

  describe "要求の形" do
    it "siteverify へ POST する。送るのは secret と response（トークン）だけ。IP アドレス（remoteip）を送らない" do
      stub = stub_request(:post, endpoint)
             .with(body: { "secret" => secret, "response" => token }, headers: { "Content-Type" => "application/x-www-form-urlencoded" })
             .to_return(status: 200, body: JSON.generate(siteverify_body))

      expect(verifier.verify(token: token, expected_action: "login", hostname: hostname, now: now)).to eq(:pass)
      expect(stub).to have_been_requested.once
    end

    it "URL は設定ファイル（config/external_services.yml）のもの" do
      expect(endpoint).to eq("https://www.google.com/recaptcha/api/siteverify")
    end
  end

  describe "判定の行列（verify の戻り値）" do
    {
      "正常" => [ {}, :pass, :ok ],
      "success が false（error-codes なし）" => [ { "success" => false }, :fail, :verification_failed ],
      "行為名が違う" => [ { "action" => "broadcast_start" }, :fail, :action_mismatch ],
      "行為名が無い" => [ { "action" => :omit }, :fail, :action_mismatch ],
      "行為名の大文字・小文字が違う" => [ { "action" => "Login" }, :fail, :action_mismatch ],
      "ホストが違う" => [ { "hostname" => "evil.example.test" }, :fail, :hostname_mismatch ],
      "ホストが無い" => [ { "hostname" => :omit }, :fail, :hostname_mismatch ],
      "ホストの前方一致（サブドメインの付け足し）" => [ { "hostname" => "app.example.test.evil.example" }, :fail, :hostname_mismatch ],
      "ホストの大文字・小文字は区別しない" => [ { "hostname" => "APP.Example.Test" }, :pass, :ok ],
      "低スコア" => [ { "score" => 0.3 }, :fail, :low_score ],
      "スコアが閾値ちょうど（0.5）" => [ { "score" => 0.5 }, :pass, :ok ],
      "スコアが閾値の直前（0.49）" => [ { "score" => 0.49 }, :fail, :low_score ],
      "スコア 0.0" => [ { "score" => 0.0 }, :fail, :low_score ],
      "スコア 1.0" => [ { "score" => 1.0 }, :pass, :ok ],
      "スコアが整数（1）" => [ { "score" => 1 }, :pass, :ok ]
    }.each do |label, (overrides, verdict, reason)|
      it "#{label}: #{verdict}（#{reason}）" do
        stub_siteverify(body: siteverify_body(overrides))

        result = assess

        expect(result.verdict).to eq(verdict)
        expect(result.reason).to eq(reason)
        expect(verifier.verify(token: token, expected_action: "login", hostname: hostname, now: now)).to eq(verdict)
      end
    end

    it "行為名は、3 つとも検証できる（login・youtube_connect・broadcast_start）" do
      %w[ login youtube_connect broadcast_start ].each do |action|
        stub_siteverify(body: siteverify_body("action" => action))

        expect(assess(action: action).verdict).to eq(:pass), action
      end
    end
  end

  describe "トークンの有効期限（challenge_ts から 2 分）" do
    {
      "5 秒前" => [ 5, :pass, :ok ],
      "119 秒前" => [ 119, :pass, :ok ],
      "ちょうど 120 秒前（2 分）" => [ 120, :pass, :ok ],
      "121 秒前" => [ 121, :fail, :token_expired ],
      "1 時間前" => [ 3600, :fail, :token_expired ],
      "0 秒前（同時刻）" => [ 0, :pass, :ok ],
      "5 秒先（時計のずれの範囲）" => [ -5, :pass, :ok ],
      "30 秒先（時計のずれの上限）" => [ -30, :pass, :ok ],
      "31 秒先（時計のずれを超える）" => [ -31, :indeterminate, :challenge_ts_in_future ]
    }.each do |label, (age_seconds, verdict, reason)|
      it "#{label}: #{verdict}" do
        stub_siteverify(body: siteverify_body("challenge_ts" => (now - age_seconds).utc.iso8601))

        result = assess

        expect([ result.verdict, result.reason ]).to eq([ verdict, reason ])
      end
    end

    it "有効期限は 2 分（契約の注記どおり）" do
      expect(described_class::TOKEN_MAX_AGE_SECONDS).to eq(120)
    end

    it "challenge_ts は、タイムゾーンつきの表記でもよい（+09:00）" do
      stub_siteverify(body: siteverify_body("challenge_ts" => (now - 10).getlocal("+09:00").iso8601))

      expect(assess.verdict).to eq(:pass)
    end

    it "判定の時刻は、引数の now（実時計を読まない）" do
      stub_siteverify(body: siteverify_body("challenge_ts" => (now - 5).utc.iso8601))

      expect(assess(at: now + 3600).reason).to eq(:token_expired)
      expect(assess(at: now).reason).to eq(:ok)
    end
  end

  describe "解釈できない応答・判定できない応答は :indeterminate（受理側へ倒さない）" do
    {
      "error-codes が空でない（success: false）" => { "success" => false, "error-codes" => [ "invalid-input-response" ] },
      "error-codes が空でない（success: true でも）" => { "error-codes" => [ "bad-request" ] },
      "error-codes: 秘密鍵の誤り（サーバー側の設定の不備）" => { "success" => false, "error-codes" => [ "invalid-input-secret" ] },
      "error-codes: 重複・期限切れ（timeout-or-duplicate）" => { "success" => false, "error-codes" => [ "timeout-or-duplicate" ] },
      "error-codes が配列でない" => { "error-codes" => "bad-request" },
      "error-codes に文字列でない値" => { "error-codes" => [ 1 ] },
      "success が無い" => { "success" => :omit },
      "success が真偽値でない（文字列 true）" => { "success" => "true" },
      "success が null" => { "success" => nil },
      "score が無い" => { "score" => :omit },
      "score が文字列" => { "score" => "0.9" },
      "score が null" => { "score" => nil },
      "score が範囲外（1.5）" => { "score" => 1.5 },
      "score が範囲外（-0.1）" => { "score" => -0.1 },
      "challenge_ts が無い" => { "challenge_ts" => :omit },
      "challenge_ts が日時として読めない" => { "challenge_ts" => "yesterday" },
      "challenge_ts が文字列でない" => { "challenge_ts" => 1_760_000_000 }
    }.each do |label, overrides|
      it "#{label}" do
        stub_siteverify(body: siteverify_body(overrides))

        expect(assess.verdict).to eq(:indeterminate)
        expect(verifier.verify(token: token, expected_action: "login", hostname: hostname, now: now)).to eq(:indeterminate)
      end
    end

    it "error-codes が空の配列なら、ないものとして扱う（正常）" do
      stub_siteverify(body: siteverify_body("error-codes" => []))

      expect(assess.verdict).to eq(:pass)
    end

    it "無料枠の超過（fail open: success: true・score: 0.9・\"Over free quota.\"）は、success: true でも :indeterminate" do
      [
        siteverify_body("error-codes" => [ "Over free quota." ]),
        siteverify_body("message" => "Over free quota."),
        siteverify_body("detail" => { "note" => "over  FREE quota" }),
        siteverify_body("hostname" => hostname, "list" => [ "ok", "Over free quota." ])
      ].each do |body|
        stub_siteverify(body: body)

        result = assess

        expect(result.verdict).to eq(:indeterminate), body.inspect
        expect(result.reason).to be_in(%i[ quota_exceeded error_codes ])
      end
    end

    it "無料枠の超過の応答（スコア 0.9 で高得点）を、:pass にしない" do
      stub_siteverify(body: { "success" => true, "score" => 0.9, "action" => "login", "challenge_ts" => (now - 1).utc.iso8601, "hostname" => hostname, "error-codes" => [], "message" => "Over free quota." })

      expect(verifier.verify(token: token, expected_action: "login", hostname: hostname, now: now)).not_to eq(:pass)
    end

    [
      [ "JSON でない本文", "not json" ],
      [ "空の本文", "" ],
      [ "HTML の本文", "<html>error</html>" ],
      [ "JSON の配列", "[]" ],
      [ "JSON の文字列", "\"ok\"" ],
      [ "JSON の null", "null" ],
      [ "壊れた JSON", "{\"success\":" ]
    ].each do |label, raw|
      it "#{label}: :indeterminate（invalid_response）" do
        stub_siteverify(raw: raw)

        result = assess

        expect(result.verdict).to eq(:indeterminate)
        expect(result.reason).to eq(:invalid_response)
      end
    end
  end

  describe "到達できない・サーバーの失敗は :indeterminate" do
    {
      "接続のタイムアウト" => ->(stub) { stub.to_timeout },
      "読み取りのタイムアウト" => ->(stub) { stub.to_raise(Net::ReadTimeout) },
      "接続の拒否" => ->(stub) { stub.to_raise(Errno::ECONNREFUSED) },
      "名前が引けない" => ->(stub) { stub.to_raise(SocketError) },
      "TLS の失敗" => ->(stub) { stub.to_raise(OpenSSL::SSL::SSLError) }
    }.each do |label, arrange|
      it "#{label}: :indeterminate（unreachable）" do
        arrange.call(stub_request(:post, endpoint))

        result = assess

        expect(result.verdict).to eq(:indeterminate)
        expect(result.reason).to eq(:unreachable)
      end
    end

    [ 500, 502, 503, 504, 429, 404, 403, 400, 302 ].each do |status|
      it "HTTP #{status}: :indeterminate（http_status）。本文が正常な形でも、通さない" do
        stub_siteverify(status: status, body: siteverify_body)

        result = assess

        expect(result.verdict).to eq(:indeterminate)
        expect(result.reason).to eq(:http_status)
      end
    end

    it "応答が大きすぎる: :indeterminate（unreachable）" do
      stub_request(:post, endpoint).to_return(status: 200, body: "x" * (ExternalHttp::MAX_BODY_BYTES + 1))

      expect(assess.verdict).to eq(:indeterminate)
    end

    it "リダイレクトを追わない（Location へ通信しない）" do
      stub_request(:post, endpoint).to_return(status: 302, headers: { "Location" => "https://evil.example.test/verify" })

      expect(assess.verdict).to eq(:indeterminate)
      expect(a_request(:any, "https://evil.example.test/verify")).not_to have_been_made
    end
  end

  describe "トークンの扱い（欠落・不正は :fail。外部サービスを呼ばない）" do
    [ nil, "", "   ", "\n", 123, [ "a" ], { "a" => 1 }, :symbol ].each do |bad|
      it "トークン #{bad.inspect}: :fail（token_missing）。通信しない" do
        result = assess(token_value: bad)

        expect(result.verdict).to eq(:fail)
        expect(result.reason).to eq(:token_missing)
        expect(a_request(:any, endpoint)).not_to have_been_made
      end
    end

    it "長すぎるトークン（#{RecaptchaVerifier::TOKEN_MAX_LENGTH + 1} 文字）: :fail（token_too_long）。通信しない" do
      result = assess(token_value: "a" * (RecaptchaVerifier::TOKEN_MAX_LENGTH + 1))

      expect(result.verdict).to eq(:fail)
      expect(result.reason).to eq(:token_too_long)
      expect(a_request(:any, endpoint)).not_to have_been_made
    end

    it "上限ちょうどのトークンは、検証へ進む" do
      stub_siteverify

      expect(assess(token_value: "a" * RecaptchaVerifier::TOKEN_MAX_LENGTH).verdict).to eq(:pass)
    end

    it "トークンは、そのまま（前後の空白も含めて）送る。符号化して送る" do
      raw_token = "tok en+/=&?"
      stub = stub_request(:post, endpoint).with(body: { "secret" => secret, "response" => raw_token }).to_return(status: 200, body: JSON.generate(siteverify_body))

      expect(assess(token_value: raw_token).verdict).to eq(:pass)
      expect(stub).to have_been_requested.once
    end
  end

  describe "閾値（設定 bot_score_threshold）" do
    it "判定のたびに、現在の設定を読む（管理画面の変更を、次の判定から反映する）" do
      stub_siteverify(body: siteverify_body("score" => 0.6))

      expect(assess.verdict).to eq(:pass)
      threshold_holder[:value] = 0.7
      expect(assess.verdict).to eq(:fail)
      threshold_holder[:value] = 0.0
      expect(assess.verdict).to eq(:pass)
      threshold_holder[:value] = 1.0
      expect(assess.verdict).to eq(:fail)
    end

    it "設定を読めない（例外）ときは、例外をそのまま伝える。:indeterminate に丸めない・既定値で続行しない" do
      broken = Class.new(StandardError)
      failing = described_class.new(secret: secret, endpoint: endpoint, settings_source: -> { raise broken })
      stub_siteverify

      expect { failing.verify(token: token, expected_action: "login", hostname: hostname, now: now) }.to raise_error(broken)
    end

    it "設定が Settings でなければ、ArgumentError" do
      wrong = described_class.new(secret: secret, endpoint: endpoint, settings_source: -> { { bot_score_threshold: 0.5 } })
      stub_siteverify

      expect { wrong.verify(token: token, expected_action: "login", hostname: hostname, now: now) }.to raise_error(ArgumentError, /Settings/)
    end

    it "通信が先: 検証サービスに届かないときは、設定を読まない" do
      calls = []
      source = lambda do
        calls << :read
        Settings.defaults
      end
      counting = described_class.new(secret: secret, endpoint: endpoint, settings_source: source)
      stub_request(:post, endpoint).to_timeout

      counting.verify(token: token, expected_action: "login", hostname: hostname, now: now)

      expect(calls).to be_empty
    end
  end

  describe "引数の検査（呼び出しの誤りは ArgumentError）" do
    it "未知の行為名" do
      [ "signup", "", nil, :login, "LOGIN" ].each do |action|
        expect { verifier.verify(token: token, expected_action: action, hostname: hostname, now: now) }.to raise_error(ArgumentError, /expected_action/)
      end
    end

    it "ホストが空・文字列でない" do
      [ "", "  ", nil, :host, 1 ].each do |host|
        expect { verifier.verify(token: token, expected_action: "login", hostname: host, now: now) }.to raise_error(ArgumentError, /hostname/)
      end
    end

    it "now が Time でない" do
      [ nil, "2026-10-08", 1_760_000_000, Date.new(2026, 10, 8) ].each do |bad|
        expect { verifier.verify(token: token, expected_action: "login", hostname: hostname, now: bad) }.to raise_error(ArgumentError, /now/)
      end
    end

    it "検査の誤りでは、通信しない" do
      expect { verifier.verify(token: token, expected_action: "signup", hostname: hostname, now: now) }.to raise_error(ArgumentError)
      expect(a_request(:any, endpoint)).not_to have_been_made
    end

    it "秘密鍵・URL・設定の取得元の誤り（構築時）" do
      [ nil, "", "  ", 1 ].each do |bad|
        expect { described_class.new(secret: bad, endpoint: endpoint, settings_source: settings_source) }.to raise_error(ArgumentError, /secret/)
      end
      [ nil, "", "http://www.google.com/recaptcha/api/siteverify", 1 ].each do |bad|
        expect { described_class.new(secret: secret, endpoint: bad, settings_source: settings_source) }.to raise_error(ArgumentError, /endpoint/)
      end
      [ nil, "source", 1 ].each do |bad|
        expect { described_class.new(secret: secret, endpoint: endpoint, settings_source: bad) }.to raise_error(ArgumentError, /settings_source/)
      end
    end
  end

  describe "秘密値・トークンを出さない" do
    it "inspect に、秘密鍵を出さない" do
      expect(verifier.inspect).not_to include(secret)
    end

    it "ログに、判定・理由・行為名・スコア・閾値は出すが、トークン・秘密鍵・ホストの値は出さない" do
      stub_siteverify(body: siteverify_body("score" => 0.3))

      output = capture_logs { assess }

      expect(output).to include("[recaptcha]")
      expect(output).to include("verdict=fail")
      expect(output).to include("reason=low_score")
      expect(output).to include("action=login")
      expect(output).to include("score=0.3")
      expect(output).to include("threshold=0.5")
      expect(output).not_to include(token)
      expect(output).not_to include(secret)
    end

    it "通信の失敗のログにも、トークン・秘密鍵を出さない" do
      stub_request(:post, endpoint).to_raise(Errno::ECONNREFUSED)

      output = capture_logs { assess }

      expect(output).to include("verdict=indeterminate")
      expect(output).to include("reason=unreachable")
      expect(output).not_to include(token)
      expect(output).not_to include(secret)
    end

    it "応答の本文（error-codes の自由な文字列）を、ログへ出さない" do
      stub_siteverify(body: siteverify_body("success" => false, "error-codes" => [ "dummy-leaky-error-code-with-token-#{token}" ]))

      output = capture_logs { assess }

      expect(output).to include("reason=error_codes")
      expect(output).not_to include("dummy-leaky-error-code")
      expect(output).not_to include(token)
    end
  end
end
