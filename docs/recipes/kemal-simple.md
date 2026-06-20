# Simple Kemal App

Status: draft example awaiting maintainer verification.

Small [Crystal](https://crystal-lang.org/)/[Kemal](https://kemalcr.com/) app
with no database or accessory service. `meridian init` does not currently
auto-detect Kemal projects, so this recipe starts from a hand-written
`.meridian/deploy.yml`.

## `.meridian/deploy.yml`

```yaml
service: my-app
image: ghcr.io/example/my-app:latest

servers:
  web:
    hosts:
      - prod-01.example.com
    proxy:
      host: app.example.com
      ssl: true
      app_port: 3000
      healthcheck:
        path: /health

env:
  clear:
    KEMAL_ENV: production

ssh:
  user: deploy
  keys:
    - ~/.ssh/id_ed25519

transfer:
  mode: stream
```

See [`servers.<role>`](/reference/deploy-yml#serversrole),
[`servers.<role>.proxy.healthcheck`](/reference/deploy-yml#healthcheck), and
[`transfer`](/reference/deploy-yml#transfer).

## `Containerfile`

```dockerfile
FROM crystallang/crystal:1.19-alpine AS build

WORKDIR /app
RUN apk add --no-cache shards openssl-dev yaml-dev zlib-dev

COPY shard.yml shard.lock ./
RUN shards install --production

COPY . .
RUN crystal build src/server.cr --release -o /out/my-app

FROM alpine:3.21

WORKDIR /app
RUN apk add --no-cache ca-certificates openssl yaml libgcc

COPY --from=build /out/my-app /app/my-app

ENV KEMAL_ENV=production
EXPOSE 3000

CMD ["/app/my-app"]
```

## Kemal Snippet

Use one cheap app health endpoint for Meridian's proxy switch. You can expose
additional routes such as `/ready` for humans or monitoring, but `deploy.yml`
selects one `servers.web.proxy.healthcheck.path`.

```crystal
require "kemal"

get "/health" do
  "ok"
end

Kemal.config.port = 3000
Kemal.run
```

The Kemal app only needs to expose `/health`. During deploy, Meridian runs the
temporary probe container on `meridian-proxy.network` and calls that endpoint.

## Commands

```bash
podman build -t ghcr.io/example/my-app:latest .
meridian setup
meridian plan
meridian check
meridian deploy
```
