require "rails_helper"

# YouTube 接続の認可の要求の login_hint（ログイン中の Google の識別子 sub。issue #11。requirements.md 7.2・28.2）を、ログへ出さない。
# 本番では、login_hint は Google へ渡すだけで、このアプリケーションの要求には現れない。開発の疑似の同意画面は、認可の要求のパラメータを
# そのまま受けるので、要求のログ（開始の行・Parameters の行）に、疑似のアカウントの識別子が出る。伏せる対象に加える。
RSpec.describe "ログから除くパラメータ: login_hint" do
  let(:filter) { ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters) }

  it "login_hint は伏せる（文字列のキー・シンボルのキー・入れ子）" do
    filtered = filter.filter(
      { "login_hint" => "dummy-sub-must-not-appear", login_hint: "dummy-sub-must-not-appear", "outer" => { "login_hint" => "dummy-sub-must-not-appear" } }
    )

    expect(filtered["login_hint"]).to eq("[FILTERED]")
    expect(filtered[:login_hint]).to eq("[FILTERED]")
    expect(filtered.dig("outer", "login_hint")).to eq("[FILTERED]")
  end

  it "要求のクエリ文字列の login_hint も伏せる（ログの開始の行に出る形）" do
    request = ActionDispatch::Request.new(
      Rack::MockRequest.env_for("/api/dev/google/connect?scope=dummy-scope&login_hint=dummy-sub-must-not-appear", "action_dispatch.parameter_filter" => Rails.application.config.filter_parameters)
    )

    expect(request.filtered_path).not_to include("dummy-sub-must-not-appear")
    expect(request.filtered_path).to include("scope=dummy-scope")
  end

  it "login や hint だけの名前、ほかの認可の要求のパラメータ（scope・access_type・prompt）は伏せない" do
    values = { "login" => "x", "hint" => "x", "scope" => "x", "access_type" => "x", "prompt" => "x" }

    expect(filter.filter(values)).to eq(values)
  end
end
