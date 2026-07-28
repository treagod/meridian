# Marten + Postgres + Dragonfly + Assets CDN

Full [Marten](https://martenframework.com/) production stack: one web
container, [Postgres](https://www.postgresql.org/), [Dragonfly](https://www.dragonflydb.io/),
migrations before app start, and deploy-managed static assets served from a
separate asset hostname.

## `.meridian/deploy.yml`

```yaml
service: my-app
image: localhost/my-app:latest

servers:
  web:
    hosts:
      - prod-01.example.com
    proxy:
      host: app.example.com
      ssl: true
      app_port: 8000
      healthcheck:
        path: /healthz
        interval: 2
        timeout: 5
        retries: 15
        required_successes: 3
env:
  clear:
    MARTEN_ENV: production
    MARTEN_ALLOWED_HOSTS: app.example.com
    MY_APP_DATABASE_HOST: my-app-postgres
    MY_APP_DATABASE_NAME: my_app
    MY_APP_DATABASE_USER: my_app
    MY_APP_DRAGONFLY_URL: my-app-dragonfly:6379
  secret:
    - MARTEN_SECRET_KEY
    - MY_APP_DATABASE_PASSWORD

ssh:
  user: deploy
  keys:
    - ~/.ssh/id_ed25519

boot:
  limit: 1
  wait: 5

transfer:
  mode: stream

accessories:
  my-app-postgres:
    image: docker.io/library/postgres:18-alpine
    host: prod-01.example.com
    network: my-app.network
    volumes:
      - my-app-pgdata:/var/lib/postgresql
    env:
      clear:
        POSTGRES_DB: my_app
        POSTGRES_USER: my_app
        POSTGRES_PASSWORD_FILE: /run/secrets/MY_APP_DATABASE_PASSWORD
    secrets:
      - MY_APP_DATABASE_PASSWORD
    ready:
      cmd: ["pg_isready", "-q", "-U", "my_app"]

  my-app-dragonfly:
    image: ghcr.io/dragonflydb/dragonfly:v1.39.0
    host: prod-01.example.com
    network: my-app.network
    volumes:
      - my-app-dragonfly:/data
    cmd: dragonfly --logtostderr --cache_mode=true

assets:
  host: assets.my-app.example.com
  command: /app/manage collectassets --fingerprint --no-input
  output_dir: /app/assets
  retain_releases: 2

hooks:
  remote:
    before_start:
      - command: >-
          podman run --rm --network=my-app
          -e MARTEN_ENV=production
          -e MARTEN_ALLOWED_HOSTS=app.example.com
          -e MY_APP_DATABASE_HOST=my-app-postgres
          -e MY_APP_DATABASE_NAME=my_app
          -e MY_APP_DATABASE_USER=my_app
          -e MY_APP_DRAGONFLY_URL=my-app-dragonfly:6379
          --secret MARTEN_SECRET_KEY,type=env,target=MARTEN_SECRET_KEY
          --secret MY_APP_DATABASE_PASSWORD,type=env,target=MY_APP_DATABASE_PASSWORD
          localhost/my-app:latest /app/manage migrate
```

See [`transfer`](/reference/deploy-yml#transfer), [`accessories`](/reference/deploy-yml#accessories),
[`assets`](/reference/deploy-yml#assets), and [`hooks`](/reference/deploy-yml#hooks)
for field details. The image build and generated manifest follow Marten's
[deployment](https://martenframework.com/docs/deployment/introduction/) and
[asset handling](https://martenframework.com/docs/assets/introduction/)
guidance; Postgres consumes the password through the official image's
[`POSTGRES_PASSWORD_FILE`](https://hub.docker.com/_/postgres) convention. Marten's
`config.assets.url` (in the production settings below) must point at the same host
as `assets.host` so fingerprinted URLs resolve to the generated asset server; see
[CSS `url()` 404s](/guide/troubleshooting#css-url-assets-404-against-the-asset-cdn)
if CSS-referenced files 404.

## `Containerfile`

```dockerfile
# --- Stage 1: Crystal build ---
FROM crystallang/crystal:1.21.0-alpine AS build

# Build dependencies for Marten, SQLite dev defaults, and the pg shard.
RUN apk --no-cache add sqlite-dev openssl-dev yaml-dev zlib-dev \
    libpq-dev openssl-libs-static yaml-static zlib-static sqlite-static

ENV MARTEN_ENV=production
ENV SKIP_MARTEN_CLI_PRECOMPILATION=true

WORKDIR /app

COPY shard.yml shard.lock ./
RUN shards install --production --skip-postinstall

COPY . .

# Dynamic linking keeps the build simple when pg/libpq is involved.
RUN mkdir -p bin && \
    crystal build src/server.cr -o bin/server && \
    crystal build manage.cr -o bin/manage

# Build fingerprinted assets with dummy production env values.
RUN MARTEN_SECRET_KEY=build-only \
    MARTEN_ALLOWED_HOSTS=build.example \
    MY_APP_DATABASE_HOST=localhost \
    MY_APP_DATABASE_NAME=build \
    MY_APP_DATABASE_USER=build \
    MY_APP_DATABASE_PASSWORD=build \
    bin/manage collectassets --fingerprint --no-input

# --- Stage 2: Runtime ---
FROM alpine:3.21

WORKDIR /app
RUN apk add --no-cache ca-certificates tzdata openssl yaml libpq libgcc gc pcre2

COPY --from=build /app/bin/server /app/server
COPY --from=build /app/bin/manage /app/manage
COPY --from=build /app/src /app/src
COPY --from=build /app/assets /app/assets
COPY --from=build /app/lib /app/lib

ENV MARTEN_ENV=production
EXPOSE 8000

CMD ["/app/server"]
```

## Marten Production Snippets

Required shards for this recipe:

```yaml
dependencies:
  marten:
    github: martenframework/marten
  pg:
    github: will/crystal-pg
```

```crystal
Marten.configure :production do |config|
  config.debug = false
  config.host = "0.0.0.0"
  config.port = 8000

  config.secret_key = ENV.fetch("MARTEN_SECRET_KEY")
  config.allowed_hosts = ENV.fetch("MARTEN_ALLOWED_HOSTS")
    .split(",")
    .map(&.strip)
    .reject(&.empty?)

  config.database do |db|
    db.backend = :postgresql
    db.host = ENV.fetch("MY_APP_DATABASE_HOST", "")
    db.name = ENV.fetch("MY_APP_DATABASE_NAME", "")
    db.user = ENV.fetch("MY_APP_DATABASE_USER", "")
    db.password = ENV.fetch("MY_APP_DATABASE_PASSWORD", "")
  end

  config.assets.url = "https://assets.my-app.example.com/"
  config.assets.manifests = ["src/manifest.json"]

  config.sessions.cookie_secure = true
  config.sessions.cookie_http_only = true
  config.csrf.cookie_secure = true
  config.csrf.cookie_http_only = true
  config.templates.cached = true

  config.use_x_forwarded_host = true
  config.use_x_forwarded_port = true
  config.use_x_forwarded_proto = true
end
```

Dragonfly speaks the Redis protocol. Read the connection string from
`MY_APP_DRAGONFLY_URL` and use it with any Redis-compatible Crystal client or
session store.

```crystal
class HealthzHandler < Marten::Handler
  def get
    respond("ok", content_type: "text/plain")
  end
end
```

```crystal
Marten.routes.draw do
  path "/healthz", HealthzHandler, name: "healthz"
end
```

## Commands

```bash
podman build -t localhost/my-app:latest -f Containerfile .
meridian secret gen MARTEN_SECRET_KEY
meridian secret gen MY_APP_DATABASE_PASSWORD
meridian setup
meridian accessory start my-app-postgres
meridian accessory start my-app-dragonfly
meridian plan
meridian check
meridian deploy
```
