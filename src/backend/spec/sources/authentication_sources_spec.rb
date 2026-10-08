require "rails_helper"
require "ripper"

# 認証（issue #8）のソースの検査（コメントは対象外。字句解析で、コードの部分だけを見る）。
#   1. 日本語の文字列リテラルが無い（利用者に表示する文章は、文言カタログ（config/locales/ja.yml）へ分離。直書きを検知する）
#   2. 外部サービスの URL を、コードに直書きしない（config/external_services.yml）
#   3. 外部への HTTP は、ExternalHttp だけを通す（Net::HTTP などを、ほかの場所で使わない）
#   4. JWT の署名の検証を自作しない（jwt gem の JWT.decode だけ。OpenSSL の公開鍵・署名の API を使わない）
#   5. 実時計を読まない（時刻は引数 now で受け取る）
#   6. 利用者の IP を読む場所は、決まった 1 か所だけ（頻度制限の計数。siteverify・DB・ログへ送らない・出さない）
#   7. ログへ出す値は、許可した名前だけ（理由の符号・状態・内部の識別子。トークン・コード・state・sub を出さない）
#   8. 標準出力へ書く呼び出し・ファイルを消す呼び出し・絵文字が無い。リポジトリに秘密鍵（*.pem・*.key・PEM のブロック）が無い
RSpec.describe "認証のソース" do
  root = Rails.root

  # issue #8 が作った（または変更した）、アプリケーションのコード（相対パス）
  code_files = %w[
    app/gateways/external_http.rb app/gateways/external_services.rb app/gateways/fake_google_oidc.rb
    app/gateways/fake_recaptcha_verifier.rb app/gateways/fake_services.rb app/gateways/google_jwks_cache.rb
    app/gateways/google_oidc.rb app/gateways/google_oidc_client.rb app/gateways/recaptcha_verifier.rb
    app/services/account_registry.rb app/services/login_procedure.rb
    app/controllers/api/auth_controller.rb app/controllers/api/error/bot_check_failed.rb app/controllers/dev/google_controller.rb
    app/controllers/api/base_controller.rb
    config/initializers/locale.rb
  ].freeze
  # テキストの設定・画面（Ruby ではない）
  other_files = %w[ config/external_services.yml config/locales/ja.yml app/views/dev/google/authorize.html.erb ].freeze

  ignored_token_types = %i[ on_comment on_sp on_nl on_ignored_nl on_embdoc_beg on_embdoc on_embdoc_end ]
  japanese = /[\p{Hiragana}\p{Katakana}\p{Han}　-〿＀-￯]/
  full_url = %r{https?://[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}}

  def code_tokens(path, ignored)
    Ripper.lex(File.read(path, encoding: "UTF-8")).reject { |_, type, _, _| ignored.include?(type) }
  end

  def relative(path, root)
    Pathname.new(path).relative_path_from(root).to_s
  end

  def hits(files, root, ignored_types)
    files.flat_map { |path| yield(code_tokens(path, ignored_types), relative(path, root)) }
  end

  let(:files) { code_files.map { |name| root.join(name).to_s } }

  it "検査の対象のファイルが、すべて存在する（ファイル名の取り違えで、検査が空にならない）" do
    missing = (code_files + other_files).reject { |name| root.join(name).file? }

    expect(missing).to be_empty, "存在しない: #{missing.join(', ')}"
  end

  it "文字列リテラルに、日本語が無い（利用者に表示する文章を、コードに直書きしない）" do
    found = hits(files, root, ignored_token_types) do |tokens, name|
      tokens.filter_map { |(line, _), type, text, _| "#{name}:#{line}" if type == :on_tstring_content && text.match?(japanese) }
    end

    expect(found).to be_empty, "日本語の文字列リテラルがある（文言カタログへ分離してください）:\n#{found.join("\n")}"
  end

  it "画面（ERB）にも、日本語の直書きが無い（文言は t ヘルパーで ja.yml から引く）" do
    template = root.join("app/views/dev/google/authorize.html.erb").read(encoding: "UTF-8")

    expect(template).not_to match(japanese)
    expect(template).to include('t(".title")')
  end

  it "外部サービスの URL を、コードに直書きしない（config/external_services.yml に置く）" do
    found = hits(files, root, ignored_token_types) do |tokens, name|
      tokens.filter_map { |(line, _), type, text, _| "#{name}:#{line}" if type == :on_tstring_content && text.match?(full_url) }
    end

    expect(found).to be_empty, "URL の直書きがある:\n#{found.join("\n")}"
  end

  it "外部サービスの URL は、設定ファイルにある（https だけ）" do
    urls = root.join("config/external_services.yml").read.scan(full_url)

    expect(urls.size).to be >= 4
    expect(root.join("config/external_services.yml").read).not_to match(%r{http://})
  end

  it "外部への HTTP は、ExternalHttp だけを通す（Net::HTTP・open-uri・Faraday などを、ExternalHttp の外で使わない）" do
    client_constants = %w[ Faraday HTTParty Typhoeus RestClient Excon HTTPClient ]
    client_libraries = %w[ net/http open-uri faraday httparty typhoeus rest-client excon httpclient ]
    app_files = Dir[root.join("{app,lib,config}/**/*.rb").to_s] - [ root.join("app/gateways/external_http.rb").to_s ]
    found = app_files.filter_map do |path|
      tokens = code_tokens(path, ignored_token_types)
      by_constant = tokens.any? { |_, type, text, _| type == :on_const && client_constants.include?(text) }
      by_library = tokens.any? { |_, type, text, _| type == :on_tstring_content && client_libraries.include?(text) }
      net_http = tokens.each_cons(3).any? { |a, b, c| a[2] == "Net" && b[2] == "::" && c[2] == "HTTP" }
      uri_open = tokens.each_cons(3).any? { |a, b, c| a[2] == "URI" && b[1] == :on_period && c[2] == "open" }
      relative(path, root) if by_constant || by_library || net_http || uri_open
    end

    expect(found).to be_empty, "ExternalHttp の外で HTTP クライアントを使っている:\n#{found.join("\n")}"
  end

  it "JWT の署名の検証を自作しない（jwt gem の JWT.decode だけ。OpenSSL の公開鍵・署名の API を、アプリケーションで使わない）" do
    app_files = Dir[root.join("app/**/*.rb").to_s]
    decode_calls = app_files.flat_map do |path|
      code_tokens(path, ignored_token_types).each_cons(3).filter_map do |a, b, c|
        relative(path, root) if a[2] == "JWT" && b[1] == :on_period && c[2] == "decode"
      end
    end
    pkey = app_files.filter_map do |path|
      relative(path, root) if code_tokens(path, ignored_token_types).each_cons(3).any? { |a, b, c| a[2] == "OpenSSL" && b[2] == "::" && c[2] == "PKey" }
    end

    expect(decode_calls).to eq([ "app/gateways/google_oidc_client.rb" ])
    expect(pkey).to be_empty, "OpenSSL::PKey を使っている（署名の検証は jwt gem に任せる）:\n#{pkey.join("\n")}"
  end

  it "JWT.decode は、アルゴリズムを RS256 に限り、署名の検証を有効にして呼ぶ（verify = true）" do
    source = root.join("app/gateways/google_oidc_client.rb").read

    expect(source).to match(/ALGORITHMS = %w\[ RS256 \]/)
    expect(source).to match(/JWT\.decode\(id_token, nil, true, decode_options\(now\)\)/)
    expect(source).to match(/algorithms: ALGORITHMS/)
    expect(source).not_to match(/JWT\.decode\([^)]*\bfalse\b/)
  end

  it "実時計（Time.now・Time.current・Date.today・Date.current・DateTime.now）を読まない（時刻は引数 now で受け取る）" do
    clock_calls = { "Time" => %w[ now current ], "Date" => %w[ today current ], "DateTime" => %w[ now current ] }
    found = hits(files, root, ignored_token_types) do |tokens, name|
      tokens.each_cons(3).filter_map do |first, second, third|
        next unless first[1] == :on_const && second[1] == :on_period && clock_calls.fetch(first[2], []).include?(third[2])

        "#{name}:#{first[0][0]}: #{first[2]}.#{third[2]}"
      end
    end

    expect(found).to be_empty, "実時計を読んでいる:\n#{found.join("\n")}"
  end

  it "利用者の IP を読む場所は、auth_controller.rb の頻度制限の 1 か所だけ（client_ip）。IP の名前を、ほかで使わない" do
    ip_names = /remote_ip|x_forwarded_for|forwarded_for|HTTP_X_FORWARDED_FOR|HTTP_CLIENT_IP|REMOTE_ADDR|HTTP_FORWARDED|remoteip|\bclient_ip\b/i
    found = hits(files, root, ignored_token_types) do |tokens, name|
      next [] if name == "app/controllers/api/base_controller.rb" # #7 のファイル（IP の読み出しは #7 の検査の対象）

      by_name = tokens.filter_map do |(line, _), type, text, _|
        "#{name}:#{line}: #{text}" if %i[ on_ident on_const on_tstring_content on_label on_ivar ].include?(type) && text.match?(ip_names)
      end
      by_call = tokens.each_cons(2).filter_map { |first, second| "#{name}:#{first[0][0]}: .ip" if first[1] == :on_period && second[1] == :on_ident && second[2] == "ip" }
      by_name + by_call
    end
    lines = root.join("app/controllers/api/auth_controller.rb").read.lines.select { |line| line.match?(/\bclient_ip\b/) && !line.strip.start_with?("#") }

    expect(found.map { |entry| entry.split(":").first }.uniq).to eq([ "app/controllers/api/auth_controller.rb" ])
    expect(found.size).to eq(1)
    expect(lines.size).to eq(1)
    expect(lines.first).to include("enforce_rate_limit!(RateLimitPolicy.login_start, client_ip.to_s)")
  end

  it "ログへ出す値は、許可した名前だけ（logger の呼び出しの #{}。トークン・コード・state・nonce・検証子・sub を出さない）" do
    allowed = [
      "LOG_TAG", "failure.reason", "error.host", "error.reason", "method", "cause", "status", "user.id", "reason", "policy",
      "self.class.name", "action_name", "request.request_id", "api_error.status", "api_error.code", "api_error.reason", "describe_cause(error)"
    ]
    found = files.flat_map do |path|
      File.readlines(path, encoding: "UTF-8").each_with_index.flat_map do |line, index|
        next [] unless line.match?(/\blogger\.(info|warn|error|debug)\b/)

        line.scan(/#\{(.*?)\}/).flatten.map(&:strip).reject { |expression| allowed.include?(expression) }.map { |expression| "#{relative(path, root)}:#{index + 1}: #{expression}" }
      end
    end

    expect(found).to be_empty, "許可していない値を、ログへ出している:\n#{found.join("\n")}"
  end

  it "標準出力へ書く呼び出し（puts・print・pp・p）が無い（ログは Rails.logger）" do
    found = hits(files, root, ignored_token_types) do |tokens, name|
      tokens.each_cons(2).filter_map do |first, second|
        "#{name}:#{first[0][0]}: #{first[2]}" if first[1] == :on_ident && %w[ puts print pp p ].include?(first[2]) && second[1] != :on_op
      end
    end

    expect(found).to be_empty
  end

  it "ファイル・ディレクトリを消す呼び出しが無い" do
    removal_methods = [ "r" + "m", "r" + "mdir", "rem" + "ove", "del" + "ete", "un" + "link" ]
    removal_receivers = %w[ File FileUtils Dir Pathname ]
    found = hits(files, root, ignored_token_types) do |tokens, name|
      tokens.each_cons(3).filter_map do |first, second, third|
        "#{name}:#{first[0][0]}" if first[1] == :on_const && removal_receivers.include?(first[2]) && second[1] == :on_period && removal_methods.include?(third[2])
      end
    end

    expect(found).to be_empty
  end

  it "疑似のコントローラは、rescue_from・標準のセッション・flash を使わない" do
    tokens = code_tokens(root.join("app/controllers/dev/google_controller.rb").to_s, ignored_token_types)
    names = tokens.filter_map { |(_line, _), type, text, _| text if type == :on_ident }

    expect(names & %w[ rescue_from flash reset_session session ]).to be_empty
  end

  it "認証のコントローラは、Api::BaseController を継承し、ログインの方針を宣言する" do
    auth = root.join("app/controllers/api/auth_controller.rb").read
    dev = root.join("app/controllers/dev/google_controller.rb").read

    expect(auth).to match(/class AuthController < BaseController/)
    expect(auth).to include("requires_login only: %i[ logout ]")
    expect(auth).to include("allow_anonymous only: %i[ login_start callback ]")
    expect(dev).to match(/class GoogleController < Api::BaseController/)
    expect(dev).to match(/^\s+allow_anonymous$/)
  end

  it "絵文字・ゼロ幅の文字・異体字選択子が無い（コメント・設定・画面を含む全文）" do
    forbidden = /[\u{200B}-\u{200F}\u{2028}-\u{202E}\u{2060}-\u{2064}\u{FE00}-\u{FE0F}\u{FEFF}\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{2300}-\u{23FF}]/
    found = (code_files + other_files).flat_map do |name|
      File.readlines(root.join(name), encoding: "UTF-8").each_with_index.filter_map { |line, index| "#{name}:#{index + 1}" if line.match?(forbidden) }
    end

    expect(found).to be_empty, "絵文字・見えない文字がある:\n#{found.join("\n")}"
  end

  it "秘密鍵を置かない（*.pem・*.key のファイル、PEM の秘密鍵のブロック。スペックの RSA 鍵は、メモリの上でだけ生成する）" do
    key_files = Dir[root.join("**/*.{pem,key}").to_s].reject { |path| path.include?("/vendor/") || path.include?("/.cache/") || path.include?("/tmp/") }
    candidates = Dir[root.join("{app,config,lib,spec}/**/*").to_s].select { |path| File.file?(path) } - [ __FILE__ ]
    blocks = candidates.select { |path| File.binread(path).include?("-----BEGIN") && File.binread(path).match?(/-----BEGIN [A-Z ]*PRIVATE KEY-----/) }

    expect(key_files).to be_empty
    expect(blocks.map { |path| relative(path, root) }).to be_empty
  end

  it "検出の仕組みが働く（日本語の文字列・URL・実時計・標準出力・許可していないログの値を、検出する）" do
    source = "x = \"#{[ 0x65E5, 0x672C ].pack('U*')}\"\nu = \"https://api.example.test/v1\"\ny = Time.now\nputs y\n"
    tokens = Ripper.lex(source).reject { |_, type, _, _| ignored_token_types.include?(type) }

    expect(tokens.any? { |_, type, text, _| type == :on_tstring_content && text.match?(japanese) }).to be(true)
    expect(tokens.any? { |_, type, text, _| type == :on_tstring_content && text.match?(full_url) }).to be(true)
    expect(tokens.each_cons(3).any? { |a, b, c| a[2] == "Time" && b[1] == :on_period && c[2] == "now" }).to be(true)
    expect(tokens.any? { |_, type, text, _| type == :on_ident && text == "puts" }).to be(true)
    expect("logger.info(\"x \#{token}\")".scan(/#\{(.*?)\}/).flatten).to eq([ "token" ])
  end
end
