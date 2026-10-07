require "rails_helper"

RSpec.describe "GET /up", type: :request do
  it "ヘルスチェックに 200 を返す" do
    get "/up"

    expect(response).to have_http_status(:ok)
  end
end
