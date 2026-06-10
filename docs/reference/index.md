# Reference

The technical reference for Meridian. It is still being built out.

## Planned Sections

- Framework detection - which defaults `init` sets for Marten, Rails, Elixir, Node, and Go
- `deploy.yml` - the configuration format and all available options
- CLI commands - `init`, `server bootstrap`, `setup`, `proxy remove`, `check`, `deploy`, `rollback`, `status`, `logs`, `exec`, `run`, `quadlet`, `accessory`, `secret`
- Quadlet templates - what Meridian generates for you
- Same-host hosting - service-scoped runtime state, shared proxy network, and manifest collision checks
- Hooks and extension points

## Configuration At A Glance

During `init`, Meridian detects frameworks such as Marten and sets framework-specific defaults like `MARTEN_ENV=production`, `RAILS_ENV=production`, `MIX_ENV=prod`, or `NODE_ENV=production`.

```yaml
service: my-app
image: ghcr.io/acme/my-app:latest

servers:
  web:
    hosts:
      - prod-01.example.com
    proxy:
      host: my-app.example.com
      ssl: true
      app_port: 8000

env:
  clear:
    MARTEN_ENV: production
  secret:
    - DATABASE_URL

accessories:
  postgres:
    image: docker.io/library/postgres:18-alpine
    host: prod-01.example.com
    network: my-app.network
    ready:
      cmd: ["pg_isready", "-U", "app"]
```

For a fast introduction, see the [Guide](/guide/).

## Accessory readiness

When an accessory joins the service network (`network: <service>.network`), Meridian treats it as a hard dependency of the app: during `deploy` it will not start the new app color until every co-network accessory passes a readiness probe, so the first requests after a rollout do not fail while rootless Podman's aardvark-dns warms up.

Declare the probe per accessory under `ready:` (exactly one shape):

| Key | Meaning |
| --- | --- |
| `tcp: <port>` or `tcp: [<port>, …]` | TCP connect succeeds on each port (probed from a pinned sidecar on the network). |
| `cmd: [<argv>]` | Command run inside the accessory (`podman exec`) exits 0 — e.g. `["pg_isready", "-U", "app"]`. |
| `http: { path: <path>, port: <port> }` | HTTP GET returns success. |

Optional `timeout` (default 5s), `interval` (default 1s), and `retries` (default 30) bound each probe.

If `ready:` is omitted, Meridian infers a default from the image:

| Image (base name) | Inferred probe |
| --- | --- |
| `postgres` | `cmd: ["pg_isready", "-U", <POSTGRES_USER or "postgres">]` |
| `redis`, `valkey`, `dragonfly`, `keydb` | `tcp: 6379` |
| `mysql`, `mariadb` | `cmd: ["mysqladmin", "ping", "--silent"]` |
| anything else | `tcp` on the first declared `port:` — and if no port is declared, `meridian plan`/`deploy` fails asking you to declare `ready:` explicitly. |

The generated app Quadlet also gains `Wants=`/`After=` on each co-network accessory unit (systemd ordering on reboot or manual start), and `cmd:` accessories get a Podman `HealthCmd=` so `podman inspect` reflects their health. Accessories are not auto-started — start them with `meridian accessory start <name>`; the gate fails fast naming any that are not ready.

## Health check tuning

Under `servers.<role>.proxy.healthcheck`:

| Key | Default | Meaning |
| --- | --- | --- |
| `path` | `/health` | Path the readiness probe requests. |
| `interval` | `2` | Seconds between probe attempts. |
| `timeout` | `5` | Per-probe timeout (seconds). |
| `retries` | `10` | Maximum probe attempts before failing the rollout. |
| `probe_image` | `docker.io/library/alpine:3.21` | Pinned image the sidecar probe runs (must provide `wget`/`nc`). |
| `required_successes` | `3` | Consecutive successful probes required before switching traffic. |
