# Marten + SQLite + Assets CDN

Small [Marten](https://martenframework.com/) deployment with no database
accessory. [SQLite](https://sqlite.org/) lives on a named Podman volume, while
fingerprinted static assets are published on a separate hostname.

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
        path: /health

env:
  clear:
    MARTEN_ENV: production
    MARTEN_ALLOWED_HOSTS: app.example.com
  secret:
    - MARTEN_SECRET_KEY
ssh:
  user: deploy
  keys:
    - ~/.ssh/id_ed25519

transfer:
  mode: stream

volumes:
  - my-app-data:/app/data

assets:
  host: assets.app.example.com
  command: /app/manage collectassets --fingerprint --no-input
  output_dir: /app/assets
  retain_releases: 2

hooks:
  remote:
    before_start:
      - command: >-
          podman run --rm
          -v my-app-data:/app/data
          -e MARTEN_ENV=production
          -e MARTEN_ALLOWED_HOSTS=app.example.com
          --secret MARTEN_SECRET_KEY,type=env,target=MARTEN_SECRET_KEY
          localhost/my-app:latest /app/manage migrate
```

The migration container mounts the same volume as the web container, so schema
changes are applied to the persistent database before the new app color starts.
See [`volumes`](/reference/deploy-yml#volumes), [`assets`](/reference/deploy-yml#assets),
and [`hooks`](/reference/deploy-yml#hooks). The binary and asset workflow follows
Marten's [deployment](https://martenframework.com/docs/deployment/introduction/)
and [asset handling](https://martenframework.com/docs/assets/introduction/)
guidance. Marten's `config.assets.url` (in the production settings below) must
point at the same host as `assets.host` so fingerprinted URLs resolve to the
generated asset server; see
[CSS `url()` 404s](/guide/troubleshooting#css-url-assets-404-against-the-asset-cdn)
if CSS-referenced files 404.

## `Containerfile`

```dockerfile
FROM crystallang/crystal:1.21.0-alpine AS build

RUN apk --no-cache add sqlite-dev openssl-dev yaml-dev zlib-dev \
    openssl-libs-static yaml-static zlib-static sqlite-static

ENV MARTEN_ENV=production
ENV SKIP_MARTEN_CLI_PRECOMPILATION=true

WORKDIR /app

COPY shard.yml shard.lock ./
RUN shards install --production --skip-postinstall

COPY . .

RUN mkdir -p bin && \
    crystal build src/server.cr -o bin/server --static && \
    crystal build manage.cr -o bin/manage --static

# The web process needs the generated manifest at runtime to resolve
# fingerprinted URLs. The deploy asset builder publishes the same files.
RUN MARTEN_SECRET_KEY=build-only \
    MARTEN_ALLOWED_HOSTS=build.example \
    bin/manage collectassets --fingerprint --no-input

FROM alpine:3.21

RUN apk add --no-cache tzdata

ENV MARTEN_ENV=production

WORKDIR /app
RUN mkdir -p /app/data

COPY --from=build /app/bin/server /app/server
COPY --from=build /app/bin/manage /app/manage
COPY --from=build /app/src/ /app/src/
COPY --from=build /app/assets/ /app/assets/

EXPOSE 8000

CMD ["/app/server"]
```

## Marten Production Snippets

The base database configuration points SQLite at the mounted volume:

```crystal
Marten.configure do |config|
  config.database do |db|
    db.backend = :sqlite
    db.name = Path["/app/data/my-app.db"]
  end
end
```

Production settings load secrets, trust the proxy headers, and map Marten's
asset resolver to Meridian's asset hostname and generated manifest:

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

  config.assets.url = "https://assets.app.example.com/"
  config.assets.manifests = ["src/manifest.json"]

  config.templates.cached = true
  config.sessions.cookie_secure = true
  config.csrf.cookie_secure = true
  config.use_x_forwarded_host = true
  config.use_x_forwarded_port = true
  config.use_x_forwarded_proto = true
end
```

```crystal
class HealthHandler < Marten::Handler
  def get
    respond("ok", content_type: "text/plain")
  end
end
```

```crystal
Marten.routes.draw do
  path "/health", HealthHandler, name: "health"
end
```

## Commands

```bash
podman build -t localhost/my-app:latest .
meridian secret gen MARTEN_SECRET_KEY
meridian setup
meridian plan
meridian check
meridian deploy
```
