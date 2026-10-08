# ストリームの健全性（issue #10。requirements.md 10.3）。YouTubeGateway#fetch_stream_health が返す。
#
#   status         status.healthStatus.status: good・ok・bad・noData
#   error_types    status.healthStatus.configurationIssues のうち severity が error のものの type（gopSizeLong など。符号の形のものだけ。それ以外は unrecognized）
#
# 警告にするのは、status が bad のとき、または severity: error の設定の問題があるときだけ（warning?）。
# noData は「バックエンドに健全性の情報が無い」の意味なので、警告にしない。警告は画面に表示するだけで、配信は継続する（10.3）。
class StreamHealth < Data.define(:status, :error_types)
  STATUSES = %w[ good ok bad noData ].freeze
  BAD_STATUS = "bad".freeze

  def initialize(status:, error_types:)
    raise ArgumentError, "status must be one of #{STATUSES.inspect}" unless STATUSES.include?(status)
    raise ArgumentError, "error_types must be an Array" unless error_types.is_a?(Array)

    super(status: status, error_types: error_types.map { |reason| YouTubeErrors.safe_reason(reason) }.freeze)
  end

  def warning?
    status == BAD_STATUS || !error_types.empty?
  end
end
