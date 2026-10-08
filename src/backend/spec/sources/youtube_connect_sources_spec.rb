require "rails_helper"
require "ripper"

# YouTube 接続（issue #11）のソースの検査（コメントは対象外。字句解析で、コードの部分だけを見る）。
#   1. 日本語の文字列リテラルが無い・URL を直書きしない（文言・URL は、文言カタログ・設定ファイルへ。画面（ERB）にも日本語の直書きが無い）
#   2. 実時計を読まない（時刻は引数・時計から）
#   3. ログへ出す値は、許可した名前だけ（結果・理由の符号・内部のアカウント識別子。トークン・コード・state・検証子・チャンネル名を出さない）
#   4. 利用者の IP を読む場所は、コントローラの頻度制限の 1 か所だけ
#   5. 失効の取り違えを防ぐ: 手続きは TokenVault#revoke（保存した接続を消す）を呼ばない。受け取ったトークンの失効は、Google の口（oidc.revoke）だけ
#   6. 接続の行ロックを持ったまま TokenVault を呼ばない（行をロックしない）。窓口（probe_channel）を呼ぶのは、手続きだけ
#   7. 例外を握りつぶさない・グローバル変数・クラス変数が無い・標準出力へ書かない・ファイルを消す呼び出しが無い・絵文字が無い・実行権限が無い
#   8. 契約の固定値（頻度制限の上限・窓、チャンネル名の保持時間）を、数値で直書きしない
# 削除系の語は、このファイルにも素のまま書かない（語を組み立てる）。
RSpec.describe "YouTube 接続のソース" do
  root = Rails.root

  # issue #11 が作った（または変更した）、アプリケーションのコード（相対パス）
  code_files = %w[
    app/services/youtube_connect_service.rb app/services/channel_name_cache.rb app/services/recheck_gate.rb app/services/rate_limiter.rb
    app/gateways/oauth_grant.rb app/gateways/google_oidc_client.rb app/gateways/fake_google_oidc.rb
    app/controllers/api/youtube_controller.rb app/controllers/dev/google_connect_controller.rb
    app/controllers/api/error/broadcast_in_progress.rb app/controllers/api/error/not_connected.rb app/controllers/api/error/unverifiable.rb
    config/initializers/token_encryption_key.rb config/initializers/zeitwerk_inflections.rb config/routes.rb
  ].freeze
  other_files = %w[ config/external_services.yml app/views/dev/google_connect/consent.html.erb ].freeze

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
  let(:service_path) { root.join("app/services/youtube_connect_service.rb").to_s }
  let(:controller_path) { root.join("app/controllers/api/youtube_controller.rb").to_s }

  it "検査の対象のファイルが、すべて存在する（ファイル名の取り違えで、検査が空にならない）" do
    missing = (code_files + other_files).reject { |name| root.join(name).file? }

    expect(missing).to be_empty, "存在しない: #{missing.join(', ')}"
  end

  describe "文言・URL・時刻" do
    it "文字列リテラルに、日本語が無い（利用者に表示する文章を、コードに直書きしない）" do
      found = hits(files, root, ignored_token_types) do |tokens, name|
        tokens.filter_map { |(line, _), type, text, _| "#{name}:#{line}" if type == :on_tstring_content && text.match?(japanese) }
      end

      expect(found).to be_empty, "日本語の文字列リテラルがある（文言カタログへ分離してください）:\n#{found.join("\n")}"
    end

    it "画面（ERB）にも、日本語の直書きが無い（文言は t ヘルパーで ja.yml から引く）" do
      template = root.join("app/views/dev/google_connect/consent.html.erb").read(encoding: "UTF-8")

      expect(template).not_to match(japanese)
      expect(template).to include('t("dev.google.authorize.title")')
    end

    it "外部サービスの URL を、コードに直書きしない（YouTube のスコープも、config/external_services.yml）" do
      found = hits(files, root, ignored_token_types) do |tokens, name|
        tokens.filter_map { |(line, _), type, text, _| "#{name}:#{line}" if type == :on_tstring_content && text.match?(full_url) }
      end

      expect(found).to be_empty, "URL の直書きがある:\n#{found.join("\n")}"
      expect(root.join("config/external_services.yml").read).to include("youtube_scope: https://www.googleapis.com/auth/youtube")
    end

    it "設定ファイルに、資格情報・トークンの語を書かない" do
      expect(root.join("config/external_services.yml").read).not_to match(/client_secret|client_id|secret_key|password|refresh_token|access_token/i)
    end

    it "実時計（Time.now・Time.current・Date.today・Date.current・DateTime.now）を読まない（時刻は引数 now・注入した時計から）" do
      clock_calls = { "Time" => %w[ now current ], "Date" => %w[ today current ], "DateTime" => %w[ now current ] }
      found = hits(files, root, ignored_token_types) do |tokens, name|
        tokens.each_cons(3).filter_map do |first, second, third|
          next unless first[1] == :on_const && second[1] == :on_period && clock_calls.fetch(first[2], []).include?(third[2])

          "#{name}:#{first[0][0]}: #{first[2]}.#{third[2]}"
        end
      end

      expect(found).to be_empty, "実時計を読んでいる:\n#{found.join("\n")}"
    end

    it "契約の固定値（頻度制限の上限・窓、チャンネル名の保持時間）を、数値で直書きしない（Contract::Limits から得る）" do
      # 60 は、単位の換算（分 -> 秒）にも使われる数なので、数えない。それ以外の、頻度制限の上限・窓と、チャンネル名の保持時間（秒）
      limits = Contract::Limits::RATE_LIMITS.values.flat_map { |rule| rule.slice("limit", "window_seconds").values.grep(Integer) }
      numbers = (limits + [ Contract::Limits::RETENTION.fetch("channel_title_memory_max_minutes") * 60 ]).select { |value| value >= 20 }.uniq - [ 60 ]
      scanned = code_files - %w[ config/routes.rb config/initializers/zeitwerk_inflections.rb app/services/rate_limiter.rb ]
      found = hits(scanned.map { |name| root.join(name).to_s }, root, ignored_token_types) do |tokens, name|
        tokens.filter_map { |(line, _), type, text, _| "#{name}:#{line}: #{text}" if type == :on_int && numbers.include?(text.delete("_").to_i) }
      end

      expect(numbers).to include(20, 30, 600, 3600, 86_400)
      expect(found).to be_empty, "契約の固定値を直書きしている:\n#{found.join("\n")}"
    end
  end

  describe "ログ" do
    it "ログへ出す値は、許可した名前だけ（logger の呼び出しの #{}。トークン・コード・state・検証子・チャンネル名・sub を出さない）" do
      allowed = [
        "LOG_TAG", "account_field(user)", "result", "reason", "state", "CS::REVOKED", "verdict.reason", "error.message", "failure.reason",
        "status"
      ]
      found = files.flat_map do |path|
        File.readlines(path, encoding: "UTF-8").each_with_index.flat_map do |line, index|
          next [] unless line.match?(/\blogger\.(info|warn|error|debug)\b/)

          line.scan(/#\{(.*?)\}/).flatten.map(&:strip).reject { |expression| allowed.include?(expression) }.map { |expression| "#{relative(path, root)}:#{index + 1}: #{expression}" }
        end
      end

      expect(found).to be_empty, "許可していない値を、ログへ出している:\n#{found.join("\n")}"
    end

    it "account_field は、内部のアカウント識別子（user.id）か none だけを出す" do
      source = File.read(service_path, encoding: "UTF-8")
      body = source[/def account_field\(user\).*?\n  end\n/m]

      expect(body).to include("user_id=")
      expect(body).to include("user.id")
      expect(body).not_to match(/google_sub|sub\b|email|title/)
    end

    it "標準出力へ書く呼び出し（puts・print・pp・p）が無い（ログは Rails.logger）" do
      found = hits(files, root, ignored_token_types) do |tokens, name|
        tokens.each_cons(2).filter_map do |first, second|
          "#{name}:#{first[0][0]}: #{first[2]}" if first[1] == :on_ident && %w[ puts print pp p ].include?(first[2]) && second[1] != :on_op
        end
      end

      expect(found).to be_empty
    end
  end

  describe "利用者の IP" do
    it "利用者の IP を読む場所は、YouTube のコントローラの頻度制限の 1 か所だけ（client_ip）。IP の名前を、ほかのファイルで使わない" do
      ip_names = /remote_ip|x_forwarded_for|forwarded_for|HTTP_X_FORWARDED_FOR|HTTP_CLIENT_IP|REMOTE_ADDR|HTTP_FORWARDED|remoteip|\bclient_ip\b/i
      others = code_files - %w[ app/controllers/api/youtube_controller.rb config/routes.rb ]
      found = hits(others.map { |name| root.join(name).to_s }, root, ignored_token_types) do |tokens, name|
        tokens.filter_map { |(line, _), type, text, _| "#{name}:#{line}: #{text}" if %i[ on_ident on_const on_tstring_content on_label on_ivar ].include?(type) && text.match?(ip_names) }
      end
      lines = File.read(controller_path, encoding: "UTF-8").lines.select { |line| line.match?(/\bclient_ip\b/) && !line.strip.start_with?("#") }

      expect(found).to be_empty, "IP を読んでいる:\n#{found.join("\n")}"
      expect(lines.size).to eq(1)
      expect(lines.first).to include("enforce_rate_limit!(RateLimitPolicy.connect_start, client_ip.to_s)")
    end
  end

  describe "失効・ロック・窓口の取り扱い" do
    it "手続きは、TokenVault#revoke（保存した接続を消す）を呼ばない。受け取ったトークンの失効は、Google の口（@oidc.revoke）だけ" do
      tokens = code_tokens(service_path, ignored_token_types)
      revokes = tokens.each_cons(3).filter_map { |a, b, c| a[2] if b[1] == :on_period && c[2] == "revoke" }

      expect(revokes).to eq([ "@oidc" ])
    end

    it "接続の行をロックしない（lock・lock!・with_lock を呼ばない）。TokenVault を呼ぶ前に、行ロックを持たないため" do
      tokens = code_tokens(service_path, ignored_token_types)
      locking = tokens.each_cons(2).filter_map { |a, b| b[2] if a[1] == :on_period && %w[ lock lock! with_lock ].include?(b[2]) }

      expect(locking).to be_empty
    end

    it "トランザクションは ApplicationRecord.transaction だけ（requires_new を使わない）。TokenVault#store の内側のセーブポイントに任せる" do
      source = File.read(service_path, encoding: "UTF-8").lines.reject { |line| line.strip.start_with?("#") }.join

      expect(source.scan(/(\w+(?:::\w+)*)\.transaction\b/).flatten.uniq).to eq([ "ApplicationRecord" ])
      expect(source).not_to include("requires_new")
    end

    it "YouTube の確認（probe_channel）を呼ぶのは、手続き（YouTubeConnectService）だけ。窓口の外で、YouTube へ HTTP を送らない" do
      app_files = Dir[root.join("{app,lib}/**/*.rb").to_s]
      callers = app_files.select do |path|
        code_tokens(path, ignored_token_types).each_cons(3).any? { |a, b, c| a[1] == :on_ivar && b[1] == :on_period && c[2] == "probe_channel" }
      end

      expect(callers.map { |path| relative(path, root) }).to eq([ "app/services/youtube_connect_service.rb" ])
    end

    it "コントローラは、ドメインの手続き・窓口を直接呼ばない（YouTubeConnectService・RecheckGate を通す）" do
      tokens = code_tokens(controller_path, ignored_token_types)
      constants = tokens.filter_map { |_, type, text, _| text if type == :on_const }

      expect(constants).not_to include("YouTubeGateway", "TokenVault", "QuotaLedger", "ExternalHttp", "GoogleTokenClient")
    end
  end

  describe "一般の規則" do
    it "ファイルを消す呼び出しが無い。行を消す呼び出し（delete_all・destroy 系）も無い" do
      file_removals = [ "r" + "m", "r" + "mdir", "rem" + "ove", "del" + "ete", "un" + "link" ]
      receivers = %w[ File FileUtils Dir Pathname ]
      row_removals = [ "del" + "ete_all", "des" + "troy", "des" + "troy_all", "des" + "troy!" ]
      file_calls = hits(files, root, ignored_token_types) do |tokens, name|
        tokens.each_cons(3).filter_map do |first, second, third|
          "#{name}:#{first[0][0]}" if first[1] == :on_const && receivers.include?(first[2]) && second[1] == :on_period && file_removals.include?(third[2])
        end
      end
      row_calls = hits(files, root, ignored_token_types) do |tokens, name|
        tokens.each_cons(2).filter_map { |first, second| "#{name}:#{first[0][0]}" if first[1] == :on_period && row_removals.include?(second[2]) }
      end

      expect(file_calls).to be_empty
      expect(row_calls).to be_empty
    end

    it "例外を握りつぶさない: rescue は、クラスを指定する（StandardError・Exception・指定なしは不可）" do
      found = hits(files, root, ignored_token_types) do |tokens, name|
        tokens.each_cons(3).filter_map do |first, second, third|
          next unless first[1] == :on_kw && first[2] == "rescue"

          splat = second[1] == :on_op && second[2] == "*"
          subject = splat ? third : second
          broad = subject[1] != :on_const || %w[ StandardError Exception ].include?(subject[2])
          "#{name}:#{first[0][0]}" if broad
        end
      end

      expect(found).to be_empty, "広い rescue がある:\n#{found.join("\n")}"
    end

    it "グローバル変数・クラス変数が無い" do
      found = hits(files, root, ignored_token_types) do |tokens, name|
        tokens.filter_map { |(line, _), type, _, _| "#{name}:#{line}" if %i[ on_gvar on_cvar ].include?(type) }
      end

      expect(found).to be_empty
    end

    it "Api::BaseController を継承し、API のコントローラは Rails 標準のセッション・flash・rescue_from を使わない" do
      source = File.read(controller_path, encoding: "UTF-8")
      names = code_tokens(controller_path, ignored_token_types).filter_map { |_, type, text, _| text if type == :on_ident }

      expect(source).to match(/class YoutubeController < BaseController/)
      expect(names & %w[ flash reset_session session rescue_from ]).to be_empty
      expect(File.read(root.join("app/controllers/dev/google_connect_controller.rb"), encoding: "UTF-8")).to match(/class GoogleConnectController < Api::BaseController/)
    end

    it "ログインの方針を、動作ごとに宣言している" do
      source = File.read(controller_path, encoding: "UTF-8")

      expect(source).to include("requires_login only: %i[ connect_start recheck ]")
      expect(source).to include("allow_anonymous only: %i[ connect_callback ]")
      expect(File.read(root.join("app/controllers/dev/google_connect_controller.rb"), encoding: "UTF-8")).to match(/^\s+allow_anonymous$/)
    end

    it "絵文字・ゼロ幅の文字・異体字選択子が無い（コメント・設定・画面を含む全文）" do
      forbidden = /[\u{200B}-\u{200F}\u{2028}-\u{202E}\u{2060}-\u{2064}\u{FE00}-\u{FE0F}\u{FEFF}\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{2300}-\u{23FF}]/
      found = (code_files + other_files).flat_map do |name|
        File.readlines(root.join(name), encoding: "UTF-8").each_with_index.filter_map { |line, index| "#{name}:#{index + 1}" if line.match?(forbidden) }
      end

      expect(found).to be_empty, "絵文字・見えない文字がある:\n#{found.join("\n")}"
    end

    it "実行権限が無い（実行権限つきのファイルは、CI の削除系の語の検査の対象になる）" do
      executable = (code_files + other_files).select { |name| root.join(name).executable? }

      expect(executable).to be_empty
    end

    it "秘密鍵を置かない（*.pem・*.key のファイル、PEM の秘密鍵のブロック）" do
      key_files = Dir[root.join("**/*.{pem,key}").to_s].reject { |path| path.include?("/vendor/") || path.include?("/.cache/") || path.include?("/tmp/") }
      blocks = (code_files + other_files).select { |name| root.join(name).read.match?(/-----BEGIN [A-Z ]*PRIVATE KEY-----/) }

      expect(key_files).to be_empty
      expect(blocks).to be_empty
    end
  end

  describe "Zeitwerk の個別の指定" do
    it "YouTubeConnectService は、ファイル名の単位の個別の指定で読み込まれる（グローバルな inflect.acronym で YouTube を足さない）" do
      inflector = Rails.autoloaders.main.inflector

      expect(inflector.camelize("youtube_connect_service", "")).to eq("YouTubeConnectService")
      expect(inflector.camelize("youtube_connection", "")).to eq("YoutubeConnection")
      expect(inflector.camelize("youtube_controller", "")).to eq("YoutubeController")
      expect(ActiveSupport::Inflector.inflections(:en).acronyms.keys).not_to include("youtube")
    end

    it "app/services・app/gateways・app/controllers のすべてのファイルが、期待する定数を定義する（eager load で確かめる）" do
      %w[ app/services app/gateways app/controllers ].each do |dir|
        expect { Rails.autoloaders.main.eager_load_dir(root.join(dir).to_s) }.not_to raise_error
      end
    end
  end

  it "検出の仕組みが働く（日本語の文字列・URL・実時計・標準出力・広い rescue・許可していないログの値を、検出する）" do
    source = "x = \"#{[ 0x65E5, 0x672C ].pack('U*')}\"\nu = \"https://api.example.test/v1\"\ny = Time.now\nputs y\nbegin\n  1\nrescue => e\n  2\nend\n"
    tokens = Ripper.lex(source).reject { |_, type, _, _| ignored_token_types.include?(type) }

    expect(tokens.any? { |_, type, text, _| type == :on_tstring_content && text.match?(japanese) }).to be(true)
    expect(tokens.any? { |_, type, text, _| type == :on_tstring_content && text.match?(full_url) }).to be(true)
    expect(tokens.each_cons(3).any? { |a, b, c| a[2] == "Time" && b[1] == :on_period && c[2] == "now" }).to be(true)
    expect(tokens.any? { |_, type, text, _| type == :on_ident && text == "puts" }).to be(true)
    expect(tokens.each_cons(3).any? { |a, b, _| a[1] == :on_kw && a[2] == "rescue" && b[1] != :on_const }).to be(true)
    expect("logger.info(\"x \#{token}\")".scan(/#\{(.*?)\}/).flatten).to eq([ "token" ])
  end
end
