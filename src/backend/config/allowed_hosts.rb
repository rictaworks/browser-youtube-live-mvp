# ホストの許可（config.hosts）。DNS rebinding の防止（requirements.md 6.1・28.1）。
# 環境ごとの一覧を持つ。素の Ruby（Rails に依存しない）。config/application.rb が読み込み、spec が一覧を直接検査する。
#
#   開発    localhost（ブラウザから）・backend（docker compose の他のコンテナ。frontend・relay がサービス名で呼ぶ）
#   本番    *.up.railway.app（Railway の公開ドメイン）・*.railway.internal（プライベートネットワーク。中継が内部通信で呼ぶ）
#   テスト  制限しない（Rack::Test の Host は www.example.com）。一覧の動作は、spec が環境ごとの一覧で検査する
#
# Rails のホストの指定で、先頭が "." の文字列は、そのドメインと、その下のすべてのサブドメインに一致する。
#
# 注意（転送ヘッダとの関係）: Rails の HostAuthorization は、Host ヘッダだけでなく、X-Forwarded-Host も、許可の一覧と照合する。
# BFF（フロントエンド）が付ける X-Forwarded-Host は、フロントエンドの公開ドメイン（この一覧に無い）なので、そのままでは、
# 本番のすべての要求が 403 になる。そのため、転送ヘッダを env から取り除く ForwardedHeaders を、ミドルウェアの先頭に置く
# （lib/forwarded_headers.rb。config/initializers/request_pipeline.rb）。
module AllowedHosts
  DEVELOPMENT = %w[ localhost backend ].freeze
  PRODUCTION = %w[ .up.railway.app .railway.internal ].freeze
  TEST = [].freeze

  BY_ENVIRONMENT = {
    development: DEVELOPMENT,
    production: PRODUCTION,
    test: TEST
  }.freeze

  # ヘルスチェックは、ホストの検査の対象外（コンテナ内の 127.0.0.1・Railway のヘルスチェックの Host を、一覧に入れない）
  HEALTH_CHECK_PATH = "/up".freeze

  # 環境の名前（シンボルまたは文字列）の、許可するホストの一覧。未知の名前は、既定の環境へ倒さず、例外にする
  def self.for(name)
    BY_ENVIRONMENT.fetch(name.to_s.to_sym) do
      raise ArgumentError, "unknown environment (expected one of: #{BY_ENVIRONMENT.keys.join(', ')})"
    end
  end

  def self.health_check?(request)
    request.path == HEALTH_CHECK_PATH
  end
end
