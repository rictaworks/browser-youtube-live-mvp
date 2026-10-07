require "rails_helper"

# bl_oauth（issue #7。requirements.md 7.1・28.1。src/contracts/http-api.md 1.3）。
# 認可の途中の状態（state・nonce・PKCE の検証子・用途 login|connect・connect のときの内部のアカウント識別子）を、
# 暗号化した短命の Cookie（Max-Age=600）で持つ。鍵は SESSION_SECRET から導出する。改ざん・期限切れ・用途違いは無効。
RSpec.describe OAuthStateCookie do
  let(:secret) { "dummy-session-secret-for-oauth-cookie-spec-0123456789" }
  let(:cookie) { described_class.new(secret: secret) }
  let(:now) { Time.utc(2026, 10, 7, 4, 30, 0) }
  let(:user_id) { "7c9d1e2f-3a4b-4c5d-8e6f-0a1b2c3d4e5f" }
  let(:login_attributes) do
    { state: "dummy-state-0123456789", nonce: "dummy-nonce-0123456789", code_verifier: "dummy-code-verifier-0123456789-abcdefghijklmnop", purpose: "login" }
  end
  let(:connect_attributes) { login_attributes.merge(purpose: "connect", user_id: user_id) }

  it "名前は bl_oauth、有効期間は 600 秒（Max-Age）" do
    expect(described_class::NAME).to eq("bl_oauth")
    expect(described_class::MAX_AGE).to eq(600)
    expect(described_class::PURPOSES).to eq(%w[ login connect ])
  end

  describe "#seal と #open（往復）" do
    it "login の状態を、暗号化して、元に戻せる（アカウント識別子は無い）" do
      sealed = cookie.seal(**login_attributes, now: now)
      payload = cookie.open(sealed, expected_purpose: "login", now: now)

      expect(payload).to have_attributes(
        state: "dummy-state-0123456789", nonce: "dummy-nonce-0123456789",
        code_verifier: "dummy-code-verifier-0123456789-abcdefghijklmnop", purpose: "login", user_id: nil
      )
    end

    it "connect の状態を、内部のアカウント識別子つきで、元に戻せる" do
      sealed = cookie.seal(**connect_attributes, now: now)
      payload = cookie.open(sealed, expected_purpose: "connect", now: now)

      expect(payload).to have_attributes(purpose: "connect", user_id: user_id, state: "dummy-state-0123456789")
    end

    it "別のインスタンス（同じ秘密値）でも開ける（プロセスの再起動・複数のプロセスで、鍵が同じ）" do
      sealed = cookie.seal(**login_attributes, now: now)

      expect(described_class.new(secret: secret).open(sealed, expected_purpose: "login", now: now).state).to eq("dummy-state-0123456789")
    end

    it "暗号化されている（state・nonce・検証子・アカウント識別子が、平文で見えない）" do
      sealed = cookie.seal(**connect_attributes, now: now)

      [ "dummy-state-0123456789", "dummy-nonce-0123456789", "dummy-code-verifier", user_id, "connect", "login" ].each do |plain|
        expect(sealed).not_to include(plain)
      end
    end

    it "Cookie の値として安全な文字だけ（URL 安全な base64）で、長さに上限がある（Cookie は 4096 バイトまで）" do
      sealed = cookie.seal(**connect_attributes, now: now)

      expect(sealed).to match(/\A[A-Za-z0-9_=-]+\z/)
      expect(sealed.bytesize).to be < 1500
    end

    it "同じ内容でも、封じるたびに別の値（暗号化のたびに、新しい初期化ベクトル）" do
      expect(cookie.seal(**login_attributes, now: now)).not_to eq(cookie.seal(**login_attributes, now: now))
    end
  end

  describe "#open（無効なもの）" do
    let(:sealed) { cookie.seal(**login_attributes, now: now) }

    it "改ざん（1 文字の書き換え）は無効" do
      tampered = sealed.dup
      tampered[10] = tampered[10] == "A" ? "B" : "A"

      expect { cookie.open(tampered, expected_purpose: "login", now: now) }.to raise_error(OAuthStateCookie::InvalidCookie)
    end

    it "改ざん（末尾の切り詰め）は無効" do
      expect { cookie.open(sealed[0..-5], expected_purpose: "login", now: now) }.to raise_error(OAuthStateCookie::InvalidCookie)
    end

    it "別の秘密値で封じたものは無効" do
      other = described_class.new(secret: "#{secret}x").seal(**login_attributes, now: now)

      expect { cookie.open(other, expected_purpose: "login", now: now) }.to raise_error(OAuthStateCookie::InvalidCookie)
    end

    it "用途違いは無効（login の Cookie を connect のコールバックへ、connect の Cookie を login のコールバックへ渡せない）" do
      expect { cookie.open(sealed, expected_purpose: "connect", now: now) }.to raise_error(OAuthStateCookie::InvalidCookie)

      connect_sealed = cookie.seal(**connect_attributes, now: now)
      expect { cookie.open(connect_sealed, expected_purpose: "login", now: now) }.to raise_error(OAuthStateCookie::InvalidCookie)
    end

    {
      "期限の 1 秒前" => [ 599, true ],
      "期限の瞬間（封じてから 600 秒）" => [ 600, false ],
      "期限の 1 秒後" => [ 601, false ],
      "1 時間後" => [ 3600, false ],
      "封じた時刻より前（時計の逆行）" => [ -1, true ]
    }.each do |label, (elapsed, valid)|
      it "#{label}は、#{valid ? '有効' : '無効（期限切れ）'}" do
        if valid
          expect(cookie.open(sealed, expected_purpose: "login", now: now + elapsed).state).to eq("dummy-state-0123456789")
        else
          expect { cookie.open(sealed, expected_purpose: "login", now: now + elapsed) }.to raise_error(OAuthStateCookie::InvalidCookie)
        end
      end
    end

    [ nil, "", " ", "abc", "a" * 5000, "\xFF\xFE", 123, [ "x" ], {} ].each do |garbage|
      it "でたらめな値 #{garbage.inspect[0, 20]} は、InvalidCookie だけを起こす（他の例外を漏らさない）" do
        expect { cookie.open(garbage, expected_purpose: "login", now: now) }.to raise_error(OAuthStateCookie::InvalidCookie)
      end
    end

    it "期待する用途が、login・connect 以外なら、ArgumentError（呼び出しの誤り）" do
      expect { cookie.open(sealed, expected_purpose: "other", now: now) }.to raise_error(ArgumentError)
      expect { cookie.open(sealed, expected_purpose: nil, now: now) }.to raise_error(ArgumentError)
    end

    it "InvalidCookie のメッセージに、Cookie の値・内容を含めない" do
      expect { cookie.open("dummy-garbage-must-not-appear", expected_purpose: "login", now: now) }
        .to raise_error(OAuthStateCookie::InvalidCookie) { |error| expect(error.message).not_to include("dummy-garbage-must-not-appear") }
    end
  end

  describe "#seal（入力の検査）" do
    it "用途が login・connect 以外なら、例外にする" do
      [ "other", nil, :login, "" ].each do |purpose|
        expect { cookie.seal(**login_attributes, purpose: purpose, now: now) }.to raise_error(ArgumentError)
      end
    end

    it "login には、アカウント識別子を付けられない（まだ、アカウントが無い）" do
      expect { cookie.seal(**login_attributes, user_id: user_id, now: now) }.to raise_error(ArgumentError)
    end

    it "connect には、アカウント識別子（UUID）が要る" do
      expect { cookie.seal(**connect_attributes, user_id: nil, now: now) }.to raise_error(ArgumentError)
      expect { cookie.seal(**connect_attributes, user_id: "not-a-uuid", now: now) }.to raise_error(ArgumentError)
    end

    %i[ state nonce code_verifier ].each do |key|
      [ nil, "", "  ", 123 ].each do |value|
        it "#{key} が #{value.inspect} なら、例外にする" do
          expect { cookie.seal(**login_attributes, key => value, now: now) }.to raise_error(ArgumentError)
        end
      end
    end

    it "now が時刻でなければ、例外にする" do
      expect { cookie.seal(**login_attributes, now: nil) }.to raise_error(ArgumentError)
    end

    it "余分な属性（氏名・メールアドレスなど）は、受け付けない" do
      expect { cookie.seal(**login_attributes, email: "dummy@example.test", now: now) }.to raise_error(ArgumentError)
    end
  end

  describe ".new" do
    [ nil, "", "  " ].each do |value|
      it "秘密値 #{value.inspect} は、例外にする" do
        expect { described_class.new(secret: value) }.to raise_error(ArgumentError)
      end
    end

    it "鍵は、SESSION_SECRET から導出する（DerivedKeys の oauth_cookie。CSRF の鍵とは別）" do
      expect(DerivedKeys.new(secret: secret).derive("oauth_cookie")).not_to eq(DerivedKeys.new(secret: secret).derive("csrf"))
    end
  end

  describe ".attributes（Set-Cookie の属性）" do
    let(:development) { AppEnvironment.new("development") }
    let(:production) { AppEnvironment.new("production") }

    it "開発・テスト（http）: HttpOnly・SameSite=Lax・Path=/・Max-Age=600。Secure は付けない" do
      expect(described_class.attributes("sealed-value", environment: development)).to eq(
        value: "sealed-value", httponly: true, same_site: :lax, path: "/", max_age: 600, secure: false
      )
    end

    it "本番: Secure を付ける" do
      expect(described_class.attributes("sealed-value", environment: production)).to include(secure: true, max_age: 600)
    end

    it "失効させる Cookie の属性は、発行のときと同じ Path・HttpOnly・SameSite（Max-Age は付けない）" do
      expect(described_class.expiry_attributes(environment: production)).to eq(httponly: true, same_site: :lax, path: "/", secure: true)
    end
  end
end
