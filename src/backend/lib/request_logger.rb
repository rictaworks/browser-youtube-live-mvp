# 要求の開始のログ。Rails 標準の Rails::Rack::Logger の代わり（config/initializers/request_pipeline.rb。issue #7）。
#
# 標準は、"Started GET "/path" for 203.0.113.5 at ..." と、利用者の IP（request.remote_ip）を、要求のたびにログへ出す。
# IP は、頻度制限の計数にだけ使い、ログへ記録しない（requirements.md 28.2）。そこで、IP を出さない形にする。
# request.remote_ip を呼ばないので、X-Forwarded-For と Client-IP の食い違いによる IpSpoofAttackError も、起こさない。
# 経路のクエリは、request.filtered_path で、config.filter_parameters に従って伏せる（認可コード・state・チケットなど）。
#
# ログの時刻は、ログの出力のためで、業務の判定には使わない。
class RequestLogger < Rails::Rack::Logger
  private

  # Started GET "/api/state" at 2026-10-07 13:30:00 +0900
  def started_request_message(request)
    format('Started %s "%s" at %s', request.raw_request_method, request.filtered_path, Time.now)
  end
end
