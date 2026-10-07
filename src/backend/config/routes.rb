Rails.application.routes.draw do
  # ヘルスチェック（公開側）。例外なく起動していれば 200、そうでなければ 500 を返す
  get "up" => "rails/health#show", as: :rails_health_check
end
