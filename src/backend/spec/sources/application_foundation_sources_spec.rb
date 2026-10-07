require "rails_helper"
require "ripper"

# アプリケーション基盤（issue #7）のソースの検査（コメントは対象外。字句解析で、コードの部分だけを見る）。
#   1. 日本語の文字列リテラルが無い（利用者に表示する文章は、文言カタログへ分離する。直書きを検知する）
#   2. 実時計を読まない（時刻・時計は引数で受け取る。SystemClock だけが読む）
#   3. 利用者の IP を読む場所は、決まったファイルだけ（ForwardedHeaders・VerifiedBffRequest・ClientIp）
#   4. Rails 標準のセッション・flash を、API が使わない
#   5. ファイルを消す呼び出しが無い
#   6. 絵文字・ゼロ幅の文字が無い（アイコンは FontAwesome。見えない文字は、レビューで見逃す）
# 他の issue のファイル（app/services/settings_store.rb など）は、対象に入れない。
RSpec.describe "アプリケーション基盤のソース" do
  root = Rails.root

  # issue #7 が作ったファイル（相対パス）
  foundation_files = %w[
    lib/api_error_body.rb lib/forwarded_headers.rb lib/host_rejected_app.rb lib/internal_listener.rb lib/listener_port.rb
    lib/not_found_app.rb lib/public_listener.rb lib/request_logger.rb
    app/controllers/api/base_controller.rb app/controllers/api/error.rb app/controllers/api/usage_events_controller.rb
    app/services/bff_guard.rb app/services/bucketizer.rb app/services/browser_class.rb app/services/browser_usage_event.rb
    app/services/client_ip.rb app/services/cookie_policy.rb app/services/csrf_token.rb app/services/derived_keys.rb
    app/services/oauth_state_cookie.rb app/services/public_origin.rb app/services/rate_limit_policy.rb app/services/rate_limiter.rb
    app/services/session_cookie.rb app/services/session_store.rb app/services/system_clock.rb app/services/usage_recorder.rb
    app/services/verified_bff_request.rb
    config/allowed_hosts.rb config/required_environment.rb
    config/initializers/listener_ports.rb config/initializers/request_pipeline.rb config/initializers/required_environment.rb
  ].freeze

  ignored_token_types = %i[ on_comment on_sp on_nl on_ignored_nl on_embdoc_beg on_embdoc on_embdoc_end ]

  # 日本語の文字（ひらがな・カタカナ・漢字・全角の記号・半角カナ）
  japanese = /[\p{Hiragana}\p{Katakana}\p{Han}　-〿＀-￯]/

  def code_tokens(path, ignored)
    Ripper.lex(File.read(path, encoding: "UTF-8")).reject { |_, type, _, _| ignored.include?(type) }
  end

  def relative(path, root)
    Pathname.new(path).relative_path_from(root).to_s
  end

  def hits(files, root, ignored_types)
    files.flat_map do |path|
      yield(code_tokens(path, ignored_types), relative(path, root))
    end
  end

  let(:files) { foundation_files.map { |name| root.join(name).to_s } }

  it "検査の対象のファイルが、すべて存在する（ファイル名の取り違えで、検査が空にならない）" do
    missing = foundation_files.reject { |name| root.join(name).file? }

    expect(missing).to be_empty, "存在しない: #{missing.join(', ')}"
  end

  it "文字列リテラルに、日本語が無い（利用者に表示する文章を、コードに直書きしない）" do
    found = hits(files, root, ignored_token_types) do |tokens, name|
      tokens.filter_map { |(line, _), type, text, _| "#{name}:#{line}" if type == :on_tstring_content && text.match?(japanese) }
    end

    expect(found).to be_empty, "日本語の文字列リテラルがある（文言カタログへ分離してください）:\n#{found.join("\n")}"
  end

  it "実時計（Time.now・Time.current・Date.today・Date.current・DateTime.now）を読まない。SystemClock だけが読む" do
    clock_calls = { "Time" => %w[ now current ], "Date" => %w[ today current ], "DateTime" => %w[ now current ] }
    # SystemClock は、時計の唯一の読み取り口。RequestLogger の時刻は、ログの出力のためで、業務の判定には使わない
    allowed = [ "app/services/system_clock.rb", "lib/request_logger.rb" ]
    found = hits(files, root, ignored_token_types) do |tokens, name|
      next [] if allowed.include?(name)

      tokens.each_cons(3).filter_map do |first, second, third|
        next unless first[1] == :on_const && second[1] == :on_period && clock_calls.fetch(first[2], []).include?(third[2])

        "#{name}:#{first[0][0]}: #{first[2]}.#{third[2]}"
      end
    end

    expect(found).to be_empty, "実時計を読んでいる（時刻は引数で受け取る）:\n#{found.join("\n")}"
  end

  it "利用者の IP を読む場所は、ForwardedHeaders・VerifiedBffRequest・ClientIp だけ（IP は、頻度制限の計数にだけ使う）" do
    ip_names = /remote_ip|x_forwarded_for|forwarded_for|HTTP_X_FORWARDED_FOR|HTTP_CLIENT_IP|REMOTE_ADDR|HTTP_FORWARDED/i
    allowed = %w[ lib/forwarded_headers.rb app/services/verified_bff_request.rb app/services/client_ip.rb ]
    found = hits(files, root, ignored_token_types) do |tokens, name|
      next [] if allowed.include?(name)

      by_name = tokens.filter_map do |(line, _), type, text, _|
        "#{name}:#{line}: #{text}" if %i[ on_ident on_const on_tstring_content on_label on_ivar ].include?(type) && text.match?(ip_names)
      end
      by_call = tokens.each_cons(2).filter_map do |first, second|
        "#{name}:#{first[0][0]}: .ip" if first[1] == :on_period && second[1] == :on_ident && second[2] == "ip"
      end
      by_name + by_call
    end

    expect(found).to be_empty, "IP を読む場所が、決まったファイルの外にある:\n#{found.join("\n")}"
  end

  it "ClientIp は、IP を記録するメソッド（保存・ログ）を呼ばない" do
    tokens = code_tokens(root.join("app/services/client_ip.rb").to_s, ignored_token_types)
    forbidden = %w[ create create! save save! update update! logger info warn error debug ]

    called = tokens.each_cons(2).filter_map { |first, second| second[2] if first[1] == :on_period && forbidden.include?(second[2]) }
    expect(called).to be_empty
  end

  it "API のコントローラは、Rails 標準のセッション・flash を使わない（セッションは SessionStore）" do
    api_files = Dir[root.join("app/controllers/api/**/*.rb").to_s]
    found = hits(api_files, root, ignored_token_types) do |tokens, name|
      tokens.each_cons(2).filter_map do |first, second|
        next unless first[1] == :on_ident

        standard = %w[ flash reset_session ].include?(first[2]) || (first[2] == "session" && second[2] == "[")
        "#{name}:#{first[0][0]}: #{first[2]}" if standard
      end
    end

    expect(found).to be_empty, "標準のセッション・flash を使っている:\n#{found.join("\n")}"
  end

  it "API のコントローラは、rescue_from を使わない（Rails は、rescue_from で受けた例外のメッセージを、ログへ出す。機密が漏れる）" do
    api_files = Dir[root.join("app/controllers/api/**/*.rb").to_s]
    found = hits(api_files, root, ignored_token_types) do |tokens, name|
      tokens.filter_map { |(line, _), type, text, _| "#{name}:#{line}" if type == :on_ident && text == "rescue_from" }
    end

    expect(found).to be_empty, "rescue_from を使っている（動作の中で受けて、Api::Error にして投げ直す）:\n#{found.join("\n")}"
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

  it "標準出力へ書く呼び出し（puts・print・pp・p）が無い（ログは Rails.logger。機密・IP を、標準出力へ出さない）" do
    found = hits(files, root, ignored_token_types) do |tokens, name|
      tokens.each_cons(2).filter_map do |first, second|
        "#{name}:#{first[0][0]}: #{first[2]}" if first[1] == :on_ident && %w[ puts print pp p ].include?(first[2]) && second[1] != :on_op
      end
    end

    expect(found).to be_empty, "標準出力へ書いている:\n#{found.join("\n")}"
  end

  it "絵文字・ゼロ幅の文字・異体字選択子が無い（コメントを含む全文）" do
    forbidden = /[\u{200B}-\u{200F}\u{2028}-\u{202E}\u{2060}-\u{2064}\u{FE00}-\u{FE0F}\u{FEFF}\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{2300}-\u{23FF}]/
    found = files.flat_map do |path|
      File.readlines(path, encoding: "UTF-8").each_with_index.filter_map do |line, index|
        "#{relative(path, root)}:#{index + 1}" if line.match?(forbidden)
      end
    end

    expect(found).to be_empty, "絵文字・見えない文字がある:\n#{found.join("\n")}"
  end

  it "/api のコントローラは、Api::BaseController を継承する。ログインが要る動作は、requires_login で宣言する" do
    api_files = Dir[root.join("app/controllers/api/**/*_controller.rb").to_s] - [ root.join("app/controllers/api/base_controller.rb").to_s ]

    expect(api_files).not_to be_empty
    api_files.each do |path|
      source = File.read(path, encoding: "UTF-8")
      expect(source).to match(/class \w+ < (Api::)?BaseController/), "#{relative(path, root)} が BaseController を継承していない"
    end
    expect(File.read(root.join("app/controllers/api/usage_events_controller.rb"), encoding: "UTF-8")).to include("requires_login")
  end

  it "検出の仕組みが働く（日本語の文字列リテラル・実時計の呼び出し・標準出力の呼び出しを含む断片を、検出する）" do
    source = "x = \"#{[ 0x65E5, 0x672C ].pack('U*')}\"\ny = Time.now\nputs y\n"
    tokens = Ripper.lex(source).reject { |_, type, _, _| ignored_token_types.include?(type) }

    expect(tokens.any? { |_, type, text, _| type == :on_tstring_content && text.match?(japanese) }).to be(true)
    expect(tokens.each_cons(3).any? { |a, b, c| a[2] == "Time" && b[1] == :on_period && c[2] == "now" }).to be(true)
    expect(tokens.any? { |_, type, text, _| type == :on_ident && text == "puts" }).to be(true)
  end
end
