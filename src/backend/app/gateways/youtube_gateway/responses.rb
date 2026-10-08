class YouTubeGateway
  # YouTube の成功の応答（2xx の JSON）の解釈（issue #10。requirements.md 10.1・10.2・10.3）。窓口の内部の部品。
  #
  # 形が違う応答は、YouTubeErrors::UnexpectedResponse（detail に符号。黙って成功にしない）。応答の本文・値を、例外に載せない
  # （配信キー・タイトル・チャンネル名を含み得る）。要求した識別子と、応答の識別子が違えば id_mismatch（他の配信・ストリームの情報を返さない）。
  module Responses
    # 配信キー（streamName）の形（印字できる ASCII。空白・改行を含まない）
    STREAM_KEY_PATTERN = /\A[\x21-\x7E]{1,256}\z/
    # 設定の問題（configurationIssues）のうち、警告にする重大度
    ERROR_SEVERITY = "error".freeze

    class << self
      # 配信の作成の応答 -> 配信の識別子
      def broadcast_id(payload, kind)
        resource = resource!(payload, kind)
        id!(resource["id"], kind)
      end

      # 未開始の配信の一覧 -> UnstartedBroadcast の配列。items が無い・空なら空
      def unstarted_broadcasts(payload, kind)
        items(payload, kind).map do |item|
          item = resource!(item, kind)
          snippet = item["snippet"].is_a?(Hash) ? item["snippet"] : {}
          UnstartedBroadcast.new(
            youtube_broadcast_id: id!(item["id"], kind),
            title: snippet["title"].is_a?(String) ? snippet["title"] : nil,
            scheduled_start_time: time_or_nil!(snippet["scheduledStartTime"], kind)
          )
        end
      end

      # 紐づけの応答。要求した配信の識別子と同じであること
      def bound_broadcast!(payload, kind, requested_id)
        resource = resource!(payload, kind)
        matched!(resource["id"], requested_id, kind)
        nil
      end

      # 配信の一覧（id 指定）の応答 -> YouTubeStatus。空なら「存在しない」
      def status(payload, kind, requested_id)
        item = items(payload, kind).first
        return YouTubeStatus.not_found if item.nil?

        item = resource!(item, kind)
        matched!(item["id"], requested_id, kind)
        value = item.dig("status", "lifeCycleStatus") if item["status"].is_a?(Hash)
        raise unexpected(kind, :missing_life_cycle_status) unless value.is_a?(String)

        YouTubeStatus.from_life_cycle_status(value)
      rescue ArgumentError
        raise unexpected(kind, :unknown_life_cycle_status)
      end

      # ストリームの一覧（id 指定）の応答 -> ストリームのリソース。空なら nil。識別子が要求と違えば id_mismatch
      def stream_item(payload, kind, requested_id)
        item = items(payload, kind).first
        return nil if item.nil?

        item = resource!(item, kind)
        matched!(item["id"], requested_id, kind)
        item
      end

      # ストリームのリソース -> StreamInfo。取り込み先は rtmpsIngestionAddress（平文の ingestionAddress・バックアップは使わない）で、
      # 返す前に IngestDestination.validate!（RTMPS・YouTube の取り込み口・443）。配信キーを検査する。
      def stream_info(resource, kind, created:, environment:)
        resource = resource!(resource, kind)
        ingestion = resource.dig("cdn", "ingestionInfo") if resource["cdn"].is_a?(Hash)
        raise unexpected(kind, :missing_ingestion_info) unless ingestion.is_a?(Hash)

        url = ingestion["rtmpsIngestionAddress"]
        raise unexpected(kind, :missing_ingestion_address) unless url.is_a?(String) && !url.empty?

        key = ingestion["streamName"]
        raise unexpected(kind, :invalid_stream_key) unless key.is_a?(String) && STREAM_KEY_PATTERN.match?(key)

        StreamInfo.new(
          stream_id: id!(resource["id"], kind), ingest_url: IngestDestination.validate!(url, environment: environment), stream_key: key, created: created
        )
      end

      # ストリームの一覧（id 指定）の応答 -> StreamHealth。ストリームが無ければ NotFound。healthStatus が無ければ noData（情報が無い）
      def stream_health(payload, kind, requested_id)
        item = stream_item(payload, kind, requested_id)
        raise YouTubeErrors::NotFound.new(call_kind: kind, reason: "liveStreamNotFound") if item.nil?

        health = item.dig("status", "healthStatus") if item["status"].is_a?(Hash)
        return StreamHealth.new(status: "noData", error_types: []) unless health.is_a?(Hash)

        status = health["status"]
        raise unexpected(kind, :unknown_health_status) unless StreamHealth::STATUSES.include?(status)

        StreamHealth.new(status: status, error_types: error_types(health["configurationIssues"]))
      end

      # チャンネルの一覧の応答 -> チャンネル名。チャンネルが無ければ nil
      def channel_title(payload, kind)
        item = items(payload, kind).first
        return nil if item.nil?

        snippet = resource!(item, kind)["snippet"]
        title = snippet["title"] if snippet.is_a?(Hash)
        raise unexpected(kind, :missing_channel_title) unless title.is_a?(String)

        title
      end

      private

      def resource!(value, kind)
        raise unexpected(kind, :unexpected_shape) unless value.is_a?(Hash)

        value
      end

      # 一覧の応答の items（無ければ空）。形が違えば UnexpectedResponse
      def items(payload, kind)
        resource!(payload, kind)
        items = payload["items"]
        return [] if items.nil?
        raise unexpected(kind, :unexpected_shape) unless items.is_a?(Array)

        items
      end

      def id!(value, kind)
        raise unexpected(kind, :missing_id) unless value.is_a?(String) && !value.empty?
        raise unexpected(kind, :invalid_id) unless Requests::ID_PATTERN.match?(value)

        value
      end

      def matched!(actual, requested, kind)
        raise unexpected(kind, :id_mismatch) unless id!(actual, kind) == requested
      end

      def time_or_nil!(value, kind)
        return nil if value.nil?
        raise unexpected(kind, :invalid_scheduled_start_time) unless value.is_a?(String)

        Time.iso8601(value)
      rescue ArgumentError
        raise unexpected(kind, :invalid_scheduled_start_time)
      end

      # severity が error の設定の問題の type
      def error_types(issues)
        return [] unless issues.is_a?(Array)

        issues.filter_map { |issue| issue["type"] if issue.is_a?(Hash) && issue["severity"] == ERROR_SEVERITY }
      end

      def unexpected(kind, detail)
        YouTubeErrors::UnexpectedResponse.new(call_kind: kind, detail: detail)
      end
    end
  end
end
