# `deploy.yml`

`deploy.yml` is Meridian's deployment contract. By default Meridian reads
`.meridian/deploy.yml`; pass `--config PATH` on commands that support alternate
config files.

Meridian parses config strictly. Unknown keys at any supported nesting level
fail before deploy with an `Unknown config key` error; this mirrors
`YAML::Serializable::Strict` and prevents silent no-op configuration.

Use `meridian plan` after editing this file. It loads the same schema and prints
the resolved deploy intent without SSH or registry access.

## Top-Level Keys

| Key | Type | Required / default | Example | Rules |
| --- | --- | --- | --- | --- |
| `service` | `String` | Required | `my-app` | Must start with a letter and contain only letters, digits, hyphens, and underscores. |
| `image` | `String` | Required | `ghcr.io/acme/my-app:latest` | Used by every role unless `servers.<role>.image` overrides it. |
| `build` | `BuildConfig` | Optional, but unsupported | See [build](#build) | Any present `build:` block fails with `Config key build is not yet supported`. |
| `servers` | map of role name to `ServerConfig` | Required, non-empty | `web: { hosts: [...] }` | Role names are user-defined; `assets:` requires `servers.web.proxy`. |
| `proxy` | `ProxyConfig` | Optional | `image: docker.io/basecamp/kamal-proxy:v0.9.2` | Configures the shared host-level kamal-proxy service used by proxied roles. |
| `registry` | `RegistryConfig` | Optional | `server: ghcr.io` | Used before registry pulls when credentials are configured. |
| `env` | `EnvConfig` | Optional | `clear: { MARTEN_ENV: production }` | Applied to app containers and one-off run containers. |
| `ssh` | `SSHConfig` | Optional, default object | `user: deploy` | Controls SSH arguments for remote commands and transfers. |
| `boot` | `BootConfig` | Optional, default object | `limit: 1` | Controls host batching and wait time during deploy. |
| `transfer` | `TransferConfig` | Optional | `mode: stream` | Omit for registry pull; if present, `mode` is required. |
| `accessories` | map of name to `AccessoryConfig` | Optional | `postgres: { image: ... }` | Accessory names become host-side Quadlet/container names. |
| `volumes` | `Array(String)` | Optional, default `[]` | `["data:/app/data"]` | App container `Volume=` entries. |
| `ports` | `Array(String)` | Optional, default `[]` | `["127.0.0.1:9000:9000"]` | App container `PublishPort=` entries. |
| `hooks` | `HooksConfig` | Optional | `pre_deploy: ./scripts/check` | Local hooks run on the operator machine; remote hooks run on selected hosts. |
| `files` | `Array(FileSyncConfig)` | Optional, default `[]` | See [files](#files) | Uploads supporting files, optionally template-rendered. |
| `assets` | `AssetsConfig` | Optional | See [assets](#assets) | Requires `servers.web.proxy`; publishes deploy-managed static assets. |

## `service`

Names every generated app unit, service network, runtime-state directory, and
proxy registration.

```yaml
service: my-app
```

Validation: `service` must match `^[a-zA-Z][a-zA-Z0-9_-]*$`.

## `image`

The default image for every managed role.

```yaml
image: ghcr.io/acme/my-app:latest
```

Roles can override this with `servers.<role>.image`. For `transfer.mode:
stream` or `incremental`, the selected image must exist in local Podman storage;
`meridian check` verifies that before remote mutation.

## `build`

Reserved for future build support. The schema accepts these keys, but any
present `build:` block currently fails validation.

| Key | Type | Required / default | Example | Rules |
| --- | --- | --- | --- | --- |
| `dockerfile` | `String` | Optional, default `Dockerfile` | `Containerfile` | Reserved; not used while `build:` is unsupported. |
| `context` | `String` | Optional, default `.` | `.` | Reserved. |
| `args` | `Hash(String, String)` | Optional, default `{}` | `{ RAILS_ENV: production }` | Reserved. |
| `platform` | `String` | Optional | `linux/arm64` | Reserved. |
| `builder` | `String` | Optional | `podman` | Reserved. |

Do not add `build:` yet. Build the image yourself, push it to a registry, or use
a registry-free transfer mode.

## `servers.<role>`

Each key under `servers:` is a role name. `web` is the conventional proxied role
and is required when `assets:` is configured.

```yaml
servers:
  web:
    hosts:
      - prod-01.example.com
    image: ghcr.io/acme/my-app-web:latest
    proxy:
      host: my-app.example.com
      ssl: true
      app_port: 8000
  workers:
    hosts:
      - prod-01.example.com
    cmd: bin/jobs
```

| Key | Type | Required / default | Example | Rules |
| --- | --- | --- | --- | --- |
| `hosts` | `Array(String)` | Optional, default `[]` | `["prod-01.example.com"]` | Commands have no targets if a role has no hosts. |
| `proxy` | `ServerProxyConfig` | Optional | See [role proxy](#serversroleproxy) | Only supported when `managed: true`. |
| `cmd` | `String` | Optional | `bin/jobs` | Appends a container command for managed roles; forbidden when `managed: false`. |
| `image` | `String` | Optional | `ghcr.io/acme/my-worker:latest` | Overrides top-level `image` for this role. |
| `managed` | `Bool` | Optional, default `true` | `false` | `false` switches to existing-unit compatibility mode. |
| `units` | `Array(String)` | Optional, default `[]` | `["legacy-app.service"]` | Required when `managed: false`; forbidden when `managed: true`. |

Validation: unmanaged roles cannot define `proxy` or `cmd`, and must define at
least one `units` entry.

## `servers.<role>.proxy`

Role-local proxy configuration enables blue/green cutover through kamal-proxy.

```yaml
servers:
  web:
    proxy:
      host: my-app.example.com
      path: /
      ssl: true
      app_port: 8000
      healthcheck:
        path: /health
        required_successes: 3
```

| Key | Type | Required / default | Example | Rules |
| --- | --- | --- | --- | --- |
| `host` | `String` | Optional | `my-app.example.com` | Public hostname registered in kamal-proxy. |
| `ssl` | `Bool` | Optional, default `false` | `true` | Use only after DNS points at the host. |
| `app_port` | `Int32` | Optional, default `3000` | `8000` | Must match the port the app listens on inside the container. |
| `healthcheck` | `HealthcheckConfig` | Optional, default object | See below | Controls readiness before proxy switch. |
| `path` | `String` | Optional | `/admin` | Route path registered in kamal-proxy. |

### `servers.<role>.proxy.healthcheck` {#healthcheck}

The healthcheck runs from a temporary probe container on the `meridian-proxy`
network, not from inside your app image. Configure one app healthcheck path per
proxied role.

| Key | Type | Required / default | Example | Rules |
| --- | --- | --- | --- | --- |
| `path` | `String` | Optional, default `/health` | `/up` | Must return success from the new app container. |
| `interval` | `Int32` | Optional, default `2` | `2` | Seconds between attempts. |
| `timeout` | `Int32` | Optional, default `5` | `5` | Per-attempt timeout in seconds. |
| `retries` | `Int32` | Optional, default `10` | `20` | Maximum attempts before failing rollout. |
| `probe_image` | `String` | Optional, default `docker.io/library/alpine:3.21` | `registry.local/probe:3.21` | Should ship `wget`/`nc` (the probe fails at deploy time otherwise — Meridian does not validate this); useful for mirrors or air-gapped hosts. |
| `required_successes` | `Int32` | Optional, default `3` | `3` | Consecutive successful probes needed before traffic switches. |

For failures, see [Healthcheck timeout](/guide/troubleshooting#healthcheck-timeout).

## `proxy`

Top-level proxy settings configure the shared kamal-proxy Quadlet installed by
`meridian setup`. This block is optional; omit it to use Meridian's built-in
kamal-proxy defaults. Role-level `servers.<role>.proxy` is what enables proxied
deploys and route registration.

```yaml
proxy:
  image: docker.io/basecamp/kamal-proxy:v0.9.2
  http_port: 80
  https_port: 443
  data_dir: /var/lib/kamal-proxy
```

| Key | Type | Required / default | Example | Rules |
| --- | --- | --- | --- | --- |
| `image` | `String` | Optional, runtime default `docker.io/basecamp/kamal-proxy:v0.9.2` | `docker.io/basecamp/kamal-proxy:v0.9.2` | Leave unset to use Meridian's pinned default. |
| `http_port` | `Int32` | Optional, default `80` | `80` | Rootless low-port binding must be enabled on the host. |
| `https_port` | `Int32` | Optional, default `443` | `443` | Same low-port requirement as `http_port`. |
| `data_dir` | `String` | Optional, default `/var/lib/kamal-proxy` | `/var/lib/kamal-proxy` | Mounted into the proxy container for certificate/state data. |

If port binding fails, see [kamal-proxy bind permission denied](/guide/troubleshooting#kamal-proxy-bind-permission-denied-on-port-80).

## `registry`

Registry credentials are used before `podman pull` when registry transfer is
selected or when images need remote pulling.

```yaml
registry:
  server: ghcr.io
  username: deploy
  password:
    - REGISTRY_PASSWORD
```

| Key | Type | Required / default | Example | Rules |
| --- | --- | --- | --- | --- |
| `server` | `String` | Optional | `ghcr.io` | Registry host passed to login. |
| `username` | `String` | Optional | `deploy` | Registry username. |
| `password` | `Array(String)` | Optional, default `[]` | `[REGISTRY_PASSWORD]` | Names environment variables that provide the password value. |

Missing password environment variables fail before SSH begins.

## `env`

Environment variables for app containers and one-off run containers.

```yaml
env:
  clear:
    MARTEN_ENV: production
  secret:
    - SECRET_KEY_BASE
    - DATABASE_URL
```

| Key | Type | Required / default | Example | Rules |
| --- | --- | --- | --- | --- |
| `clear` | `Hash(String, String)` | Optional, default `{}` | `{ MARTEN_ENV: production }` | Written directly into generated Quadlets. |
| `secret` | `Array(String)` | Optional, default `[]` | `[DATABASE_URL]` | Names Podman secrets already present on target hosts. |

Use service-prefixed secret names when multiple apps share one host.

## `ssh`

SSH settings used by remote commands and transfer helpers.

```yaml
ssh:
  user: deploy
  port: 22
  keys:
    - /Users/me/.ssh/id_ed25519
  connect_timeout: 10
  keepalive: true
  keepalive_interval: 30
```

| Key | Type | Required / default | Example | Rules |
| --- | --- | --- | --- | --- |
| `user` | `String` | Optional, default `deploy` | `deploy` | Remote user for SSH. |
| `port` | `Int32` | Optional, default `22` | `22` | SSH port. |
| `keys` | `Array(String)` | Optional, default `[]` | `["/Users/me/.ssh/id_ed25519"]` | First key is used as identity file; paths are expanded with home support. |
| `proxy_jump` | `String` | Optional | `bastion.example.com` | Passed through to SSH as a jump host. |
| `connect_timeout` | `Int32` | Optional, default `10` | `10` | SSH connection timeout in seconds. |
| `keepalive` | `Bool` | Optional, default `true` | `true` | Enables SSH server-alive options. |
| `keepalive_interval` | `Int32` | Optional, default `30` | `30` | Server-alive interval in seconds. |

## `boot`

Controls deploy batching.

```yaml
boot:
  limit: 1
  wait: 10
```

| Key | Type | Required / default | Example | Rules |
| --- | --- | --- | --- | --- |
| `limit` | `Int32` | Optional, default `1` | `1` | Number of hosts released in a batch. |
| `wait` | `Int32` | Optional, default `0` | `10` | Seconds to wait between batches. |

## `transfer`

Controls how the selected image reaches each host.

```yaml
transfer:
  mode: stream
```

| Key | Type | Required / default | Example | Rules |
| --- | --- | --- | --- | --- |
| `mode` | `registry`, `stream`, or `incremental` | Required when `transfer:` is present | `stream` | Unknown modes fail parse; empty mode fails validation. |

Omit `transfer:` for registry pull. `stream` uses `podman save | zstd | ssh |
podman load`; `incremental` exports an OCI layout and syncs changed layers.

## `accessories`

Accessories are independent services such as databases and caches. They get
their own Quadlet and lifecycle commands.

```yaml
accessories:
  postgres:
    image: docker.io/library/postgres:18-alpine
    host: prod-01.example.com
    network: my-app.network          # reachable by container name on this network; no host port
    volumes:
      - my-app-pgdata:/var/lib/postgresql
    env:
      clear:
        POSTGRES_DB: app
        POSTGRES_USER: app
        POSTGRES_PASSWORD_FILE: /run/secrets/MY_APP_POSTGRES_PASSWORD
    secrets:
      - MY_APP_POSTGRES_PASSWORD
    # readiness inferred from the postgres image (pg_isready); override with `ready:` if needed
```

The official Postgres image supports the `_FILE` convention used above, so a
Podman secret can remain mounted at `/run/secrets/...` instead of being exposed
as a Postgres environment variable. See the
[Postgres image documentation](https://hub.docker.com/_/postgres).

| Key | Type | Required / default | Example | Rules |
| --- | --- | --- | --- | --- |
| `image` | `String` | Optional in YAML, required at runtime | `docker.io/library/postgres:18-alpine` | Missing image fails when readiness inference or generation needs it. |
| `host` | `String` | Optional in schema | `prod-01.example.com` | Accessory commands need a target host; declare it explicitly. |
| `port` | `String` | Optional | `"5432:5432"` | Used as published port and for default readiness inference. |
| `volumes` | `Array(String)` | Optional, default `[]` | `["pgdata:/var/lib/postgresql"]` | Accessory `Volume=` entries. |
| `env` | `EnvConfig` | Optional | `clear: { POSTGRES_USER: app }` | Same shape as top-level `env`; official images can consume file-mounted secrets through variables such as `POSTGRES_PASSWORD_FILE`. |
| `cmd` | `String` | Optional | `postgres -c max_connections=200` | Container command for the accessory. |
| `network` | `String` | Optional | `my-app.network` | Put co-dependent accessories on the app service network. |
| `secrets` | `Array(String)` | Optional, default `[]` | `[MY_APP_POSTGRES_PASSWORD]` | Extra Podman secrets for the accessory. |
| `depends_on` | `String` | Optional | `postgres` | Adds systemd ordering between accessories. |
| `ready` | `AccessoryReadinessConfig` | Optional | See below | Explicit readiness probe; otherwise Meridian tries to infer one. |

### `accessories.<name>.ready` {#accessory-readiness}

Readiness must declare exactly one probe shape: `tcp`, `cmd`, or `http`.

| Key | Type | Required / default | Example | Rules |
| --- | --- | --- | --- | --- |
| `tcp` | `Int32` or `Array(Int32)` | One of `tcp`/`cmd`/`http` | `6379` or `[5432, 5433]` | Normalized to a list; each value must be an integer. |
| `cmd` | `Array(String)` | One of `tcp`/`cmd`/`http` | `["pg_isready", "-U", "app"]` | Runs inside the accessory with `podman exec`. |
| `http` | `AccessoryReadinessHTTPConfig` | One of `tcp`/`cmd`/`http` | `{ path: /health, port: 8080 }` | Sidecar HTTP GET. |
| `timeout` | `Int32` | Optional, default `5` | `5` | Per-probe timeout in seconds. |
| `interval` | `Int32` | Optional, default `1` | `1` | Seconds between attempts. |
| `retries` | `Int32` | Optional, default `30` | `30` | Maximum attempts before the gate fails. |

`ready.http` fields:

| Key | Type | Required / default | Example | Rules |
| --- | --- | --- | --- | --- |
| `path` | `String` | Optional, default `/` | `/health` | Request path. |
| `port` | `Int32` | Required | `8080` | Port inside the accessory container. |

If `ready:` is omitted, Meridian infers defaults for common images:

| Image base name | Inferred readiness |
| --- | --- |
| `postgres` | `cmd: ["pg_isready", "-q"]` |
| `redis`, `valkey`, `dragonfly`, `keydb` | `tcp: 6379` |
| `mysql`, `mariadb` | `cmd: ["mysqladmin", "ping", "--silent"]` |
| anything else | `tcp` on the first declared `port`; if no port exists, validation asks for explicit `ready:`. |

The generated app Quadlet gains `Wants=` and `After=` for co-network
accessories. Accessories are not auto-started; run `meridian accessory start
NAME` before the first app deploy.

## `volumes`

App container volume mounts.

```yaml
volumes:
  - my-app-data:/app/data
  - /srv/my-app/config:/app/config:ro
```

| Key | Type | Required / default | Example | Rules |
| --- | --- | --- | --- | --- |
| `volumes` | `Array(String)` | Optional, default `[]` | `my-app-data:/app/data` | Each string is passed through as a Quadlet `Volume=` entry. |

## `ports`

App container host port publications.

```yaml
ports:
  - "127.0.0.1:9000:9000"
```

| Key | Type | Required / default | Example | Rules |
| --- | --- | --- | --- | --- |
| `ports` | `Array(String)` | Optional, default `[]` | `"127.0.0.1:9000:9000"` | Each string is passed through as a Quadlet `PublishPort=` entry. |

## `hooks`

Hooks run extra commands at deploy boundaries.

```yaml
hooks:
  pre_deploy: ./scripts/preflight
  post_deploy: ./scripts/notify
  remote:
    before_start:
      - command: bin/manage migrate
        roles: [web]
```

| Key | Type | Required / default | Example | Rules |
| --- | --- | --- | --- | --- |
| `pre_deploy` | `String` | Optional | `./scripts/preflight` | Runs locally before deploy starts. |
| `post_deploy` | `String` | Optional | `./scripts/notify` | Runs locally after deploy finishes. |
| `remote` | `RemoteHooksConfig` | Optional | See below | Runs on remote hosts during deploy phases. |

Remote phases under `hooks.remote`:

| Phase | Type | Default | When it runs |
| --- | --- | --- | --- |
| `before_transfer` | `Array(RemoteHookConfig)` | `[]` | Before image transfer. |
| `after_transfer` | `Array(RemoteHookConfig)` | `[]` | After image transfer. |
| `after_upload` | `Array(RemoteHookConfig)` | `[]` | After Quadlets/files/assets upload. |
| `before_start` | `Array(RemoteHookConfig)` | `[]` | After co-network accessories are ready and before asset build/app start. |
| `after_start` | `Array(RemoteHookConfig)` | `[]` | After starting the new unit. |
| `before_switch` | `Array(RemoteHookConfig)` | `[]` | Before kamal-proxy switches traffic. |
| `after_switch` | `Array(RemoteHookConfig)` | `[]` | After kamal-proxy switches traffic. |
| `after_deploy` | `Array(RemoteHookConfig)` | `[]` | After deploy state is recorded. |

Each remote hook entry has:

| Key | Type | Required / default | Example | Rules |
| --- | --- | --- | --- | --- |
| `command` | `String` | Required | `bin/manage migrate` | Command executed remotely. |
| `roles` | `Array(String)` | Optional | `[web]` | Limits the hook to selected roles. |

## `files`

Uploads host-side files during deploy.

```yaml
files:
  - source: deploy/Caddyfile.ecr
    destination: /home/deploy/Caddyfile
    template: true
    roles: [web]
```

| Key | Type | Required / default | Example | Rules |
| --- | --- | --- | --- | --- |
| `source` | `String` | Required | `deploy/Caddyfile.ecr` | Local file path. |
| `destination` | `String` | Required | `/home/deploy/Caddyfile` | Remote path. |
| `template` | `Bool` | Optional, default `false` | `true` | Render with ECR before upload. |
| `roles` | `Array(String)` | Optional | `[web]` | Limit upload to selected roles. |

## `assets`

Deploy-managed static assets published on a separate host.

```yaml
assets:
  host: assets.my-app.example.com
  command: bin/manage collectassets --fingerprint --no-input
  output_dir: /app/assets
  retain_releases: 2
```

| Key | Type | Required / default | Example | Rules |
| --- | --- | --- | --- | --- |
| `host` | `String` | Required | `assets.my-app.example.com` | Must resolve to the server before HTTPS issuance. |
| `command` | `String` | Required | `bin/manage collectassets --fingerprint --no-input` | Runs in an app-image one-shot unit. |
| `output_dir` | `String` | Required | `/app/assets` | Directory copied into the asset release volume. |
| `retain_releases` | `Int32` | Optional, default `2` | `2` | Number of old asset releases kept. |

Validation: `assets:` requires `servers.web.proxy` because the asset server is
published through the proxied web host.
