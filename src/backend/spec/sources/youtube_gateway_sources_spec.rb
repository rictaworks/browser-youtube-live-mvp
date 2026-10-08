require "rails_helper"
require "ripper"

# YouTube 連携の窓口（issue #10）のソースの検査（コメントは対象外。字句解析で、コードの部分だけを見る）。
#   1. YouTube への HTTP は、窓口（YouTubeGateway）の 1 つの経路だけが送る（app/ を走査する。requirements.md 6.1）
#      - YouTube の API の基底の URL（api_base）に触れるのは、決まったファイルだけ。YouTube の設定（config の youtube）を読むのも、決まったファイルだけ
#      - 窓口に、HTTP を送る呼び出し（@http.request）が 1 か所だけ。公開メソッドは、すべて call を通る
#      - 台帳への支出（spend!・spend_common!）を呼ぶのは、窓口だけ
#   2. 日本語の文字列リテラルが無い・URL を直書きしない（URL は config/external_services.yml）
#   3. 実時計を読まない（時刻は引数・時計から。TokenVault#store の now: の既定値だけ許す）
#   4. ログへ出す値は、許可した名前だけ（符号・内部の識別子。トークン・配信キー・タイトル・チャンネル名を出さない）
#   5. 例外を握りつぶさない・グローバル変数・クラス変数が無い・標準出力へ書かない・ファイルを消す呼び出しが無い
#      行を消す呼び出しは、TokenVault（接続の解除）だけ
#   6. 絵文字・ゼロ幅の文字・実行権限（実行権限つきのファイルは、削除系の語の検査の対象になる）が無い
#   7. Zeitwerk の個別の指定（YouTube を含む定数）が効いている（グローバルな inflect.acronym "YouTube" は足さない）
# 削除系の語は、このファイルにも素のまま書かない（語を組み立てる）。
RSpec.describe "YouTube 連携の窓口のソース" do
  root = Rails.root

  # issue #10 が作った（または変更した）、アプリケーションのコード（相対パス）
  gateway_files = %w[
    app/gateways/youtube_gateway.rb app/gateways/youtube_gateway/calls.rb app/gateways/youtube_gateway/requests.rb app/gateways/youtube_gateway/responses.rb
    app/gateways/fake_youtube_gateway.rb app/gateways/fake_youtube_gateway/api.rb
    app/gateways/youtube_errors.rb app/gateways/youtube_status.rb app/gateways/youtube_services.rb
    app/gateways/token_vault.rb app/gateways/token_vault/access_token_cache.rb
    app/gateways/google_token_client.rb app/gateways/fake_google_token_client.rb
    app/gateways/ingest_destination.rb app/gateways/stream_info.rb app/gateways/stream_health.rb app/gateways/probe_result.rb app/gateways/unstarted_broadcast.rb
  ].freeze
  code_files = (gateway_files + %w[ app/models/youtube_connection.rb config/initializers/zeitwerk_inflections.rb ]).freeze
  other_files = %w[ config/external_services.yml ].freeze

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
  let(:app_files) { Dir[root.join("{app,lib,config}/**/*.rb").to_s] }

  it "検査の対象のファイルが、すべて存在する（ファイル名の取り違えで、検査が空にならない）" do
    missing = (code_files + other_files).reject { |name| root.join(name).file? }

    expect(missing).to be_empty, "存在しない: #{missing.join(', ')}"
  end

  describe "YouTube への HTTP の単一の窓口" do
    it "YouTube の API の基底の URL（api_base）に触れるのは、窓口・疑似の窓口・疑似の YouTube・組み立て（YouTubeServices）だけ" do
      names = %w[ api_base ]
      using = app_files.select do |path|
        code_tokens(path, ignored_token_types).any? { |_, type, text, _| %i[ on_ident on_ivar on_label ].include?(type) && names.include?(text.delete_prefix("@").delete_suffix(":")) }
      end

      expect(using.map { |path| relative(path, root) }).to match_array(
        %w[ app/gateways/youtube_gateway.rb app/gateways/fake_youtube_gateway.rb app/gateways/fake_youtube_gateway/api.rb app/gateways/youtube_services.rb ]
      )
    end

    it "YouTube の設定（config の :youtube）を読むのは、組み立て（YouTubeServices）と取り込み先の検証（IngestDestination）だけ" do
      using = app_files.select do |path|
        code_tokens(path, ignored_token_types).each_cons(2).any? { |first, second| first[1] == :on_symbeg && second[2] == "youtube" }
      end

      expect(using.map { |path| relative(path, root) }).to match_array(%w[ app/gateways/youtube_services.rb app/gateways/ingest_destination.rb ])
    end

    it "窓口が HTTP を送る呼び出し（@http.request）は 1 か所だけ（perform_request）。疑似の窓口は、それを置き換えるだけで、@http を使わない" do
      gateway = code_tokens(root.join("app/gateways/youtube_gateway.rb").to_s, ignored_token_types)
      fake = code_tokens(root.join("app/gateways/fake_youtube_gateway.rb").to_s, ignored_token_types)
      requests = gateway.each_cons(3).select { |a, b, c| a[2] == "@http" && b[1] == :on_period && c[2] == "request" }

      expect(requests.size).to eq(1)
      source = root.join("app/gateways/youtube_gateway.rb").read.lines
      expect(source[requests.first.first[0][0] - 1]).to include("@http.request(http_method, url")
      expect(fake.any? { |_, type, text, _| type == :on_ivar && text == "@http" }).to be(false)
    end

    it "窓口の公開メソッドは、すべて call（1 つの経路）を通る" do
      source = root.join("app/gateways/youtube_gateway.rb").read
      public_part = source[/\n  def insert_broadcast.*?\n  private\n/m]
      public_methods = %w[ insert_broadcast list_unstarted_broadcasts bind fetch_status fetch_stream_health complete delete ]

      public_methods.each do |name|
        body = public_part[/\n  def #{name}\b.*?\n  end\n/m]
        expect(body).to include("call(method: :"), "#{name} does not call the single path"
      end
      expect(public_part).to include("existing || create_stream(conn, broadcast)")
      expect(public_part).to include("lookup_channel(conn, access_token)")
      expect(source.scan(/^  def call\(/).size).to eq(1)
    end

    it "台帳への支出（spend!・spend_common!）を呼ぶのは、窓口だけ（YouTube の API の呼び出しは、すべて窓口を通して記帳する）" do
      ledger_files = Dir[root.join("app/services/quota_ledger.rb").to_s] + Dir[root.join("app/services/quota_ledger/*.rb").to_s]
      using = (app_files - ledger_files).select do |path|
        code_tokens(path, ignored_token_types).any? { |_, type, text, _| type == :on_ident && %w[ spend! spend_common! ].include?(text) }
      end

      expect(using.map { |path| relative(path, root) }).to eq([ "app/gateways/youtube_gateway.rb" ])
    end

    it "呼び出しの表（Calls）の単価は、契約の値（cost_key で引く。2 以上の数値を直書きしない。1 は枠の個数の比較だけ）" do
      tokens = code_tokens(root.join("app/gateways/youtube_gateway/calls.rb").to_s, ignored_token_types)

      expect(tokens.select { |_, type, text, _| type == :on_int && text.to_i > 1 }).to be_empty
    end
  end

  it "文字列リテラルに、日本語が無い（利用者に表示する文章を、コードに直書きしない）" do
    found = hits(files, root, ignored_token_types) do |tokens, name|
      tokens.filter_map { |(line, _), type, text, _| "#{name}:#{line}" if type == :on_tstring_content && text.match?(japanese) }
    end

    expect(found).to be_empty, "日本語の文字列リテラルがある（文言カタログへ分離してください）:\n#{found.join("\n")}"
  end

  it "外部サービスの URL を、コードに直書きしない（config/external_services.yml に置く）" do
    found = hits(files, root, ignored_token_types) do |tokens, name|
      tokens.filter_map { |(line, _), type, text, _| "#{name}:#{line}" if type == :on_tstring_content && text.match?(full_url) }
    end

    expect(found).to be_empty, "URL の直書きがある:\n#{found.join("\n")}"
  end

  it "外部サービスの URL は、設定ファイルにあり、https だけ（取り込み先の rtmps は、スキームと許可ホストの設定）" do
    text = root.join("config/external_services.yml").read

    expect(text.scan(full_url)).to include("https://www.googleapis.com", "https://oauth2.googleapis.com")
    expect(text).not_to match(%r{http://})
    expect(text).not_to match(/client_secret|client_id|secret_key|password|refresh_token|access_token/i)
  end

  it "実時計（Time.now・Time.current・Date.today・Date.current・DateTime.now）を読まない。TokenVault#store の now: の既定値（Time.current）だけ許す" do
    clock_calls = { "Time" => %w[ now current ], "Date" => %w[ today current ], "DateTime" => %w[ now current ] }
    found = hits(files, root, ignored_token_types) do |tokens, name|
      tokens.each_cons(4).filter_map do |before, first, second, third|
        next unless first[1] == :on_const && second[1] == :on_period && clock_calls.fetch(first[2], []).include?(third[2])
        next if name == "app/gateways/token_vault.rb" && first[2] == "Time" && third[2] == "current" && before[1] == :on_label && before[2] == "now:"

        "#{name}:#{first[0][0]}: #{first[2]}.#{third[2]}"
      end
    end

    expect(found).to be_empty, "実時計を読んでいる:\n#{found.join("\n")}"
  end

  it "ログへ出す値は、許可した名前だけ（logger の呼び出しの補間。トークン・配信キー・タイトル・チャンネル名・暗号文を出さない）" do
    allowed = [
      "LOG_TAG", "error.message", "user", "user_id", "target", "result.outcome", "cause", "kind", "error.class.name.demodulize", "fields.compact.join(' ')"
    ]
    found = files.flat_map do |path|
      File.readlines(path, encoding: "UTF-8").each_with_index.flat_map do |line, index|
        next [] unless line.match?(/\blogger\.(info|warn|error|debug)\b/)

        line.scan(/#\{(.*?)\}/).flatten.map(&:strip).reject { |expression| allowed.include?(expression) }.map { |expression| "#{relative(path, root)}:#{index + 1}: #{expression}" }
      end
    end

    expect(found).to be_empty, "許可していない値を、ログへ出している:\n#{found.join("\n")}"
  end

  it "ログの fields（窓口の失敗の記録）に載せる値は、符号と内部の識別子だけ（kind・配信レコードの識別子・アカウントの識別子・クラス名・ステータス・reason・detail）" do
    source = root.join("app/gateways/youtube_gateway.rb").read
    fields = source[/fields = \[.*?\n    \]/m]

    expressions = fields.scan(/#\{(.*?)\}/).flatten.map(&:strip)
    expect(expressions).to match_array([ "kind", "broadcast.id", "conn.user_id", "error.class.name.demodulize", "error.status", "error.reason", "error.detail" ])
  end

  it "標準出力へ書く呼び出し（puts・print・pp・p）が無い（ログは Rails.logger）" do
    found = hits(files, root, ignored_token_types) do |tokens, name|
      tokens.each_cons(2).filter_map do |first, second|
        "#{name}:#{first[0][0]}: #{first[2]}" if first[1] == :on_ident && %w[ puts print pp p ].include?(first[2]) && second[1] != :on_op
      end
    end

    expect(found).to be_empty
  end

  it "ファイルを消す呼び出しが無い。行を消す呼び出し（delete_all・destroy）は、TokenVault（接続の解除）だけ" do
    file_removals = [ "r" + "m", "r" + "mdir", "rem" + "ove", "del" + "ete", "un" + "link" ]
    receivers = %w[ File FileUtils Dir Pathname ]
    row_removals = [ "del" + "ete_all", "des" + "troy", "des" + "troy_all", "des" + "troy!" ]

    file_calls = hits(files, root, ignored_token_types) do |tokens, name|
      tokens.each_cons(3).filter_map do |first, second, third|
        "#{name}:#{first[0][0]}" if first[1] == :on_const && receivers.include?(first[2]) && second[1] == :on_period && file_removals.include?(third[2])
      end
    end
    row_calls = hits(files, root, ignored_token_types) do |tokens, name|
      tokens.each_cons(2).filter_map { |first, second| name if first[1] == :on_period && row_removals.include?(second[2]) }
    end

    expect(file_calls).to be_empty
    expect(row_calls.uniq).to eq([ "app/gateways/token_vault.rb" ])
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

  it "秘密のログ・例外へ流れ得る組み込みの to_h を、秘密を持つ値（StreamInfo・UnstartedBroadcast・ProbeResult・Tokens）が持たない" do
    secret_holders = [ StreamInfo, UnstartedBroadcast, ProbeResult, GoogleTokenClient::Tokens ]

    expect(secret_holders.reject { |holder| holder.method_defined?(:to_h) }).to eq(secret_holders)
  end

  it "絵文字・ゼロ幅の文字・異体字選択子が無い（コメント・設定を含む全文）" do
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

  describe "Zeitwerk の個別の指定（YouTube を含む定数）" do
    it "app/gateways のすべてのファイルが、期待する定数を定義する（eager load で確かめる）" do
      expect { Rails.autoloaders.main.eager_load_dir(root.join("app/gateways").to_s) }.not_to raise_error
    end

    it "個別の指定は、ファイル名の単位。グローバルな inflect.acronym で YouTube を足さない（YoutubeConnection の綴りを変えない）" do
      inflector = Rails.autoloaders.main.inflector

      expect(inflector.camelize("youtube_gateway", "")).to eq("YouTubeGateway")
      expect(inflector.camelize("fake_youtube_gateway", "")).to eq("FakeYouTubeGateway")
      expect(inflector.camelize("youtube_errors", "")).to eq("YouTubeErrors")
      expect(inflector.camelize("youtube_status", "")).to eq("YouTubeStatus")
      expect(inflector.camelize("youtube_services", "")).to eq("YouTubeServices")
      expect(inflector.camelize("youtube_connection", "")).to eq("YoutubeConnection")
      expect(ActiveSupport::Inflector.inflections(:en).acronyms.keys).not_to include("youtube")
      expect(defined?(YoutubeConnection)).to eq("constant")
    end

    it "YouTube を含む名前のファイルは、すべて個別の指定がある（足し忘れを検出する）" do
      inflector = Rails.autoloaders.main.inflector
      names = Dir[root.join("app/gateways/**/*youtube*").to_s].map { |path| File.basename(path, ".rb") }.uniq

      names.each do |name|
        camelized = inflector.camelize(name, "")
        expect(camelized).to include("YouTube"), "#{name} has no individual inflection (got #{camelized})"
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
