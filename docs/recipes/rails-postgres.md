# Rails + Postgres

Status: draft example awaiting maintainer verification.

Classic [Rails](https://rubyonrails.org/) + [Postgres](https://www.postgresql.org/)
deployment without Docker on the server. The target host runs rootless Podman
Quadlets, and the image is transferred over SSH.

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
        path: /up

env:
  clear:
    RAILS_ENV: production
    RAILS_LOG_TO_STDOUT: "true"
    MY_APP_DATABASE_HOST: my-app-postgres
    MY_APP_DATABASE_NAME: my_app
    MY_APP_DATABASE_USER: my_app
  secret:
    - MY_APP_DATABASE_PASSWORD
    - MY_APP_SECRET_KEY_BASE

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
    volumes:
      - my-app-pgdata:/var/lib/postgresql
    env:
      clear:
        POSTGRES_DB: my_app
        POSTGRES_USER: my_app
        POSTGRES_PASSWORD_FILE: /run/secrets/MY_APP_DATABASE_PASSWORD
    network: my-app.network
    secrets:
      - MY_APP_DATABASE_PASSWORD

hooks:
  remote:
    before_start:
      - command: >-
          podman run --rm --network=my-app
          -e RAILS_ENV=production
          -e MY_APP_DATABASE_HOST=my-app-postgres
          -e MY_APP_DATABASE_NAME=my_app
          -e MY_APP_DATABASE_USER=my_app
          --secret MY_APP_DATABASE_PASSWORD,type=env,target=MY_APP_DATABASE_PASSWORD
          --secret MY_APP_SECRET_KEY_BASE,type=env,target=MY_APP_SECRET_KEY_BASE
          ghcr.io/example/my-app:latest bin/rails db:prepare
```

See [`env`](/reference/deploy-yml#env), [`transfer`](/reference/deploy-yml#transfer),
[`accessories.<name>.ready`](/reference/deploy-yml#accessory-readiness), and
[`hooks`](/reference/deploy-yml#hooks). The environment mapping follows the
[Rails configuration guide](https://guides.rubyonrails.org/configuring.html),
while Postgres reads its Podman secret through the official image's
[`POSTGRES_PASSWORD_FILE`](https://hub.docker.com/_/postgres) convention.

This recipe serves precompiled assets from the app container. To publish
fingerprinted assets on a separate host during the deploy instead, add an
[`assets`](/reference/deploy-yml#assets) block and point Rails's `config.asset_host`
at the same host as `assets.host`.

## `Containerfile`

```dockerfile
FROM ruby:3.3-alpine AS build

WORKDIR /app
RUN apk add --no-cache build-base git libpq-dev nodejs yarn

COPY Gemfile Gemfile.lock ./
RUN bundle config set without development test
RUN bundle install

COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile

COPY . .
RUN SECRET_KEY_BASE_DUMMY=1 RAILS_ENV=production bundle exec rails assets:precompile

FROM ruby:3.3-alpine

WORKDIR /app
RUN apk add --no-cache libpq tzdata

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app

ENV RAILS_ENV=production
EXPOSE 3000

CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0", "-p", "3000"]
```

## Rails Production Snippets

Map the service-prefixed environment variables explicitly:

```yaml
# config/database.yml
production:
  adapter: postgresql
  encoding: unicode
  host: <%= ENV.fetch("MY_APP_DATABASE_HOST") %>
  database: <%= ENV.fetch("MY_APP_DATABASE_NAME") %>
  username: <%= ENV.fetch("MY_APP_DATABASE_USER") %>
  password: <%= ENV.fetch("MY_APP_DATABASE_PASSWORD") %>
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", 5) %>
```

```ruby
# config/environments/production.rb
Rails.application.configure do
  config.secret_key_base = ENV.fetch("MY_APP_SECRET_KEY_BASE")
end
```

```ruby
# config/routes.rb
Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check
end
```

## Commands

```bash
podman build -t ghcr.io/example/my-app:latest .
meridian secret gen MY_APP_DATABASE_PASSWORD
meridian secret gen MY_APP_SECRET_KEY_BASE
meridian setup
meridian accessory start my-app-postgres
meridian plan
meridian check
meridian deploy
```
