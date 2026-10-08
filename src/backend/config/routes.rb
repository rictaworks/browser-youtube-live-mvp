Rails.application.routes.draw do
  # 口の分離（issue #7。requirements.md 6.1・11.9）。
  # 公開側の口（PORT。既定 3001）の経路と、内部側の口（3101）の経路を、ルーティングの制約で分ける。
  # どちらの口でも、上のどれにも当てはまらない要求（反対側の口の経路を含む）は、最後の経路が 404 を返す。
  # 後続の issue が経路を足すときは、必ず、該当する口の制約の中へ書く（spec/requests/listener_isolation_spec.rb が、構造を検査する）。

  # 公開側の口だけで応答する経路: /up・/api・/admin
  constraints(PublicListener.new) do
    # ヘルスチェック。例外なく起動していれば 200、そうでなければ 500 を返す（BFF の確認の対象外）
    get "up" => "rails/health#show", as: :rails_health_check

    # /api: ブラウザが呼ぶ HTTP API（src/contracts/http-api.md）。コントローラは Api::BaseController を継承する
    # （BFF の確認・CSRF の検査・エラーの形）。後続の issue（#8・#11・#12・#16）が、最後の経路より前へ足す
    namespace :api do
      post "usage-events", to: "usage_events#create", as: :usage_events

      # 認証（issue #8）。ログインの開始・コールバックは匿名、ログアウトはログイン済みのみ（コントローラが宣言）
      post "auth/login/start", to: "auth#login_start", as: :auth_login_start
      get "auth/callback", to: "auth#callback", as: :auth_callback
      post "auth/logout", to: "auth#logout", as: :auth_logout

      # YouTube 接続（issue #11）。段階的な認可: 利用者が「YouTube を接続」を操作した時点で、初めて YouTube の権限を要求する。
      # 開始はログイン済みのみ、Google からの戻り先は匿名として受け、セッションとの一致を手続きで確かめる（コントローラが宣言）
      post "youtube/connect/start", to: "youtube#connect_start", as: :youtube_connect_start
      get "youtube/connect/callback", to: "youtube#connect_callback", as: :youtube_connect_callback
      post "youtube/recheck", to: "youtube#recheck", as: :youtube_recheck

      # 疑似の Google の画面（issue #8）。開発・テストのみ。本番では経路を描かない（存在しない /api の経路として 404 not_found）。
      # 疑似を使う環境かどうかは、外部サービスの実装の選択と同じ環境の判定（AppEnvironment#external_services）で決める
      if AppEnvironment.current.external_services == :fake
        get "dev/google/authorize", to: "/dev/google#authorize", as: :dev_google_authorize

        # YouTube 接続の同意画面と選択（issue #11）。FakeGoogleOidc::CONNECT_AUTHORIZE_PATH が指す経路
        get "dev/google/connect", to: "/dev/google_connect#consent", as: :dev_google_connect
        get "dev/google/connect/choose", to: "/dev/google_connect#choose", as: :dev_google_connect_choose
      end

      # 存在しない /api の経路。BFF の確認・CSRF の検査のあと、404 not_found（JSON）
      match "*unmatched", to: "base#route_not_found", via: :all, format: false
    end

    # /admin（管理画面）の経路も、この制約の中へ足す
  end

  # 内部側の口だけで応答する経路: /internal（中継 → アプリケーションの一方向の内部通信。#14 が足す）
  constraints(InternalListener.new) do
  end

  # どの経路にも当てはまらない要求は、404（JSON）。BFF の確認・CSRF の検査を行わない（経路の存在を明かさない）
  match "*unmatched", to: NotFoundApp, via: :all, format: false
end
