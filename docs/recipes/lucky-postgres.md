# Lucky + Postgres

[Lucky](https://luckyframework.org/) browser app with [Postgres](https://www.postgresql.org/),
migrations before app start, and fingerprinted assets served by Lucky itself. The
image is built locally with Podman and streamed to the host over SSH, so no
registry is needed.

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
      app_port: 8080
      healthcheck:
        path: /health

env:
  clear:
    LUCKY_ENV: production
    APP_DOMAIN: https://app.example.com
    PORT: "8080"
    # config/email.cr exits at boot without it. Move it to env.secret with a
    # real key once the app sends mail.
    SEND_GRID_KEY: unused
  secret:
    - SECRET_KEY_BASE
    - DATABASE_URL

ssh:
  user: deploy
  keys:
    - ~/.ssh/id_ed25519

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

hooks:
  remote:
    before_start:
      - command: >-
          podman run --rm --network=my-app
          -e LUCKY_ENV=production
          -e APP_DOMAIN=https://app.example.com
          -e PORT=8080
          -e SEND_GRID_KEY=unused
          --secret SECRET_KEY_BASE,type=env,target=SECRET_KEY_BASE
          --secret DATABASE_URL,type=env,target=DATABASE_URL
          localhost/my-app:latest /app/bin/tasks db.migrate
```

`PORT` must match `app_port`: Lucky's generated `config/server.cr` binds to
`ENV["PORT"]` in production. The migration hook runs on the host after Postgres
passes its `ready` probe, using the image that was just transferred. It loads the
whole app, so it needs the same environment and secrets as the web container. If
the migration exits nonzero, the deploy stops before traffic switches and the
previous release keeps serving.

See [`env`](/reference/deploy-yml#env), [`transfer`](/reference/deploy-yml#transfer),
[`accessories.<name>.ready`](/reference/deploy-yml#accessory-readiness), and
[`hooks`](/reference/deploy-yml#hooks). Postgres reads its password through the
official image's [`POSTGRES_PASSWORD_FILE`](https://hub.docker.com/_/postgres)
convention, and `DATABASE_URL` points at the accessory's container name on the
service network.

## `Containerfile`

```dockerfile
# --- Shards ---
FROM docker.io/crystallang/crystal:1.21.0-alpine AS shards

WORKDIR /app
COPY shard.yml shard.lock ./
RUN shards install --production

# --- Frontend (API-only apps omit this stage and the public/ copy below) ---
FROM docker.io/oven/bun:1.4-alpine AS frontend

WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile
COPY . .
# package.json runs Lucky's bake script from the installed lucky shard.
COPY --from=shards /app/lib ./lib
RUN bun run prod

# --- Crystal build ---
FROM shards AS build

# Avram pulls in BigDecimal, so the static link needs libgmp.a.
RUN apk add --no-cache gmp-static
COPY . .
# Lucky reads public/bun-manifest.json at compile time, so the assets come first.
COPY --from=frontend /app/public ./public
RUN mkdir -p bin && \
    crystal build --release --static src/start_server.cr -o bin/app && \
    crystal build --release --static tasks.cr -o bin/tasks

# --- Runtime ---
FROM docker.io/library/alpine:3.22

RUN apk add --no-cache ca-certificates tzdata
WORKDIR /app
COPY --from=build /app/bin/app /app/bin/tasks ./bin/
COPY --from=build /app/public ./public

ENV LUCKY_ENV=production
EXPOSE 8080

CMD ["/app/bin/app"]
```

Add a `.containerignore` so local build output never reaches the image:

```text
.meridian
bin
lib
node_modules
public/assets
public/bun-manifest.json
tmp
```

Keep `spec/` in the build context. The generated seed tasks under `tasks/`
require `spec/support/factories`, and `tasks.cr` compiles them.

This follows a Lucky 1.5 browser app, which bundles assets with Bun. API-only
apps have no frontend: drop the `frontend` stage and the `COPY --from=frontend`
line. Apps that still use another asset bundler can keep it. Run its production
build in the frontend stage instead of `bun run prod`, because the manifest must
exist before `crystal build`.

## Lucky Production Snippets

Add an unauthenticated health action. It subclasses `Lucky::Action` directly, so
`Auth::RequireSignIn` or `Api::Auth::RequireAuthToken` never applies to it:

```crystal
# src/actions/health/show.cr
class Health::Show < Lucky::Action
  default_format :plain_text

  get "/health" do
    plain_text "ok"
  end
end
```

Caddy terminates TLS and already redirects HTTP to HTTPS, so leave
`Lucky::ForceSSLHandler` disabled. Meridian's health probe reaches the container
over plain HTTP, and the handler would redirect it. Mark cookies `Secure` in
production instead:

```crystal
# config/cookies.cr, inside Lucky::CookieJar.configure's on_set
cookie.secure(LuckyEnv.production?)
```

## Commands

```bash
podman build -t localhost/my-app:latest -f Containerfile .

# One generated password, stored twice: for Postgres and inside DATABASE_URL.
DB_PASSWORD="$(meridian secret gen MY_APP_DATABASE_PASSWORD --print)"
printf '%s' "$DB_PASSWORD" | meridian secret set MY_APP_DATABASE_PASSWORD
printf 'postgres://my_app:%s@my-app-postgres:5432/my_app' "$DB_PASSWORD" | meridian secret set DATABASE_URL
unset DB_PASSWORD
meridian secret gen SECRET_KEY_BASE --format base64

meridian setup
meridian accessory start my-app-postgres
meridian plan
meridian check
meridian deploy
```

`secret gen` emits hex by default, so the password needs no escaping inside the
URL. `--format base64` matches what `lucky gen.secret_key` produces.
