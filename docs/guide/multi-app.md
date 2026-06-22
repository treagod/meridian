# Hosting Multiple Apps On One Server

This tutorial adds a second Meridian app to a server that already runs one app.
The goal is one small VPS, one shared kamal-proxy, and separate state for each
service.

Start state:

- `my-app` already serves `https://app.example.com` on `prod-01.example.com`.
- `meridian setup`, `meridian check`, and `meridian deploy` have already
  completed for `my-app`.
- The server has one shared `kamal-proxy.container` and `meridian-proxy.network`.

End state:

- `my-blog` serves `https://blog.example.com` on the same host.
- `my-blog` owns its own `my-blog.network`.
- Optional accessories are named and networked so they cannot collide with
  `my-app`.

## Topology

Both apps share the public proxy network, but each app keeps its private service
network and runtime state.

```text
                           public HTTP(S)
                                |
                                v
                         kamal-proxy.container
                                |
                         meridian-proxy.network
                         /                    \
              my-app-green               my-blog-blue
                   |                           |
            my-app.network              my-blog.network
                   |                           |
          my-app-postgres          my-blog-postgres
```

The important rule: `meridian-proxy.network` is shared host infrastructure.
`<service>.network` is private to one app and its accessories.

## Existing App

`my-app` has its own project directory and its own `.meridian/deploy.yml`.
Service-prefixed secret names and accessory names make the host state obvious.

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
      app_port: 8000
      healthcheck:
        path: /health

env:
  clear:
    MARTEN_ENV: production
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
    # readiness inferred from the postgres image (pg_isready)
```

Notice the names:

- `service: my-app` owns `~/.local/state/meridian/services/my-app/`.
- The accessory is `my-app-postgres`, not `postgres`.
- Secrets are `MY_APP_*`, not generic names such as `DATABASE_PASSWORD`.
- The accessory joins `my-app.network`, not `meridian-proxy.network`.

## Add The Second App

Create a separate project directory for `my-blog`. Do not reuse the first app's
`.meridian/deploy.yml`; each service owns one config and one runtime-state
directory.

```yaml
service: my-blog
image: ghcr.io/example/my-blog:latest

servers:
  web:
    hosts:
      - prod-01.example.com
    proxy:
      host: blog.example.com
      ssl: true
      app_port: 3000
      healthcheck:
        path: /up

env:
  clear:
    NODE_ENV: production
    MY_BLOG_DATABASE_HOST: my-blog-postgres
    MY_BLOG_DATABASE_NAME: my_blog
    MY_BLOG_DATABASE_USER: my_blog
  secret:
    - MY_BLOG_DATABASE_PASSWORD
    - MY_BLOG_SESSION_SECRET

ssh:
  user: deploy
  keys:
    - ~/.ssh/id_ed25519

accessories:
  my-blog-postgres:
    image: docker.io/library/postgres:18-alpine
    host: prod-01.example.com
    network: my-blog.network
    volumes:
      - my-blog-pgdata:/var/lib/postgresql
    env:
      clear:
        POSTGRES_DB: my_blog
        POSTGRES_USER: my_blog
        POSTGRES_PASSWORD_FILE: /run/secrets/MY_BLOG_DATABASE_PASSWORD
    secrets:
      - MY_BLOG_DATABASE_PASSWORD
    # readiness inferred from the postgres image (pg_isready)
```

The second app follows the same convention with `MY_BLOG_*`,
`my-blog-postgres`, and `my-blog.network`.

Neither database publishes a host port: each app reaches its own Postgres by
container name on its private `<service>.network`, so there's nothing to
collide on. Only add `port:` if you genuinely need to reach a database from the
host (e.g. an external admin tool) — and then give each service a distinct host
port (`5432:5432` for one, `15432:5432` for another) to avoid clashes.

## Point DNS First

Before deploying the second app, point the new hostnames at the same server.

```bash
dig +short app.example.com
dig +short blog.example.com
```

Both should resolve to `prod-01.example.com` or its public IP. If you also
configure `assets.host`, point that hostname before deploying with `ssl: true`.

## Prepare Secrets And Setup

Run these commands from the `my-blog` project directory.

```bash
meridian secret gen MY_BLOG_SESSION_SECRET
meridian secret gen MY_BLOG_DATABASE_PASSWORD
meridian setup
```

`secret gen` and `secret set` default to the `web` role, which is enough here
because the example accessory and web app are on the same host. For a different
role, pass `--role ROLE`.

This does not create a second proxy. It uploads or refreshes the shared
`meridian-proxy.network`, the service's private `my-blog.network`, and
`kamal-proxy.container`, starts the service network, ensures the proxy is
running, and lets this service register routes during deploy.

## Start Accessories

Start the database after `setup` has uploaded and started `my-blog.network`.

```bash
meridian accessory start my-blog-postgres
```

## Check For Collisions

Run the preflight check before deploying.

```bash
meridian check
```

The `manifest-collisions` probe compares the new `my-blog` config against
service manifests already present on the host:

```text
~/.local/state/meridian/services/
  my-app/
    manifest.json
    audit.log
  my-blog/
    manifest.json
    audit.log
```

Each `manifest.json` records what a service owns: proxy host/path, asset host,
published ports, accessory names, generated files, and service-state paths.
`meridian check` fails before deploy if `my-blog` tries to claim something
already owned by `my-app`.

Useful inspection commands:

```bash
ssh deploy@prod-01.example.com 'find ~/.local/state/meridian/services -maxdepth 2 -name manifest.json -print'
ssh deploy@prod-01.example.com 'cat ~/.local/state/meridian/services/my-app/manifest.json'
```

If `meridian check` reports `manifest-collisions: fail`, fix the second app's
config first. Change the proxy host/path, accessory name, asset host, published
host port, or service name until the collision disappears. See the
[troubleshooting entry](/guide/troubleshooting#manifest-collisions-fail) for the
diagnostic flow.

## Deploy The Second App

Once DNS, secrets, accessories, and checks are ready:

```bash
meridian deploy
meridian status --host prod-01.example.com
```

`my-app` and `my-blog` now have independent release state:

```text
~/.local/state/meridian/services/my-app/
  active-color
  release-state.json
  manifest.json
  audit.log

~/.local/state/meridian/services/my-blog/
  active-color
  release-state.json
  manifest.json
  audit.log
```

A deploy for `my-blog` should not mutate `my-app` state. It only registers or
updates `my-blog` routes on the shared proxy.

## Read The Audit Logs

Each service has its own `audit.log`, so incident review starts by checking the
service that changed.

```bash
meridian audit --host prod-01.example.com --lines 50
ssh deploy@prod-01.example.com 'tail -n 20 ~/.local/state/meridian/services/my-blog/audit.log'
ssh deploy@prod-01.example.com 'tail -n 20 ~/.local/state/meridian/services/my-app/audit.log'
```

Look for recent `deploy`, `rollback`, `proxy`, `accessory`, and `lock` entries.
If one app appears affected after another app's deploy, compare both audit logs
and then inspect both manifests.

## Removing One App

Run this from the app directory you want to remove from the proxy.

```bash
meridian proxy remove
```

For `my-blog`, this removes only `my-blog` routes and its manifest. If
`my-app` is still registered on the host, Meridian leaves the shared
kamal-proxy running.

Use `--force` only when you intentionally want to remove the shared proxy even
though other service manifests still exist:

```bash
meridian proxy remove --force
```

That is a destructive host-level action. It can interrupt other Meridian apps on
the same server.

## What Does Not Work

- Two services cannot claim the same `servers.<role>.proxy.host`.
- Two services cannot claim the same `servers.<role>.proxy.host` plus
  `servers.<role>.proxy.path`.
- Two accessories on the same host cannot use the same accessory name, because
  the accessory name becomes the Quadlet and container name.
- Two accessories cannot publish the same host port with
  `accessories.<name>.port`.
- Two services should not share generic secret names such as
  `DATABASE_PASSWORD`; use service-prefixed names so rotations are obvious.

## Checklist

Before deploying the second app:

- [ ] `service:` is unique.
- [ ] Proxy host/path is unique.
- [ ] DNS points at the server.
- [ ] Secrets are service-prefixed.
- [ ] Accessory names are service-prefixed.
- [ ] Accessories use `network: <service>.network`.
- [ ] Published accessory host ports do not collide.
- [ ] `meridian check` passes.
