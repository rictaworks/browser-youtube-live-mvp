# ログの出力を捕捉する補助（issue #7）。「ログに機密・IP が出ない」ことを、実際の出力で確かめるために使う。
#
# Rails.logger は ActiveSupport::BroadcastLogger で、Action Controller・Active Record のログも、同じ出力先へ流れる。
# 捕捉のための出力先を、ブロックの間だけ足す（既存の出力先は、そのまま）。
#
#   output = capture_logs { get "/api/state" }
module LogCapture
  # ブロックの実行中に、Rails のログへ出た内容（すべてのレベル）を、文字列で返す
  def capture_logs
    io = StringIO.new
    sink = ::Logger.new(io, level: ::Logger::DEBUG)
    Rails.logger.broadcast_to(sink)
    begin
      yield
    ensure
      Rails.logger.stop_broadcasting_to(sink)
    end
    io.string
  end
end

RSpec.configure do |config|
  config.include LogCapture
end
