class YouTubeGateway
  # YouTube への呼び出しの、閉じた表（issue #10。requirements.md 8.4・6.1）。窓口のすべての HTTP 呼び出しは、この表の 1 行に当たる。
  #
  #   kind         窓口の呼び出しの種別（YouTubeGateway#call の method:。例外の call_kind。失敗の注入の対象）
  #   api_method   台帳の明細の呼び出しの種別（YouTube の API のメソッド名）
  #   cost_key     単価の出どころ（契約 limits.json の quota.unit_costs のキー）。単価は、コードに数値で直書きしない
  #   http_method  :get・:post・:delete
  #   path         API の基底の URL からの相対パス
  #   buckets      支出できる枠。配信に属する呼び出しは :prep（準備・確認枠）か :settle（終了・清算枠）、属さない呼び出しは :common（共通枠）
  #
  # :settle を使えるのは、終了・清算の用途（状態確認・完了への遷移・削除）だけ。ほかの呼び出しは、終了・清算枠を取り崩せない
  # （8.4「終了・清算枠は、他の用途で取り崩さない」）。先行配信の清算（10.5）は、準備・確認枠から支出する。
  # 枠が 2 つある呼び出しは、用途で決まるので、呼び出し側が指定する（省略できない）。枠が 1 つの呼び出しは、省略するとその枠。
  # この表を変えるときは、スペック（youtube_gateway_calls_spec.rb）と、requirements.md 8.4 の支出表を、あわせて見直す。
  module Calls
    Spec = Data.define(:kind, :api_method, :cost_key, :http_method, :path, :buckets) do
      def initialize(kind:, api_method:, cost_key:, http_method:, path:, buckets:)
        raise ArgumentError, "buckets must be a non-empty subset of #{BUCKETS.inspect}" unless buckets.is_a?(Array) && !buckets.empty? && (buckets - BUCKETS).empty?
        raise ArgumentError, "the common bucket cannot be combined with another bucket" if buckets.include?(:common) && buckets != [ :common ]

        super(kind: kind, api_method: api_method, cost_key: cost_key, http_method: http_method, path: path, buckets: buckets.dup.freeze)
      end

      # 単価（ユニット）。契約 limits.json の quota.unit_costs
      def units
        Contract::Limits::QUOTA.fetch("unit_costs").fetch(cost_key)
      end

      # 配信に属さない呼び出し（共通枠）
      def common?
        buckets == [ :common ]
      end

      # 呼び出し側が指定した枠（シンボル。省略は nil）を、この呼び出しで使える枠に確定する。使えない枠・枠が 2 つあるのに省略は ArgumentError
      def resolve_bucket(requested)
        if requested.nil?
          return buckets.first if buckets.size == 1

          raise ArgumentError, "bucket is required for #{kind} (one of #{buckets.inspect})"
        end
        return requested if requested.is_a?(Symbol) && buckets.include?(requested)

        raise ArgumentError, "bucket must be one of #{buckets.inspect} for #{kind}"
      end
    end

    BUCKETS = %i[ prep settle common ].freeze

    TABLE = {
      insert_broadcast: Spec.new(kind: :insert_broadcast, api_method: "liveBroadcasts.insert", cost_key: "insert", http_method: :post, path: "liveBroadcasts", buckets: %i[ prep ]),
      list_unstarted_broadcasts: Spec.new(kind: :list_unstarted_broadcasts, api_method: "liveBroadcasts.list", cost_key: "list", http_method: :get, path: "liveBroadcasts", buckets: %i[ prep ]),
      check_stream: Spec.new(kind: :check_stream, api_method: "liveStreams.list", cost_key: "list", http_method: :get, path: "liveStreams", buckets: %i[ prep ]),
      create_stream: Spec.new(kind: :create_stream, api_method: "liveStreams.insert", cost_key: "insert", http_method: :post, path: "liveStreams", buckets: %i[ prep ]),
      bind: Spec.new(kind: :bind, api_method: "liveBroadcasts.bind", cost_key: "bind", http_method: :post, path: "liveBroadcasts/bind", buckets: %i[ prep ]),
      fetch_status: Spec.new(kind: :fetch_status, api_method: "liveBroadcasts.list", cost_key: "list", http_method: :get, path: "liveBroadcasts", buckets: %i[ prep settle ]),
      fetch_stream_health: Spec.new(kind: :fetch_stream_health, api_method: "liveStreams.list", cost_key: "list", http_method: :get, path: "liveStreams", buckets: %i[ prep ]),
      complete: Spec.new(kind: :complete, api_method: "liveBroadcasts.transition", cost_key: "transition", http_method: :post, path: "liveBroadcasts/transition", buckets: %i[ prep settle ]),
      delete: Spec.new(kind: :delete, api_method: "liveBroadcasts.delete", cost_key: "delete", http_method: :delete, path: "liveBroadcasts", buckets: %i[ prep settle ]),
      probe_channel_lookup: Spec.new(kind: :probe_channel_lookup, api_method: "channels.list", cost_key: "list", http_method: :get, path: "channels", buckets: %i[ common ]),
      probe_live_enabled: Spec.new(kind: :probe_live_enabled, api_method: "liveBroadcasts.list", cost_key: "list", http_method: :get, path: "liveBroadcasts", buckets: %i[ common ])
    }.freeze

    # 種別の行。表に無い種別は KeyError（黙って別の呼び出しにしない）
    def self.fetch(kind)
      TABLE.fetch(kind)
    end
  end
end
