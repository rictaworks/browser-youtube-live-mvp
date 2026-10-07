require "rails_helper"

# 利用者の IP（requirements.md 28.1・28.2。issue #7）。BFF の確認を通った要求の X-Forwarded-For の先頭だけから読む。
# IP は、頻度制限の計数にだけ使う。DB・測定イベント・配信レコード・ログへ記録しない（inspect にも出さない）。
RSpec.describe ClientIp do
  describe ".parse（X-Forwarded-For の先頭だけを読む）" do
    # [ 入力, 期待する値 ]
    {
      "IPv4" => [ "203.0.113.5", "203.0.113.5" ],
      "複数（先頭だけ。後ろは、途中の経路の IP）" => [ "203.0.113.5, 10.0.0.1, 10.0.0.2", "203.0.113.5" ],
      "複数（カンマの前後に空白が無い）" => [ "203.0.113.5,10.0.0.1", "203.0.113.5" ],
      "前後の空白" => [ "  203.0.113.5  ", "203.0.113.5" ],
      "IPv6" => [ "2001:db8::1", "2001:db8::1" ],
      "IPv6（長い表記は、短い表記にそろえる。同じ利用者を別の計数にしない）" => [ "2001:0DB8:0000:0000:0000:0000:0000:0001", "2001:db8::1" ],
      "IPv4 射影アドレス（IPv4 にそろえる）" => [ "::ffff:203.0.113.5", "203.0.113.5" ],
      "ループバック" => [ "127.0.0.1", "127.0.0.1" ]
    }.each do |label, (input, expected)|
      it "#{label}: #{input.inspect} → #{expected}" do
        ip = described_class.parse(input)

        expect(ip).to be_known
        expect(ip.to_s).to eq(expected)
      end
    end

    # IP として解釈できないものは、別の値で補わず、不明（unknown）にする
    {
      "nil（ヘッダが無い）" => nil,
      "空" => "",
      "空白だけ" => "   ",
      "先頭が空（, だけ）" => ", 203.0.113.5",
      "文字列 unknown" => "unknown",
      "任意の文字列" => "abc",
      "ポート付き" => "203.0.113.5:8080",
      "ネットワーク表記（CIDR）" => "10.0.0.0/8",
      "範囲外の数" => "203.0.113.256",
      "桁が足りない" => "1.2.3",
      "先頭が 0 の数（曖昧な表記）" => "010.001.001.001",
      "ゾーン識別子つきの IPv6" => "fe80::1%eth0",
      "角括弧つきの IPv6" => "[2001:db8::1]",
      "改行を含む" => "203.0.113.5\n203.0.113.6",
      "制御文字を含む" => "203.0.113.5\x00",
      "長すぎる" => ("1" * 200),
      "HTML の断片" => "<script>"
    }.each do |label, input|
      it "#{label}（#{input.inspect[0, 30]}）は不明になる" do
        ip = described_class.parse(input)

        expect(ip).not_to be_known
        expect(ip.to_s).to eq(ClientIp::UNKNOWN)
      end
    end

    it "文字列でない入力（数値・配列・Hash）は、不明になる" do
      [ 203, [ "203.0.113.5" ], { "a" => 1 }, Object.new ].each do |input|
        expect(described_class.parse(input)).not_to be_known
      end
    end

    it "例外を起こさない（どんな入力でも、ClientIp を返す）" do
      [ nil, "", "\xFF\xFE", "a" * 10_000, "::", "::1", "0.0.0.0" ].each do |input|
        expect { described_class.parse(input) }.not_to raise_error
      end
    end
  end

  describe "値としての性質" do
    it "同じ IP は等しい（頻度制限の計数の鍵に使える）" do
      expect(described_class.parse("203.0.113.5")).to eq(described_class.parse(" 203.0.113.5, 10.0.0.1"))
      expect(described_class.parse("203.0.113.5").hash).to eq(described_class.parse("203.0.113.5").hash)
    end

    it "異なる IP は等しくない" do
      expect(described_class.parse("203.0.113.5")).not_to eq(described_class.parse("203.0.113.6"))
    end

    it "不明どうしは等しい" do
      expect(described_class.parse(nil)).to eq(described_class.parse("abc"))
    end

    it "inspect・to_s 以外の表示（pp・メッセージ）に、IP を出さない" do
      ip = described_class.parse("203.0.113.5")

      expect(ip.inspect).not_to include("203.0.113.5")
      expect(ip.inspect).to include("FILTERED")
    end

    it "値（IP の文字列）は、to_s で得る（頻度制限の鍵に使う）" do
      expect(described_class.parse("203.0.113.5").to_s).to eq("203.0.113.5")
    end

    it "凍結されている" do
      expect(described_class.parse("203.0.113.5")).to be_frozen
    end
  end
end
