require "rails_helper"

# 取り込み先の検証（issue #10。requirements.md 6.1・10.1・28.1）。YouTube の取り込み先を中継へ返す前に、アプリケーションが検証する
# （中継も、送出の前に、もう一度検証する。src/relay/internal/rtmps/destination.go）。
#   - RTMPS（rtmps://）であること。平文の RTMP は拒否する
#   - ホストが YouTube の取り込み口（設定ファイルの許可ホスト。契約 rtmps_ingest）であること。IP アドレス・別のホスト・サブドメインの詐称は拒否
#   - ポートが 443 であること（省略・0443 も拒否）
#   - ユーザー情報・クエリ（?backup=1）・フラグメントを持たないこと
#   - パスが 1 つのアプリ名（live2 など）だけであること。配信キーを URL に混ぜた形は拒否
# 開発・テストの環境でのみ、疑似の取り込み口（契約 dev_ingest：fake-ingest・1935）を許す。production では許さない。
# 違反は IngestDestination::Invalid（符号だけ。URL の内容を含めない）。
RSpec.describe IngestDestination do
  let(:development) { AppEnvironment.new("development") }
  let(:test_environment) { AppEnvironment.new("test") }
  let(:production) { AppEnvironment.new("production") }

  def validate(url, environment: production)
    described_class.validate!(url, environment: environment)
  end

  def code_of(url, environment: production)
    validate(url, environment: environment)
    nil
  rescue described_class::Invalid => e
    e.code
  end

  describe ".validate!（許可する取り込み先）" do
    %w[
      rtmps://a.rtmps.youtube.com:443/live2
      rtmps://b.rtmps.youtube.com:443/live2
    ].each do |url|
      it "#{url} は許可する（契約 rtmps_ingest のホスト・ポート 443）" do
        expect(validate(url)).to eq(url)
      end
    end

    it "検証した URL を、凍結した複製で返す（呼び出し側の文字列を変えない）" do
      url = +"rtmps://a.rtmps.youtube.com:443/live2"

      result = validate(url)

      expect(result).to be_frozen
      expect(result).not_to equal(url)
      expect(url).not_to be_frozen
    end

    it "アプリ名は、英数字・アンダースコア・ハイフンの 1〜64 文字" do
      expect(code_of("rtmps://a.rtmps.youtube.com:443/live2")).to be_nil
      expect(code_of("rtmps://a.rtmps.youtube.com:443/Live-2_x")).to be_nil
      expect(code_of("rtmps://a.rtmps.youtube.com:443/#{'a' * 64}")).to be_nil
    end
  end

  describe ".validate!（拒否する取り込み先。違反の符号）" do
    {
      "平文の RTMP（ホストが許可リストにあっても）" => [ "rtmp://a.rtmps.youtube.com:443/live2", :scheme_not_allowed ],
      "YouTube の平文の取り込み口（ingestionAddress の形）" => [ "rtmp://a.rtmp.youtube.com/live2", :scheme_not_allowed ],
      "http" => [ "http://a.rtmps.youtube.com:443/live2", :scheme_not_allowed ],
      "https" => [ "https://a.rtmps.youtube.com:443/live2", :scheme_not_allowed ],
      "スキームの大文字（厳密に rtmps のみ）" => [ "RTMPS://a.rtmps.youtube.com:443/live2", :scheme_not_allowed ],
      "スキームが無い" => [ "a.rtmps.youtube.com:443/live2", :scheme_not_allowed ],
      "スラッシュが 1 つ足りない" => [ "rtmps:/a.rtmps.youtube.com:443/live2", :scheme_not_allowed ],
      "ユーザー情報" => [ "rtmps://user:pass@a.rtmps.youtube.com:443/live2", :userinfo_not_allowed ],
      "ユーザー情報のふりをしたホスト（@ の後ろが別ホスト）" => [ "rtmps://a.rtmps.youtube.com:443@evil.example/live2", :userinfo_not_allowed ],
      "バックアップの印（?backup=1）" => [ "rtmps://b.rtmps.youtube.com:443/live2?backup=1", :query_not_allowed ],
      "空のクエリ" => [ "rtmps://a.rtmps.youtube.com:443/live2?", :query_not_allowed ],
      "フラグメント" => [ "rtmps://a.rtmps.youtube.com:443/live2#frag", :query_not_allowed ],
      "許可リストに無いホスト" => [ "rtmps://evil.example:443/live2", :host_not_allowed ],
      "ホストの前方一致の詐称（サフィックス）" => [ "rtmps://a.rtmps.youtube.com.evil.example:443/live2", :host_not_allowed ],
      "ホストの詐称（プレフィックス）" => [ "rtmps://evil-a.rtmps.youtube.com:443/live2", :host_not_allowed ],
      "ホストが許可リストの上位ドメインだけ" => [ "rtmps://rtmps.youtube.com:443/live2", :host_not_allowed ],
      "許可リストに無い YouTube のホスト（ワイルドカードにしない）" => [ "rtmps://c.rtmps.youtube.com:443/live2", :host_not_allowed ],
      "ホストの大文字（厳密に小文字のみ）" => [ "rtmps://A.rtmps.youtube.com:443/live2", :host_not_allowed ],
      "IPv4 アドレス" => [ "rtmps://127.0.0.1:443/live2", :host_not_allowed ],
      "IPv6 アドレス" => [ "rtmps://[::1]:443/live2", :host_not_allowed ],
      "ホストが空" => [ "rtmps://:443/live2", :host_not_allowed ],
      "ポートの省略" => [ "rtmps://a.rtmps.youtube.com/live2", :port_not_allowed ],
      "ポートが 1935（本番の許可ホストでは不可）" => [ "rtmps://a.rtmps.youtube.com:1935/live2", :port_not_allowed ],
      "ポートの先頭の 0" => [ "rtmps://a.rtmps.youtube.com:0443/live2", :port_not_allowed ],
      "ポートが空" => [ "rtmps://a.rtmps.youtube.com:/live2", :port_not_allowed ],
      "ポートの後ろに文字" => [ "rtmps://a.rtmps.youtube.com:443x/live2", :port_not_allowed ],
      "パスが無い" => [ "rtmps://a.rtmps.youtube.com:443", :path_not_allowed ],
      "パスが / だけ" => [ "rtmps://a.rtmps.youtube.com:443/", :path_not_allowed ],
      "配信キーを URL に混ぜた形（/live2/キー）" => [ "rtmps://a.rtmps.youtube.com:443/live2/dummy-stream-key", :path_not_allowed ],
      "パーセントエンコード" => [ "rtmps://a.rtmps.youtube.com:443/li%76e2", :path_not_allowed ],
      "アプリ名が長すぎる（65 文字）" => [ "rtmps://a.rtmps.youtube.com:443/#{'a' * 65}", :path_not_allowed ],
      "アプリ名に記号" => [ "rtmps://a.rtmps.youtube.com:443/live2.x", :path_not_allowed ]
    }.each do |label, (url, code)|
      it "#{label}: #{code}" do
        expect(code_of(url)).to eq(code)
      end
    end

    {
      "nil" => nil,
      "空文字列" => "",
      "文字列でない（シンボル）" => :"rtmps://a.rtmps.youtube.com:443/live2",
      "文字列でない（数値）" => 1,
      "空白を含む" => "rtmps://a.rtmps.youtube.com:443/live2 ",
      "改行を含む" => "rtmps://a.rtmps.youtube.com:443/live2\n",
      "タブを含む" => "rtmps://a.rtmps.youtube.com:443/li\tve2",
      "NUL を含む" => "rtmps://a.rtmps.youtube.com:443/live2\0",
      "非 ASCII を含む" => "rtmps://a.rtmps.youtube.com:443/#{[ 0x65E5 ].pack('U')}",
      "長すぎる（256 バイトを超える）" => "rtmps://a.rtmps.youtube.com:443/#{'a' * 220}#{'b' * 8}#{'c' * 5}"
    }.each do |label, url|
      it "#{label}: invalid_url" do
        expect(code_of(url)).to eq(:invalid_url)
      end
    end

    it "長すぎる URL の長さは、ちょうど境界を試している（256 バイトは構文として通り、別の理由で拒否される）" do
      prefix = "rtmps://a.rtmps.youtube.com:443/"
      edge = prefix + ("a" * (256 - prefix.bytesize))
      over = edge + "a"

      expect(edge.bytesize).to eq(256)
      expect(code_of(edge)).to eq(:path_not_allowed)
      expect(code_of(over)).to eq(:invalid_url)
    end

    it "拒否は、最初に当たった理由の符号で返す（スキーム -> クエリ -> ユーザー情報 -> ホスト -> ポート -> パスの順）" do
      expect(code_of("ftp://u@evil.example:1/x/y?z")).to eq(:scheme_not_allowed)
      expect(code_of("rtmps://u@evil.example:1/x/y?z")).to eq(:query_not_allowed)
      expect(code_of("rtmps://u@evil.example:1/x/y")).to eq(:userinfo_not_allowed)
      expect(code_of("rtmps://evil.example:1/x/y")).to eq(:host_not_allowed)
      expect(code_of("rtmps://a.rtmps.youtube.com:1/x/y")).to eq(:port_not_allowed)
      expect(code_of("rtmps://a.rtmps.youtube.com:443/x/y")).to eq(:path_not_allowed)
    end
  end

  describe "例外（URL の内容を含めない）" do
    it "メッセージ・inspect・原因に、URL（配信キーを混ぜた形を含む）を出さない。符号だけ" do
      url = "rtmps://a.rtmps.youtube.com:443/live2/dummy-stream-key-must-not-appear"

      error = begin
        validate(url)
      rescue described_class::Invalid => e
        e
      end

      expect(error.message).to eq("youtube_error class=Invalid detail=path_not_allowed")
      expect(error.code).to eq(:path_not_allowed)
      expect(error.inspect).not_to include("dummy-stream-key-must-not-appear")
      expect(error.full_message).not_to include("dummy-stream-key-must-not-appear")
      expect(error.cause).to be_nil
    end

    it "YouTube の分類された例外の一種（UnexpectedResponse）。準備の失敗として扱える（disposition を持つ）" do
      error = described_class::Invalid.new(:host_not_allowed)

      expect(error).to be_a(YouTubeErrors::UnexpectedResponse)
      expect(error).to be_a(YouTubeErrors::Base)
      expect(error.disposition.end_reason).to eq("prepare_failed")
      expect(error.disposition.settlement_result).to eq(:failed)
    end

    it "未知の符号は ArgumentError（自由な文章を載せない）" do
      expect { described_class::Invalid.new("free text with spaces") }.to raise_error(ArgumentError)
      expect { described_class::Invalid.new(:other) }.to raise_error(ArgumentError, /code/)
    end
  end

  describe "開発・テストの疑似の取り込み口（契約 dev_ingest）" do
    let(:fake_url) { "rtmps://fake-ingest:1935/live2" }

    it "development・test では許可する" do
      expect(validate(fake_url, environment: development)).to eq(fake_url)
      expect(validate(fake_url, environment: test_environment)).to eq(fake_url)
    end

    it "production では許可しない（疑似のホストは、存在しないものとして扱う）" do
      expect(code_of(fake_url, environment: production)).to eq(:host_not_allowed)
    end

    it "疑似の取り込み口のポートは 1935 だけ（443 は不可）。YouTube のホストのポートは、開発でも 443 だけ" do
      expect(code_of("rtmps://fake-ingest:443/live2", environment: development)).to eq(:port_not_allowed)
      expect(code_of("rtmps://a.rtmps.youtube.com:1935/live2", environment: development)).to eq(:port_not_allowed)
    end

    it "開発でも、平文の RTMP・別ホストは許可しない" do
      expect(code_of("rtmp://fake-ingest:1935/live2", environment: development)).to eq(:scheme_not_allowed)
      expect(code_of("rtmps://fake-ingest.evil.example:1935/live2", environment: development)).to eq(:host_not_allowed)
    end

    it "環境を省くと、現在の環境（AppEnvironment.current。テストでは test）で判定する" do
      expect(described_class.validate!(fake_url)).to eq(fake_url)
    end
  end

  describe ".targets（許可リスト）" do
    it "production は YouTube の取り込み口だけ。development・test は、疑似の取り込み口が加わる" do
      pairs = ->(environment) { described_class.targets(environment).map { |target| [ target.host, target.port ] } }

      expect(pairs.call(production)).to eq([ [ "a.rtmps.youtube.com", 443 ], [ "b.rtmps.youtube.com", 443 ] ])
      expect(pairs.call(development)).to eq([ [ "a.rtmps.youtube.com", 443 ], [ "b.rtmps.youtube.com", 443 ], [ "fake-ingest", 1935 ] ])
      expect(pairs.call(test_environment)).to eq(pairs.call(development))
    end

    it "設定ファイルの値は、契約（src/contracts/limits.json）の rtmps_ingest・dev_ingest と一致する" do
      youtube = ExternalServices.config.fetch(:youtube)

      expect(youtube.fetch(:rtmps_ingest)).to eq(
        scheme: Contract::Limits::RTMPS_INGEST.fetch("scheme"),
        hosts: Contract::Limits::RTMPS_INGEST.fetch("hosts"),
        port: Contract::Limits::RTMPS_INGEST.fetch("port")
      )
      expect(youtube.fetch(:dev_ingest)).to eq(
        scheme: Contract::Limits::DEV_INGEST.fetch("scheme"),
        host: Contract::Limits::DEV_INGEST.fetch("host"),
        port: Contract::Limits::DEV_INGEST.fetch("port"),
        allowed_environments: Contract::Limits::DEV_INGEST.fetch("allowed_environments")
      )
      expect(Contract::Limits::RTMPS_INGEST.fetch("userinfo_allowed")).to be(false)
      expect(Contract::Limits::RTMPS_INGEST.fetch("query_allowed")).to be(false)
    end

    it "許可リストの実装は、スキームを rtmps に固定する（設定が rtmp に書き換えられても、平文を許可しない）" do
      allow(ExternalServices).to receive(:config).and_return(
        ExternalServices.config.merge(
          youtube: ExternalServices.config.fetch(:youtube).merge(
            rtmps_ingest: ExternalServices.config.fetch(:youtube).fetch(:rtmps_ingest).merge(scheme: "rtmp")
          )
        )
      )

      expect { described_class.targets(production) }.to raise_error(ArgumentError, /scheme/)
    end

    it "環境が AppEnvironment でなければ ArgumentError（既定の環境へ倒さない）" do
      expect { described_class.targets("production") }.to raise_error(ArgumentError, /environment/)
      expect { described_class.validate!("rtmps://a.rtmps.youtube.com:443/live2", environment: nil) }.to raise_error(ArgumentError, /environment/)
    end
  end
end
