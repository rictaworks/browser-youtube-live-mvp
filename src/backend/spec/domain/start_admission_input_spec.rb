require "spec_helper"
require_relative "support/domain_loader"

# 開始の受付の入力の検証（requirements.md 9.1・9.2 の順 0。契約 http-api.md の POST /api/broadcasts の要求）。
#   title           1〜100 文字（Unicode のコードポイントの数）・山括弧（<・>）を含まない・空白だけは不可
#   privacy_status  public・unlisted・private の 3 値
#   made_for_kids   子ども向けの申告。true・false の真偽が必須（未選択 = nil は不備）
# 不備のある項目名を、すべて返す（複数の不備は全項目。項目の順は、title・privacy_status・made_for_kids）。
# bot 判定のトークン（recaptcha_token）は、順 3 の bot 判定で、サーバー側で検証する（この検証には含めない）。
RSpec.describe "開始の受付の入力の検証（StartAdmission::Input）" do
  let(:input_class) { StartAdmission::Input }

  def input(**overrides)
    StartAdmission::Input.new(**{ title: "ライブ配信", privacy_status: "unlisted", made_for_kids: false }.merge(overrides))
  end

  it "不備がなければ、不備のある項目は空（凍結した配列）" do
    expect(input.invalid_fields).to eq([])
    expect(input.invalid_fields).to be_frozen
    expect(input).to be_frozen
  end

  it "項目は title・privacy_status・made_for_kids の 3 つだけ（bot 判定のトークン・ユーザーの識別情報を持たない）" do
    expect(input_class.members).to eq(%i[title privacy_status made_for_kids])
  end

  it "何も指定しない（すべて nil）と、3 項目すべてが不備（未選択も不備）" do
    expect(input_class.new.invalid_fields).to eq(%w[title privacy_status made_for_kids])
  end

  describe "title（1〜100 文字・山括弧なし・空白だけは不可）" do
    {
      "1 文字" => "a",
      "100 文字（ASCII）" => "a" * 100,
      "100 文字（全角。1 文字 3 バイトでも、文字数で数える）" => "あ" * 100,
      "100 文字（絵文字。UTF-16 では 200 だが、コードポイントで数える）" => "\u{1F600}" * 100,
      "100 文字（結合文字を含む。コードポイントで数える）" => "e\u{0301}" * 50,
      "日付つきの既定のタイトルの形" => "ライブ配信 2026-10-07 13:30",
      "前後に空白（空白だけではない）" => "  a  ",
      "全角の山括弧に似た文字（＜＞。山括弧は < と > だけ）" => "＜テスト＞",
      "山括弧に似た記号（《》〈〉）" => "《テスト》〈テスト〉",
      "記号・引用符・アンパサンド" => "Q&A \"live\" 'show' / 100%",
      "1 文字の空白でない全角文字" => "あ"
    }.each do |label, title|
      it "有効: #{label}" do
        expect(input(title: title).invalid_fields).to eq([])
      end
    end

    {
      "空文字列（0 文字）" => "",
      "半角スペース 1 つ" => " ",
      "半角スペースだけ" => "     ",
      "タブと改行だけ" => "\t\n\r",
      "全角スペース（U+3000）だけ" => "\u{3000}",
      "全角スペースと半角スペースだけ" => " \u{3000} ",
      "ノーブレークスペース（U+00A0）だけ" => "\u{00A0}",
      "EM スペース（U+2003）だけ" => "\u{2003}",
      "行区切り（U+2028）だけ" => "\u{2028}",
      "幅のない空白（U+200B）だけ" => "\u{200B}",
      "幅のない結合禁止（U+200D）と BOM（U+FEFF）だけ" => "\u{200D}\u{FEFF}",
      "101 文字（ASCII）" => "a" * 101,
      "101 文字（全角）" => "あ" * 101,
      "101 文字（絵文字）" => "\u{1F600}" * 101,
      "101 文字（結合文字を含む。コードポイントで数える）" => "#{"e\u{0301}" * 50}x",
      "山括弧 <（先頭）" => "<b>bold</b>",
      "山括弧 <（途中）" => "a<b",
      "山括弧 >（途中）" => "a>b",
      "山括弧 > だけ" => ">",
      "山括弧 < だけ" => "<",
      "山括弧のペア" => "<>",
      "100 文字で、そのうち 1 文字が山括弧" => "#{"a" * 99}<",
      "不正な UTF-8（バイト列が壊れている）" => "abc\xFF".dup.force_encoding("UTF-8"),
      "バイナリ（ASCII-8BIT）の非 ASCII" => "\xE3\x81\x82".dup.force_encoding("ASCII-8BIT"),
      "UTF-16 の文字列" => "abc".encode("UTF-16LE")
    }.each do |label, title|
      it "不備: #{label}" do
        expect(input(title: title).invalid_fields).to eq([ "title" ])
      end
    end

    it "文字列でないものは不備（nil・数値・シンボル・配列・Hash・true）" do
      [ nil, 123, 1.5, :title, [ "a" ], { "a" => 1 }, true, Object.new ].each do |invalid|
        expect(input(title: invalid).invalid_fields).to eq([ "title" ])
      end
    end

    it "ASCII だけのバイナリ文字列（ASCII-8BIT）は有効（非 ASCII を含まない）" do
      expect(input(title: "live".b).invalid_fields).to eq([])
    end

    it "巨大な文字列（1 MB）は、走査せずに、不備と判定する（長さの上限の 4 倍のバイト数を超える）" do
      expect(input(title: "a" * 1_000_000).invalid_fields).to eq([ "title" ])
      expect(input(title: "あ" * 1_000_000).invalid_fields).to eq([ "title" ])
    end

    it "inspect・to_s は、タイトルを含まない（ログ・例外へ出さない。ほかの項目は表示する）" do
      secret = input(title: "SECRET-TITLE-0123456789")

      [ secret.inspect, secret.to_s, "#{secret}", [ secret ].inspect ].each do |text|
        expect(text).not_to include("SECRET")
        expect(text).to include("[FILTERED]", "unlisted", "false")
        expect(text).to be_ascii_only
      end
    end

    it "to_h は、判定のために、タイトルを持つ（呼び出し側が、ログへ出さない）" do
      expect(input(title: "ライブ配信").to_h).to eq(title: "ライブ配信", privacy_status: "unlisted", made_for_kids: false)
    end

    it "検証は、タイトルの内容を例外にもログにも出さない（不備は項目名だけ）" do
      secret = "<secret-title-0123456789>"
      result = input(title: secret).invalid_fields

      expect(result).to eq([ "title" ])
      expect(result.inspect).not_to include("secret")
    end
  end

  describe "privacy_status（public・unlisted・private）" do
    %w[public unlisted private].each do |status|
      it "有効: #{status}" do
        expect(input(privacy_status: status).invalid_fields).to eq([])
      end
    end

    [
      "", "Public", "PUBLIC", "unlisted ", " private", "private\n", "friends", "limited", "public,private", "非公開", "限定公開"
    ].each do |status|
      it "不備: #{status.inspect}" do
        expect(input(privacy_status: status).invalid_fields).to eq([ "privacy_status" ])
      end
    end

    it "文字列でないものは不備（nil・シンボル・数値・真偽値・配列）" do
      [ nil, :public, :unlisted, 0, 1, true, false, [ "public" ] ].each do |invalid|
        expect(input(privacy_status: invalid).invalid_fields).to eq([ "privacy_status" ])
      end
    end
  end

  describe "made_for_kids（true・false の真偽が必須。未選択は不備）" do
    [ true, false ].each do |value|
      it "有効: #{value}" do
        expect(input(made_for_kids: value).invalid_fields).to eq([])
      end
    end

    [ nil, "true", "false", "yes", "no", "1", "0", 1, 0, 1.0, "", :true, :false, [], {} ].each do |invalid|
      it "不備: #{invalid.inspect}（未選択・真偽値でないもの）" do
        expect(input(made_for_kids: invalid).invalid_fields).to eq([ "made_for_kids" ])
      end
    end
  end

  describe "複数の不備は、全項目を返す（項目の順は title・privacy_status・made_for_kids）" do
    {
      "title だけ" => [ { title: "" }, %w[title] ],
      "privacy_status だけ" => [ { privacy_status: "x" }, %w[privacy_status] ],
      "made_for_kids だけ" => [ { made_for_kids: nil }, %w[made_for_kids] ],
      "title と privacy_status" => [ { title: "<", privacy_status: "x" }, %w[title privacy_status] ],
      "title と made_for_kids" => [ { title: " ", made_for_kids: nil }, %w[title made_for_kids] ],
      "privacy_status と made_for_kids" => [ { privacy_status: nil, made_for_kids: "true" }, %w[privacy_status made_for_kids] ],
      "3 項目すべて" => [ { title: "a" * 101, privacy_status: "Public", made_for_kids: 1 }, %w[title privacy_status made_for_kids] ]
    }.each do |label, (overrides, expected)|
      it label do
        expect(input(**overrides).invalid_fields).to eq(expected)
      end
    end
  end

  describe "値を変えない・検証は決定的" do
    it "検証は、入力を変更しない（凍結した文字列でも動く）。何度呼んでも同じ" do
      title = "ライブ配信".freeze
      subject_input = input(title: title)

      expect(subject_input.invalid_fields).to eq(subject_input.invalid_fields)
      expect(subject_input.title).to equal(title)
    end

    it "with で変えた入力も検証される" do
      expect(input.with(title: "").invalid_fields).to eq([ "title" ])
    end
  end
end
