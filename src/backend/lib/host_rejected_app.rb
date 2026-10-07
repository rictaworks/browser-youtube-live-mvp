# 許可されていないホストの要求への応答（ActionDispatch::HostAuthorization の response_app。config/application.rb）。
# Rails 標準の応答は、開発では HTML のデバッグ画面になるため、契約のエラーの形（403 forbidden の JSON）にする。
# 本文に、拒否した Host を含めない（手がかりを書かない）。ログには、原因をたどれるよう、拒否した Host を残す。
class HostRejectedApp
  # ログへ出す Host の長さの上限（攻撃者が選べる値のため、切り詰める）
  LOG_LIMIT = 100

  def self.call(env)
    blocked = env["action_dispatch.blocked_hosts"] || [ env["HTTP_HOST"] ]
    Rails.logger.error("[host_authorization] blocked host=#{describe(blocked)}")
    ApiErrorBody.rack_response(403, "forbidden")
  end

  # inspect で、改行・制御文字をエスケープして 1 行にし、長さを切り詰める（ログの行の偽造を防ぐ）
  def self.describe(hosts)
    Array(hosts).map { |host| host.to_s.inspect[0, LOG_LIMIT] }.join(", ")
  end
  private_class_method :describe
end
