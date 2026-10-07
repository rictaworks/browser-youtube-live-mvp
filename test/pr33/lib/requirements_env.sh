#!/usr/bin/env bash
# requirements.md 29.4（環境変数）の表を解析する。層ごとに必要な環境変数の期待値を、仕様の表から導くための部品。
# common.sh を読み込んだあとに source する。
#
# 表の列: 変数名（バッククォートで囲み、複数は「 / 」で区切る）・用途・層（「・」で区切る）
# 層の名前の対応: アプリケーション → backend、フロントエンド → frontend、中継 → relay

# 「変数名 サービス」を 1 行ずつ出す。同じ変数が複数の層に要る場合は、層の数だけ行が出る
requirements_env_pairs() {
  sed -n '/^### 29\.4 /,/^### 29\.5 /p' "$ROOT_DIR/requirements.md" | awk -F'|' '
    /^\|/ {
      names = $2
      layers = $4
      if (names ~ /変数名/ || names ~ /^[ -]+$/) next
      n = split(names, parts, "/")
      m = split(layers, ls, "・")
      for (i = 1; i <= n; i++) {
        name = parts[i]
        gsub(/[` ]/, "", name)
        if (name == "") next
        for (j = 1; j <= m; j++) {
          layer = ls[j]
          gsub(/^ +| +$/, "", layer)
          if (layer == "アプリケーション") service = "backend"
          else if (layer == "フロントエンド") service = "frontend"
          else if (layer == "中継") service = "relay"
          else service = "UNKNOWN(" layer ")"
          print name, service
        }
      }
    }'
}

# 29.4 の変数名（重複を除く）
requirements_env_names() {
  requirements_env_pairs | awk '{print $1}' | sort -u
}

# 29.4 で、指定したサービスに要る変数名
requirements_env_names_for() {
  requirements_env_pairs | awk -v svc="$1" '$2 == svc {print $1}' | sort -u
}

# docker-compose.yml が参照する変数名（${NAME...} の形）のうち、環境変数として外部から与えるもの
# （HOST_UID・HOST_GID・公開ポートの変数を除く）
compose_referenced_env_names() {
  grep -oE '\$\{[A-Z_][A-Z0-9_]*' "$ROOT_DIR/docker-compose.yml" | sed 's/^\${//' | sort -u |
    grep -vE '^(HOST_UID|HOST_GID|FRONTEND_PORT|BACKEND_PORT|RELAY_PORT)$'
}

# docker-compose.yml が必須とする変数名（${NAME:?...} の形）
compose_required_env_names() {
  grep -oE '\$\{[A-Z_][A-Z0-9_]*:\?' "$ROOT_DIR/docker-compose.yml" | sed -E 's/^\$\{([A-Z0-9_]+):\?/\1/' | sort -u |
    grep -vE '^(HOST_UID|HOST_GID)$'
}

# .env.example の、コメントではない行の変数名
env_example_names() {
  grep -E '^[A-Z_][A-Z0-9_]*=' "$ROOT_DIR/.env.example" | sed 's/=.*//' | sort -u
}
