class YouTubeGateway
  # YouTube への要求の組み立てと、引数の検査（issue #10。requirements.md 9.1・10.1）。窓口の内部の部品。
  #
  # 配信の作成内容（10.1）: タイトル・公開範囲・子ども向けの申告＝受付の入力値、開始予定時刻＝呼び出し側が決めた時刻（作成時点から 1 分後）、
  # enableAutoStart: true・enableAutoStop: true・モニターストリーム無効、その他は YouTube の既定。
  # part=snippet,contentDetails,status を指定する（contentDetails を part に含めないと、自動開始・自動停止・モニター無効の指定が
  # 捨てられて既定（モニター有効・自動開始なし）になり、10.1 の「テスト段階を経ずにライブへ進める」が成立しない。事前確認）。
  # enableAutoStop の既定値は文書に無いので、true を明示する。scheduledEndTime は付けない（scheduledEndTimeRequired が返ったら、準備の失敗）。
  # ストリームの作成内容（10.1）: part=snippet,cdn,contentDetails,status・取り込み種別 rtmp・解像度とフレームレートは variable（自動検出）・
  # isReusable: true（既定に任せず明示）。
  #
  # 引数の違反は ArgumentError。メッセージは、引数の名前だけ（タイトルなど、値を載せない）。
  module Requests
    # 配信の作成の引数（params）のキー。過不足は ArgumentError（想定外のキーを、そのまま YouTube へ送らない）
    BROADCAST_PARAMS = %i[ title privacy_status made_for_kids scheduled_start_time ].freeze
    # タイトルの長さ（9.1。文字数）。山括弧（< >）を含まない
    TITLE_LENGTH = (1..100)
    TITLE_FORBIDDEN = /[<>]/
    # YouTube の識別子（配信・ストリーム）の形。要求の URL に載せるので、形を検査する
    ID_PATTERN = /\A[A-Za-z0-9_.-]{1,128}\z/

    BROADCAST_PARTS = "snippet,contentDetails,status".freeze
    STREAM_PARTS = "snippet,cdn,contentDetails,status".freeze

    class << self
      # 配信の作成の引数を検査して、シンボルのキーの Hash で返す
      def broadcast_params!(params)
        raise ArgumentError, "params must be a Hash" unless params.is_a?(Hash)

        missing = BROADCAST_PARAMS - params.keys
        unknown = params.keys - BROADCAST_PARAMS
        raise ArgumentError, "params is missing: #{missing.join(', ')}" unless missing.empty?
        raise ArgumentError, "params has unknown keys: #{unknown.map(&:to_s).join(', ')}" unless unknown.empty?

        validate_title!(params.fetch(:title))
        raise ArgumentError, "privacy_status must be one of #{Broadcast::PRIVACY_STATUSES.inspect}" unless Broadcast::PRIVACY_STATUSES.include?(params.fetch(:privacy_status))
        raise ArgumentError, "made_for_kids must be true or false" unless [ true, false ].include?(params.fetch(:made_for_kids))
        raise ArgumentError, "scheduled_start_time must be a Time" unless params.fetch(:scheduled_start_time).is_a?(Time)

        params
      end

      # 配信の作成の本文（liveBroadcasts.insert）
      def broadcast_body(params)
        {
          "snippet" => { "title" => params.fetch(:title), "scheduledStartTime" => params.fetch(:scheduled_start_time).utc.iso8601 },
          "status" => { "privacyStatus" => params.fetch(:privacy_status), "selfDeclaredMadeForKids" => params.fetch(:made_for_kids) },
          "contentDetails" => {
            "enableAutoStart" => true,
            "enableAutoStop" => true,
            "monitorStream" => { "enableMonitorStream" => false }
          }
        }
      end

      # ストリームの作成の本文（liveStreams.insert）。title は、設定のストリームの名前
      def stream_body(title)
        {
          "snippet" => { "title" => title },
          "cdn" => { "ingestionType" => "rtmp", "resolution" => "variable", "frameRate" => "variable" },
          "contentDetails" => { "isReusable" => true }
        }
      end

      # YouTube の識別子（配信・ストリーム）。形が違えば ArgumentError（name は引数の名前）
      def id!(value, name)
        raise ArgumentError, "#{name} must be a YouTube identifier" unless value.is_a?(String) && ID_PATTERN.match?(value)

        value
      end

      private

      def validate_title!(title)
        valid = title.is_a?(String) && TITLE_LENGTH.cover?(title.length) && !TITLE_FORBIDDEN.match?(title)
        raise ArgumentError, "title must be a String of #{TITLE_LENGTH} characters without angle brackets" unless valid
      end
    end
  end
end
