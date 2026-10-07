# 中継層（Gin）の Dockerfile。段ごとの用途は次のとおり。
#   dev        開発用。Go の道具一式を持つ。docker-compose.yml が target に指定し、ソースをバインドマウントして
#              command で起動する（ホストの UID・GID で動かすため、イメージの中にビルド結果を持たない）
#   build      本番用バイナリのビルド
#   production 本番用（最終段なので、段を指定しなければこの段が使われる。Railway を想定）。
#              GIN_MODE=release。静的リンクのバイナリだけを持ち、一般ユーザー（65532）で動く
FROM golang:1.27-bookworm AS dev
WORKDIR /app

FROM dev AS build
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/relay .

FROM scratch AS production
# RTMPS（TLS）の接続先の証明書を検証するための CA 証明書
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /out/relay /relay
ENV GIN_MODE=release
USER 65532:65532
EXPOSE 3002
ENTRYPOINT ["/relay"]
