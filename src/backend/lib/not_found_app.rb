# どの経路にも当てはまらない要求への 404（Rack の部品）。config/routes.rb の最後の経路が、これを呼ぶ。
# 反対側の口の経路（内部側の口への /api・/admin・/up、公開側の口への /internal）も、ここへ来る。
#
# BFF の確認・CSRF の検査を行わない。経路の存在を明かさないため、要求の内容（秘密値の有無・ログイン）によらず、同じ応答を返す。
# 本文に、要求の経路を含めない。
class NotFoundApp
  def self.call(_env)
    ApiErrorBody.rack_response(404, "not_found")
  end
end
