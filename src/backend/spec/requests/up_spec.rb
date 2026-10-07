require "rails_helper"
require "support/api_helpers"

# ヘルスチェック（公開側の口だけ。BFF の確認の対象外）。
# テストでは puma.socket が無いので、待ち受けの口は、env で明示する（ListenerPort。黙って公開側と見なさない）。
RSpec.describe "GET /up", type: :request do
  include ApiHelpers

  it "ヘルスチェックに 200 を返す" do
    get "/up", env: public_listener_env

    expect(response).to have_http_status(:ok)
  end

  it "X-BFF-Secret が無くても 200（ヘルスチェックは、BFF の確認の対象外）" do
    get "/up", env: public_listener_env

    expect(request.headers["X-BFF-Secret"]).to be_nil
    expect(response).to have_http_status(:ok)
  end

  # テストの環境は、ホストを制限しない（Rack::Test の Host は www.example.com）。/up がホストの検査の対象外であることは、
  # 本番・開発の一覧での動作を、spec/config/allowed_hosts_spec.rb と、実サーバーの確認（この issue の test/ 配下）が確かめる
  it "Host が 127.0.0.1 でも 200（コンテナのヘルスチェック）" do
    get "/up", headers: { "Host" => "127.0.0.1:3001" }, env: public_listener_env

    expect(response).to have_http_status(:ok)
  end
end
