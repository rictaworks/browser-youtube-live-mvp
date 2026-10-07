require "rails_helper"

# 公開オリジン（フロントエンドのオリジン。issue #7・src/contracts/http-api.md 1.2・6）。
# リダイレクト先の組み立てと、CSRF の Origin の照合に使う。BFF の確認を通った要求の X-Forwarded-Host・X-Forwarded-Proto から作る。
# バックエンドのホスト（*.up.railway.app）を、ブラウザへ出さない。
RSpec.describe PublicOrigin do
  describe ".from_forwarded（正しい値）" do
    # [ host, proto, 期待する文字列 ]
    [
      [ "app.example.test", "https", "https://app.example.test" ],
      [ "app.example.test", "http", "http://app.example.test" ],
      [ "localhost:3000", "http", "http://localhost:3000" ],
      [ "my-app-git-main.vercel.app", "https", "https://my-app-git-main.vercel.app" ],
      [ "App.Example.TEST", "HTTPS", "https://app.example.test" ],
      [ "app.example.test:8443", "https", "https://app.example.test:8443" ],
      [ "203.0.113.5:3000", "http", "http://203.0.113.5:3000" ],
      [ "a", "https", "https://a" ]
    ].each do |host, proto, expected|
      it "host=#{host.inspect}・proto=#{proto.inspect} → #{expected}" do
        expect(described_class.from_forwarded(host: host, proto: proto).to_s).to eq(expected)
      end
    end

    it "複数の値（途中の経路が足した値）は、先頭（BFF が付けた値）を使う" do
      origin = described_class.from_forwarded(host: "app.example.test, backend.up.railway.app", proto: "https, http")

      expect(origin.to_s).to eq("https://app.example.test")
    end

    it "前後の空白を除く" do
      expect(described_class.from_forwarded(host: " app.example.test ", proto: " https ").to_s).to eq("https://app.example.test")
    end
  end

  describe ".from_forwarded（正しくない値は、補わず、例外にする）" do
    {
      "host が無い" => [ nil, "https" ],
      "host が空" => [ "", "https" ],
      "host が空白だけ" => [ "  ", "https" ],
      "proto が無い" => [ "app.example.test", nil ],
      "proto が空" => [ "app.example.test", "" ],
      "proto が http・https 以外（ftp）" => [ "app.example.test", "ftp" ],
      "proto が http・https 以外（javascript）" => [ "app.example.test", "javascript" ],
      "proto にスキームの区切りを含む" => [ "app.example.test", "https://" ],
      "host に経路を含む" => [ "app.example.test/path", "https" ],
      "host にユーザー情報を含む" => [ "user@evil.example", "https" ],
      "host に空白を含む" => [ "app example.test", "https" ],
      "host に改行を含む" => [ "app.example.test\nevil.example", "https" ],
      "host に制御文字を含む" => [ "app.example.test\x00", "https" ],
      "host に # を含む" => [ "app.example.test#x", "https" ],
      "host に ? を含む" => [ "app.example.test?x=1", "https" ],
      "host に \\ を含む" => [ "app.example.test\\evil.example", "https" ],
      "host がハイフンで始まる" => [ "-app.example.test", "https" ],
      "host がハイフンで終わる" => [ "app-.example.test", "https" ],
      "host に連続したドットを含む" => [ "app..example.test", "https" ],
      "host がドットで終わる" => [ "app.example.test.", "https" ],
      "host に非 ASCII を含む" => [ "app.exampl\xC3\xA9.test", "https" ],
      "host が IPv6 のリテラル" => [ "[::1]:3000", "http" ],
      "ポートが 0" => [ "app.example.test:0", "https" ],
      "ポートが範囲外" => [ "app.example.test:65536", "https" ],
      "ポートが空" => [ "app.example.test:", "https" ],
      "ポートが数字でない" => [ "app.example.test:abc", "https" ],
      "host が長すぎる" => [ "#{'a' * 64}.example.test", "https" ],
      "host 全体が長すぎる" => [ ([ "a" * 60 ] * 5).join(".") + ".test", "https" ]
    }.each do |label, (host, proto)|
      it "#{label}（#{host.inspect[0, 40]}・#{proto.inspect}）" do
        expect { described_class.from_forwarded(host: host, proto: proto) }.to raise_error(PublicOrigin::InvalidError)
      end
    end

    it "例外のメッセージに、渡された値を含めない（攻撃者が選べる値を、ログへ出さない）" do
      expect { described_class.from_forwarded(host: "evil.example/dummy-path-must-not-appear", proto: "https") }
        .to raise_error(PublicOrigin::InvalidError) { |error| expect(error.message).not_to include("dummy-path-must-not-appear") }
    end
  end

  describe "#url_for（リダイレクト先の絶対 URL）" do
    let(:origin) { described_class.from_forwarded(host: "app.example.test", proto: "https") }

    {
      "経路" => [ "/studio", "https://app.example.test/studio" ],
      "ルート" => [ "/", "https://app.example.test/" ],
      "クエリつき（ログインの失敗）" => [ "/?login_error=oauth_failed", "https://app.example.test/?login_error=oauth_failed" ],
      "クエリつき（接続の結果）" => [ "/account?connect=connected", "https://app.example.test/account?connect=connected" ]
    }.each do |label, (path, expected)|
      it "#{label}: #{path} → #{expected}" do
        expect(origin.url_for(path)).to eq(expected)
      end
    end

    {
      "スラッシュで始まらない" => "studio",
      "スキームを含む" => "https://evil.example/",
      "プロトコル相対（//）" => "//evil.example/",
      "バックスラッシュ" => "/\\evil.example",
      "空" => "",
      "空白を含む" => "/a b",
      "改行を含む" => "/a\nLocation: https://evil.example",
      "制御文字を含む" => "/a\x00",
      "nil" => nil
    }.each do |label, path|
      it "不正な経路（#{label}）は、例外にする" do
        expect { origin.url_for(path) }.to raise_error(ArgumentError)
      end
    end

    it "バックエンドのホストを含まない" do
      expect(origin.url_for("/studio")).not_to include("railway")
    end
  end

  describe "#matches_origin?（CSRF の Origin の照合）" do
    let(:origin) { described_class.from_forwarded(host: "app.example.test", proto: "https") }

    {
      "同じ" => [ "https://app.example.test", true ],
      "大文字・小文字の違い" => [ "HTTPS://App.Example.TEST", true ],
      "スキームが違う" => [ "http://app.example.test", false ],
      "ホストが違う" => [ "https://evil.example", false ],
      "サブドメインを足した" => [ "https://evil.app.example.test", false ],
      "前に文字を足した" => [ "https://xapp.example.test", false ],
      "ポートを足した" => [ "https://app.example.test:8443", false ],
      "末尾にスラッシュ（Origin の形ではない）" => [ "https://app.example.test/", false ],
      "経路つき" => [ "https://app.example.test/studio", false ],
      "null（サンドボックス・プライバシー設定）" => [ "null", false ],
      "空" => [ "", false ],
      "空白" => [ " ", false ],
      "前後に空白" => [ " https://app.example.test", false ]
    }.each do |label, (header, expected)|
      it "#{label}（#{header.inspect}）→ #{expected}" do
        expect(origin.matches_origin?(header)).to be(expected)
      end
    end

    it "文字列でなければ、一致しない" do
      [ nil, 1, [ "https://app.example.test" ] ].each do |header|
        expect(origin.matches_origin?(header)).to be(false)
      end
    end

    it "ポート付きの公開オリジンは、ポート付きの Origin だけに一致する" do
      with_port = described_class.from_forwarded(host: "localhost:3000", proto: "http")

      expect(with_port.matches_origin?("http://localhost:3000")).to be(true)
      expect(with_port.matches_origin?("http://localhost")).to be(false)
      expect(with_port.matches_origin?("http://localhost:3001")).to be(false)
    end
  end

  it "凍結されている" do
    expect(described_class.from_forwarded(host: "app.example.test", proto: "https")).to be_frozen
  end
end
