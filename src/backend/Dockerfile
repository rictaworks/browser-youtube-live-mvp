# アプリケーション層（Rails）の開発用イメージ。
# ソース・gem（vendor/bundle）・ログはバインドマウントして使い、イメージには入れない。
# コンテナはホストの UID・GID で動く（docker-compose.yml の user）。
FROM ruby:3.4-slim

# build-essential・libpq-dev・libyaml-dev・pkg-config  ネイティブ拡張を持つ gem（pg・psych）のビルド
# postgresql-client   schema_format :sql が使う pg_dump・psql。サーバー（postgres:17）と同じ版
# git                 bundler-audit が脆弱性の DB を取得する
# curl                healthcheck
# apt のキャッシュ（/var/lib/apt/lists）は削除しない（CLAUDE.md の削除系コマンドの禁止）。イメージは少し大きくなる
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends \
      build-essential \
      curl \
      git \
      libpq-dev \
      libyaml-dev \
      pkg-config \
      postgresql-client

WORKDIR /app
