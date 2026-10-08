# 取り込み先（RTMPS の宛先）の検証（issue #10。requirements.md 6.1・10.1・28.1）。
#
# 取り込み先は、YouTube が返す rtmpsIngestionAddress だけで、利用者が宛先を指定する手段は存在しない。アプリケーションは、
# 取り込み先を中継へ返す前に、このクラスで検証する（YouTubeGateway#ensure_stream が、返す前に検証する）。中継も、送出の前に、
# もう一度検証する（src/relay/internal/rtmps/destination.go。二重にする）。この検証が通る URL は、中継の検証も通る
# （アプリケーションの許可は、中継の許可に含まれる。大文字のホスト・ポートの先頭の 0 など、中継が許す形も、ここでは拒否する）。
#
# 許すのは、次のすべてを満たす URL だけ。
#   - rtmps://ホスト:ポート/アプリ名 の形。平文の RTMP を許さない
#   - ホストが、許可リスト（設定ファイル config/external_services.yml の youtube.rtmps_ingest.hosts。契約 rtmps_ingest）に、完全に一致する。
#     IP アドレス・サブドメインの詐称・別のホストを許さない（IP アドレスでは接続しない。SNI にホスト名を設定する）
#   - ポートが、そのホストの許可のポート（YouTube は 443）に、文字列として一致する。省略・0443 を許さない
#   - ユーザー情報（user:pass@）・クエリ（バックアップの ?backup=1 など）・フラグメントを持たない
#   - パスが、1 つのアプリ名（英数字・_・-。64 文字まで）だけ。配信キーを URL に混ぜた形（/live2/キー）を許さない
# 開発・テストの環境（契約 dev_ingest.allowed_environments）だけ、疑似の取り込み口（fake-ingest:1935）を、許可リストに加える。
# production の許可リストには、存在しない。
#
# 公式に許可ホストの列挙が無い（https://developers.google.com/youtube/v3/live/guides/rtmps-ingestion は、rtmps と 443 だけを定める）。
# 許可ホストは、二次情報（OBS Studio の YouTube RTMPS プリセット）の a.rtmps.youtube.com・b.rtmps.youtube.com から始め、
# 最初の実機で、準備の応答（rtmpsIngestionAddress）のホストを採取して確定する。
#
# 違反は IngestDestination::Invalid（符号だけ。URL の内容・配信キーを含めない）。
module IngestDestination
  # 平文の RTMP を用いない（requirements.md 6.1）。設定ファイルの値には依らない（設定が書き換えられても、平文を許可しない）
  SCHEME = "rtmps".freeze
  SCHEME_PREFIX = "#{SCHEME}://".freeze

  # URL の長さの上限（バイト）。YouTube の取り込み先は 40 バイトほど
  MAX_URL_BYTES = 256
  # アプリ名（URL のパス）の形。YouTube は live2
  APP_NAME = /\A[A-Za-z0-9_-]{1,64}\z/
  # URL に使ってよい文字（空白・制御文字・DEL・非 ASCII を拒否する）
  PRINTABLE_ASCII = /\A[\x21-\x7E]+\z/

  # 違反の符号。この順に判定する
  CODES = %i[
    invalid_url scheme_not_allowed query_not_allowed userinfo_not_allowed host_not_allowed port_not_allowed path_not_allowed
  ].freeze

  # 許可する宛先（ホストとポート）
  Target = Data.define(:host, :port)

  # 取り込み先が、許可に合わない。UnexpectedResponse の一種（YouTube が返した宛先が不正）なので、準備の失敗として扱える。
  # code は違反の符号（CODES）。メッセージは、符号だけ（URL を含めない）
  class Invalid < YouTubeErrors::UnexpectedResponse
    def initialize(code)
      raise ArgumentError, "code must be one of #{CODES.inspect}" unless CODES.include?(code)

      super(detail: code)
    end

    def code
      detail
    end
  end

  class << self
    # url（取り込み先。配信キーを含まない）を検証する。通れば、凍結した複製を返す。違反は Invalid。
    # environment は AppEnvironment（疑似の取り込み口を許す環境かの判定に使う。既定は現在の環境）
    def validate!(url, environment: AppEnvironment.current)
      allowed = targets(environment)
      check_syntax!(url)
      invalid!(:scheme_not_allowed) unless url.start_with?(SCHEME_PREFIX)

      rest = url.delete_prefix(SCHEME_PREFIX)
      invalid!(:query_not_allowed) if rest.match?(/[?#]/)

      authority, slash, path = rest.partition("/")
      invalid!(:userinfo_not_allowed) if authority.include?("@")

      host, colon, port = authority.partition(":")
      target = allowed.find { |candidate| candidate.host == host }
      invalid!(:host_not_allowed) if target.nil?
      invalid!(:port_not_allowed) unless colon == ":" && port == target.port.to_s
      invalid!(:path_not_allowed) unless slash == "/" && APP_NAME.match?(path)

      url.dup.freeze
    end

    # 許可する宛先の一覧。YouTube の取り込み口（設定の youtube.rtmps_ingest）に、開発・テストの環境だけ、疑似の取り込み口を加える
    def targets(environment)
      raise ArgumentError, "environment must be an AppEnvironment, got #{environment.class}" unless environment.is_a?(AppEnvironment)

      youtube = ExternalServices.config.fetch(:youtube)
      rtmps = youtube.fetch(:rtmps_ingest)
      fake = youtube.fetch(:dev_ingest)
      [ rtmps, fake ].each do |section|
        raise ArgumentError, "the scheme of the ingest configuration must be #{SCHEME}" unless section.fetch(:scheme) == SCHEME
      end

      list = rtmps.fetch(:hosts).map { |host| Target.new(host: host, port: rtmps.fetch(:port)) }
      list << Target.new(host: fake.fetch(:host), port: fake.fetch(:port)) if fake.fetch(:allowed_environments).include?(environment.name.to_s)
      list.freeze
    end

    private

    def check_syntax!(url)
      valid = url.is_a?(String) && url.bytesize <= MAX_URL_BYTES && PRINTABLE_ASCII.match?(url)
      invalid!(:invalid_url) unless valid
    end

    def invalid!(code)
      raise Invalid.new(code)
    end
  end
end
