# Third-Party Distroless Image

Status: draft (pending a re-verification deploy).

Third-party app recipe using an upstream image and registry pull. This example
uses [Vikunja](https://vikunja.io/) with [Postgres](https://www.postgresql.org/);
there is no local `Containerfile`.

::: warning Third-party env names can't be service-prefixed
Meridian injects each `env.secret` value as an environment variable of the **same
name** (`--secret NAME,type=env,target=NAME`). A third-party image reads the
variable names *it* defines — here Vikunja requires `VIKUNJA_SERVICE_SECRET` and
`VIKUNJA_DATABASE_PASSWORD` — so those secrets must be named exactly that, not
`MY_APP_*`. The per-service prefix convention (see the
[multi-app guide](/guide/multi-app)) applies to secrets *you* name; it cannot
apply to names the upstream app hard-codes. Verify the full Vikunja env contract
(service secret, public URL, database name/user/password) against the
[Vikunja config docs](https://vikunja.io/docs/config-options/) before treating
this recipe as verified.
:::

## `.meridian/deploy.yml`

```yaml
service: my-app
image: docker.io/vikunja/vikunja:2.3.0   # pin the tag; upstream renames break behaviour

servers:
  web:
    hosts:
      - prod-01.example.com
    proxy:
      host: app.example.com
      ssl: true
      app_port: 3456
      healthcheck:
        path: /api/v1/info
        interval: 2
        timeout: 5
        retries: 20

env:
  clear:
    VIKUNJA_SERVICE_PUBLICURL: https://app.example.com/
    VIKUNJA_DATABASE_TYPE: postgres
    VIKUNJA_DATABASE_HOST: my-app-postgres
    VIKUNJA_DATABASE_USER: my_app
    VIKUNJA_DATABASE_DATABASE: my_app
  secret:
    - VIKUNJA_SERVICE_SECRET        # Vikunja's own env var name — required, no prefix
    - VIKUNJA_DATABASE_PASSWORD

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
        POSTGRES_PASSWORD_FILE: /run/secrets/VIKUNJA_DATABASE_PASSWORD
    secrets:
      - VIKUNJA_DATABASE_PASSWORD
    # readiness inferred from the postgres image (pg_isready)
```

Omit `transfer:` to pull from the registry. See [`image`](/reference/deploy-yml#image),
[`registry`](/reference/deploy-yml#registry), and
[`accessories.<name>.ready`](/reference/deploy-yml#accessory-readiness).

## Upstream Image

```text
docker.io/vikunja/vikunja:2.3.0
```

## Commands

```bash
meridian secret gen VIKUNJA_SERVICE_SECRET
meridian secret gen VIKUNJA_DATABASE_PASSWORD
meridian setup
meridian accessory start my-app-postgres
meridian plan
meridian check
meridian deploy
```
