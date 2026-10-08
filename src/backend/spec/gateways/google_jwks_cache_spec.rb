require "rails_helper"
require "support/external_http_support"
require "support/google_oidc_support"
require "support/log_capture"

# Google の公開鍵（JWKS）のキャッシュ GoogleJwksCache（issue #8）。
# 取得した JWKS を、有効期間のあいだ使い回す。kid が見つからないとき（鍵の入れ替え）は、最短の間隔を空けて、再取得する。
# 取得できないときは、古い鍵で続行せず、GoogleOidc::AuthenticationFailed（jwks_unavailable）。時刻は引数で受け取る。
RSpec.describe GoogleJwksCache do
  include GoogleOidcSupport

  let(:jwks_uri) { google_config.fetch(:jwks_uri) }
  let(:now) { Time.utc(2026, 10, 8, 3, 0, 0) }
  let(:ttl) { 3600 }
  let(:min_refetch) { 60 }
  let(:cache) { described_class.new(http: ExternalHttp.new, jwks_uri: jwks_uri, ttl_seconds: ttl, min_refetch_seconds: min_refetch) }

  def fetches
    a_request(:get, jwks_uri)
  end

  def unavailable!(&block)
    expect(&block).to raise_error(GoogleOidc::AuthenticationFailed) { |error| expect(error.reason).to eq(:jwks_unavailable) }
  end

  it "設定の値: 有効期間 1 時間・再取得の最短の間隔 60 秒（config/external_services.yml）" do
    expect(google_config.fetch(:jwks_cache_seconds)).to eq(3600)
    expect(google_config.fetch(:jwks_min_refetch_seconds)).to eq(60)
  end

  describe "取得とキャッシュ" do
    it "最初の呼び出しで取得し、JWKS（keys の配列を持つ Hash）を返す" do
      stub_jwks

      document = cache.keys(now: now)

      expect(fetches).to have_been_made.once
      expect(document.fetch("keys").map { |key| key.fetch("kid") }).to eq([ kid ])
    end

    it "有効期間のあいだは、再取得しない" do
      stub_jwks

      cache.keys(now: now)
      cache.keys(now: now + 1)
      cache.keys(now: now + ttl - 1)

      expect(fetches).to have_been_made.once
    end

    it "有効期間が過ぎたら（ちょうどの時刻から）、再取得する" do
      stub_jwks

      cache.keys(now: now)
      cache.keys(now: now + ttl)

      expect(fetches).to have_been_made.twice
    end

    it "再取得した鍵が、新しい鍵になる" do
      stub_jwks(jwks_document({ kid => signing_key }))
      cache.keys(now: now)
      stub_jwks(jwks_document({ other_kid => other_key }))

      document = cache.keys(now: now + ttl)

      expect(document.fetch("keys").map { |key| key.fetch("kid") }).to eq([ other_kid ])
    end

    it "時刻が戻っても（now が取得時刻より前）、キャッシュは有効なまま" do
      stub_jwks
      cache.keys(now: now)

      cache.keys(now: now - 10)

      expect(fetches).to have_been_made.once
    end

    it "返した JWKS を書き換えても、キャッシュは変わらない（凍結されている）" do
      stub_jwks

      document = cache.keys(now: now)

      expect(document).to be_frozen
      expect(document.fetch("keys")).to be_frozen
    end
  end

  describe "kid が見つからないときの再取得（invalidate: true）" do
    it "最短の間隔（60 秒）が過ぎていれば、再取得する" do
      stub_jwks
      cache.keys(now: now)

      cache.keys(now: now + min_refetch, invalidate: true)

      expect(fetches).to have_been_made.twice
    end

    it "最短の間隔の前は、再取得しない（キャッシュを返す）。同じ要求を繰り返しても、取得先を叩き続けない" do
      stub_jwks
      cache.keys(now: now)

      3.times { |i| cache.keys(now: now + min_refetch - 1 - i, invalidate: true) }

      expect(fetches).to have_been_made.once
    end

    it "キャッシュが空なら、invalidate でも 1 回だけ取得する" do
      stub_jwks

      cache.keys(now: now, invalidate: true)

      expect(fetches).to have_been_made.once
    end

    it "再取得したあとは、また最短の間隔を空ける" do
      stub_jwks
      cache.keys(now: now)
      cache.keys(now: now + 100, invalidate: true)
      cache.keys(now: now + 130, invalidate: true)

      expect(fetches).to have_been_made.twice
    end
  end

  describe "取得できないとき（古い鍵で続行しない）" do
    it "最初の取得の失敗: jwks_unavailable" do
      stub_request(:get, jwks_uri).to_raise(Errno::ECONNREFUSED)

      unavailable! { cache.keys(now: now) }
    end

    {
      "タイムアウト" => ->(stub) { stub.to_timeout },
      "TLS の失敗" => ->(stub) { stub.to_raise(OpenSSL::SSL::SSLError) },
      "名前が引けない" => ->(stub) { stub.to_raise(SocketError) }
    }.each do |label, arrange|
      it "#{label}: jwks_unavailable" do
        arrange.call(stub_request(:get, jwks_uri))

        unavailable! { cache.keys(now: now) }
      end
    end

    [ 500, 503, 429, 404, 403, 302 ].each do |status|
      it "HTTP #{status}: jwks_unavailable" do
        stub_jwks(status: status)

        unavailable! { cache.keys(now: now) }
      end
    end

    [
      [ "JSON でない本文", "not json" ],
      [ "JSON の配列", "[]" ],
      [ "keys が無い", "{}" ],
      [ "keys が配列でない", "{\"keys\":\"x\"}" ],
      [ "keys が空", "{\"keys\":[]}" ],
      [ "keys の要素がオブジェクトでない", "{\"keys\":[1]}" ]
    ].each do |label, body|
      it "#{label}: jwks_unavailable" do
        stub_request(:get, jwks_uri).to_return(status: 200, body: body)

        unavailable! { cache.keys(now: now) }
      end
    end

    it "有効期間が過ぎたあとの再取得の失敗: 古い鍵を返さずに失敗する" do
      stub_jwks
      cache.keys(now: now)
      stub_request(:get, jwks_uri).to_raise(Errno::ECONNREFUSED)

      unavailable! { cache.keys(now: now + ttl) }
    end

    it "invalidate の再取得の失敗: 失敗する（古い鍵で続行しない）" do
      stub_jwks
      cache.keys(now: now)
      stub_request(:get, jwks_uri).to_timeout

      unavailable! { cache.keys(now: now + min_refetch, invalidate: true) }
    end

    it "失敗した取得は、キャッシュを壊さない（有効期間内なら、前の鍵を使い続けられる）" do
      stub_jwks
      cache.keys(now: now)
      stub_request(:get, jwks_uri).to_timeout

      expect(cache.keys(now: now + 10).fetch("keys").map { |key| key.fetch("kid") }).to eq([ kid ])
    end

    it "失敗のあとの次の呼び出しは、また取得を試みる" do
      stub_request(:get, jwks_uri).to_timeout
      unavailable! { cache.keys(now: now) }
      stub_jwks

      expect(cache.keys(now: now + 1).fetch("keys")).not_to be_empty
    end
  end

  describe "並行" do
    it "複数のスレッドが同時に呼んでも、取得は 1 回" do
      stub_jwks

      results = Array.new(8) { Thread.new { cache.keys(now: now) } }.map(&:value)

      expect(fetches).to have_been_made.once
      expect(results.map { |document| document.fetch("keys").size }).to all(eq(1))
    end
  end

  describe "引数の検査" do
    it "now は Time" do
      stub_jwks

      [ nil, "2026-10-08", 1_760_000_000 ].each do |bad|
        expect { cache.keys(now: bad) }.to raise_error(ArgumentError, /now/)
      end
    end

    it "構築時: URL は https、期間は正の整数" do
      [ nil, "http://example.test/certs", "", 1 ].each do |bad|
        expect { described_class.new(http: ExternalHttp.new, jwks_uri: bad, ttl_seconds: ttl, min_refetch_seconds: min_refetch) }.to raise_error(ArgumentError, /jwks_uri/)
      end
      [ 0, -1, nil, 1.5, "3600" ].each do |bad|
        expect { described_class.new(http: ExternalHttp.new, jwks_uri: jwks_uri, ttl_seconds: bad, min_refetch_seconds: min_refetch) }.to raise_error(ArgumentError, /ttl_seconds/)
        expect { described_class.new(http: ExternalHttp.new, jwks_uri: jwks_uri, ttl_seconds: ttl, min_refetch_seconds: bad) }.to raise_error(ArgumentError, /min_refetch_seconds/)
      end
    end
  end

  describe "ログ" do
    it "取得の失敗を、符号だけで出す。JWKS の本文は出さない" do
      stub_request(:get, jwks_uri).to_return(status: 200, body: "{\"keys\":[],\"note\":\"dummy-body-must-not-appear\"}")

      output = capture_logs { unavailable! { cache.keys(now: now) } }

      expect(output).to include("[google_jwks]")
      expect(output).to include("reason=")
      expect(output).not_to include("dummy-body-must-not-appear")
    end
  end
end
