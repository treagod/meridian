# Meridian

**A Kamal-inspired deployment CLI for Podman, written in Crystal.**

Meridian deploys containerised applications to remote Linux servers over SSH - no Kubernetes, no cloud platform, no Docker daemon. It uses [Podman Quadlets](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) to run containers as native systemd services, and performs zero-downtime blue/green deploys via [kamal-proxy](https://github.com/basecamp/kamal-proxy). Images can be pulled from a registry or transferred directly to servers over SSH with no registry at all.

> **Status:** Early development - not yet production-ready. Architecture and configuration format are subject to change.
> **Implemented:** `server bootstrap`, `init`, `setup` / `proxy remove`, `check`, `deploy`, `status`, `logs`, role-based `exec`, `rollback`, `quadlet`, multi-server rolling blue/green deploy, registry-free stream and incremental transfer, `accessory start|stop|logs`, `secret set|rm|ls`, arbitrary file sync, remote deploy hooks, and deploy-managed static assets via a shared volume, a oneshot builder, and a Caddy sidecar.

---

## Installation

### Binaries

Pre-built binaries for Linux x86_64 and ARM64 are attached to each [GitHub Release](https://github.com/treagod/meridian/releases).

### From source

```bash
git clone https://github.com/treagod/meridian.git
cd meridian
shards install
crystal build src/meridian_cli.cr --release -o meridian
sudo mv meridian /usr/local/bin/
```

---

## Quick start

```bash
# 0. Provision a fresh server (Debian/Ubuntu + Podman + UFW + deploy user)
meridian server bootstrap --host 1.2.3.4

# 1. Generate deploy.yml and .env from your project directory
meridian init

# 2. Install kamal-proxy on your servers
meridian setup

# 3. Verify the hosts are ready
meridian check

# 4. Deploy
meridian deploy
```

---

## Commands

Run `meridian COMMAND --help` for command-specific usage and options.

### `meridian server bootstrap`

Provisions a fresh Debian/Ubuntu server so it is ready for Meridian deploys. Connects as root over SSH (interactive password prompt), installs Podman and rootless helpers, configures UFW for SSH plus `80/tcp` and `443/tcp`, creates the deploy user, installs your SSH public key, configures systemd lingering and subuid/subgid maps, creates `~/.config/containers/systemd/` and `~/.local/share/containers/`, installs transfer dependencies based on `transfer.mode`, then hardens SSH (disables root login and password authentication). The public key is derived from the first path in `ssh.keys` by appending `.pub`; the deploy user defaults to `ssh.user` from `deploy.yml`. If `transfer.mode` is omitted, Meridian prepares the host for registry pulls with no extra transfer packages.

```bash
meridian server bootstrap --host 1.2.3.4
meridian server bootstrap --host 1.2.3.4 --root-user ubuntu --rootless-port-start 443
meridian server bootstrap --host 1.2.3.4 --passwordless-sudo no --enable-auto-updates no
```

**Requires:** a Debian/Ubuntu server reachable as `--root-user` (default `root`) via SSH, and at least one key path in `ssh.keys` with a matching `.pub` file.

### `meridian init`

Detects what it can from the project directory (service name, Git remote, Dockerfile, framework), prompts for the rest, and generates `deploy.yml` and `.env`. Framework detection currently covers Marten, Rails, Elixir, Go, and Node projects, with framework-specific env defaults and healthcheck hints where available. Dockerfile detection is currently informational only; Meridian does not support a `build:` section yet.

```bash
meridian init           # refuses to overwrite an existing deploy.yml
meridian init --force   # regenerates the files
```

### `meridian setup`

Installs kamal-proxy on all web servers as a Quadlet service.

```bash
meridian setup
meridian proxy remove   # stops and removes kamal-proxy
```

### `meridian deploy`

Deploys all hosts in `servers.web` in rolling batches controlled by `boot.limit` and `boot.wait`. As soon as the first web host succeeds, Meridian releases any secondary roles so workers can overlap with later web batches. When `transfer.mode: stream` is configured, Meridian sends the image to each host directly over SSH with `podman save | zstd | ssh | podman load`, so the `registry:` block becomes optional. When `transfer.mode: incremental` is configured, Meridian exports the image to a local OCI layout, rsyncs it to the host, and imports it there with `skopeo`, so repeated deploys send only changed layers. Otherwise it keeps the remote `podman pull` flow. When `servers.web.proxy` is configured, each web host uses a zero-downtime blue/green deploy through kamal-proxy and records the active colour in `~/.config/containers/systemd/.meridian-color`. If no web proxy config is present, Meridian falls back to the older stop/start flow with brief downtime.

```bash
meridian deploy
```

### `meridian status`

Shows the blue/green systemd state for every configured host across all roles.

```bash
meridian status
```

### `meridian plan`

Prints what Meridian resolved from `deploy.yml` - service, image, transfer mode, roles and hosts, proxy settings, required secret names, files, hooks, assets, and accessory summary - without contacting any host. Use it to catch configuration mistakes before deploy. Secret values are never printed, only their names.

```bash
meridian plan
meridian plan --file path/to/deploy.yml
```

### `meridian check`

Runs read-only preflight probes against every configured host before a deploy. It verifies non-interactive SSH connectivity, Podman 4.4 or newer, systemd lingering, a writable rootless Quadlet directory, transfer tools for the configured `transfer.mode`, Podman secrets named in `env.secret`, and a running `kamal-proxy` container on web hosts when proxying is configured. Hosts are checked in batches controlled by `boot.limit`; any failed probe makes the command exit non-zero.

```bash
meridian check
```

If your config lists `env.secret` names, create them first with `meridian secret set`; otherwise `check` will correctly report the missing Podman secrets.

### `meridian logs`

Streams `journalctl` for `myapp-blue.service` and `myapp-green.service`. With `--host`, Meridian tails one host directly. Without it, Meridian tails every configured host and prefixes each line with the hostname.

```bash
meridian logs
meridian logs --host 192.168.1.10
```

### `meridian exec`

Runs a command inside the active blue/green container for a configured role. If the role has multiple hosts, Meridian uses the first host by default; pass `--host` to target another one.

```bash
meridian exec web -- env
meridian exec workers --host 192.168.1.12 -- bash
```

### `meridian quadlet`

Generates the service Quadlet files locally for inspection without touching any server.

```bash
meridian quadlet --color green
```

Given the reference config above, `meridian quadlet --color green` writes these files to `./quadlet-preview/`:

**`myapp-green.container`**
```ini
[Unit]
Description=myapp (green)

[Container]
Image=registry.example.com/myorg/myapp
ContainerName=myapp-green
Network=myapp.network
Environment=RAILS_ENV=production
Environment=DATABASE_HOST=db.internal
Secret=SECRET_KEY_BASE
Secret=DATABASE_URL
Volume=/data/uploads:/app/uploads
PublishPort=8080:8080
```

**`db.container`** (with `network:`, `secrets:`, and `depends_on:` uncommented)
```ini
[Unit]
Description=db
Requires=myapp-green.service
After=myapp-green.service

[Container]
Image=docker.io/library/postgres:16
ContainerName=db
Network=myapp.network
PublishPort=5432:5432
Volume=pgdata:/var/lib/postgresql/data
Environment=POSTGRES_DB=myapp
Secret=DB_TLS_CERT
```

### `meridian rollback`

Switches kamal-proxy back to the inactive colour on every web host when that container still exists, then rewrites `.meridian-color`.

```bash
meridian rollback
```

### `meridian secret`

Creates, removes, and lists Podman secrets on remote hosts. Secrets are referenced by name in `env.secret` and injected into the container at runtime via Quadlet `Secret=` directives. When `--value` is omitted, the value is read from stdin.

```bash
meridian secret set DATABASE_URL            # reads value from stdin
meridian secret set DATABASE_URL --value s3cr3t
meridian secret set DATABASE_URL --role workers
meridian secret ls                          # per-host table of secrets
meridian secret rm DATABASE_URL
```

### `meridian accessory`

Manages standalone accessory services on their configured hosts. `start` uploads the accessory Quadlet and starts the unit, `stop` only stops that accessory unit, and `logs` tails `journalctl` for that unit. Meridian renders accessory `image`, `port`, `volumes`, `env.clear`, `env.secret`, and optional `cmd`.

```bash
meridian accessory start db
meridian accessory logs db
meridian accessory stop db
```

---

## Configuration

Meridian is configured via a single `deploy.yml` in the root of your project. Run `meridian init` to generate one, or start from this reference:

```yaml
# Name of the service (used for systemd unit names and proxy routing)
service: myapp

# Container image to deploy
image: registry.example.com/myorg/myapp

servers:
  web:
    hosts:
      - 192.168.1.10
      - 192.168.1.11
    proxy:
      app_port: 3000
      host: myapp.example.com
      ssl: true
      # path: /app
      healthcheck:
        path: /health
        interval: 2     # seconds between checks
        timeout: 5      # seconds before a check times out
        retries: 10     # attempts before declaring the deploy failed
  workers:
    hosts:
      - 192.168.1.12
    cmd: bin/sidekiq    # overrides the image's default CMD
    # image: ghcr.io/myorg/myapp-worker:latest  # overrides the global image for this role

proxy:
  image: ghcr.io/basecamp/kamal-proxy:latest

# Required for registry-backed deploys only
registry:
  server: registry.example.com
  username: deploy
  password:
    - REGISTRY_PASSWORD   # name of an environment variable

# Optional: transfer images without a registry
# transfer:
#   mode: stream          # "stream" (save/load via SSH) or "incremental" (rsync OCI layout)

volumes:
  - /data/uploads:/app/uploads   # forwarded verbatim to Volume= in the container Quadlet

ports:
  - "8080:8080"                  # forwarded to PublishPort= (useful for non-proxied roles)

env:
  clear:
    RAILS_ENV: production
    DATABASE_HOST: db.internal
  secret:
    - SECRET_KEY_BASE     # generated into .env by `meridian init`; set on hosts with `meridian secret set`
    - DATABASE_URL

ssh:
  user: deploy
  port: 22
  # proxy_jump: bastion.example.com
  # connect_timeout: 10
  # keepalive: true
  # keepalive_interval: 30

boot:
  limit: 1     # deploy to this many hosts at a time
  wait: 10     # seconds between batches

accessories:
  db:
    image: docker.io/library/postgres:16
    host: 192.168.1.20
    port: "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    env:
      clear:
        POSTGRES_DB: myapp
    cmd: postgres -c shared_buffers=256MB
    # network: myapp.network     # attach accessory to the app network (emits Network=)
    # secrets:                   # direct Podman secrets (emits Secret=, independent of env.secret)
    #   - DB_TLS_CERT
    # depends_on: myapp-green.service   # emits Requires= and After= in [Unit]

# Optional: upload supporting config files to remote hosts during deploy
# files:
#   - source: config/Caddyfile.ecr     # local path; .ecr extension is conventional for templates
#     destination: /home/deploy/Caddyfile
#     template: true                   # renders <%= @config.service %> / <%= @config.image %>
#     roles: [web]                     # omit to upload to all roles

# Optional: remote hook commands, executed on each matching host at deploy phases
# hooks:
#   remote:
#     before_start:
#       - command: systemctl --user start --wait myapp-collectassets.service
#         roles: [web]
#       - command: systemctl --user start --wait myapp-migrate.service
#         roles: [web]
#     after_deploy:
#       - command: systemctl --user --no-pager --full status myapp.service

# Optional: publish fingerprinted static assets on a separate subdomain
# Requires proxy: to be configured on the web role.
# assets:
#   host: static.example.com          # subdomain served by the Caddy asset server
#   command: bin/build-assets         # runs inside the app image before the new colour starts
#   output_dir: /app/public/assets    # directory the build command writes into
#   retain_releases: 2                # how many old asset releases to keep (default: 2)
```

## Registry-Free Deployment

Setting `transfer.mode` in `deploy.yml` switches Meridian to registry-free operation - no registry account or credentials needed.

### Stream mode (`mode: stream`)

The image is serialised with `podman save`, compressed with `zstd`, and piped over SSH to `podman load` on the remote host. Meridian checks for `zstd` locally and remotely before starting, logs compressed bytes and elapsed time for each host, and reruns the full pipeline per host. Simple, no extra infrastructure. The full image is transferred on every deploy.

### Incremental mode (`mode: incremental`)

Meridian exports the local image to `/tmp/meridian-oci/<service>` with `skopeo copy`, rsyncs that OCI layout to the host, and imports it on the server with `skopeo copy`. The first deploy transfers the full layout. Later deploys reuse the cached remote OCI directory and typically send only changed layers plus updated metadata, which keeps repeated transfers small.

### Choosing a mode

| Scenario | Recommended mode |
|----------|-----------------|
| Single server, any image size | `stream` |
| Multiple servers, any current deploy | `stream` |
| Repeated deploys with small image changes | `incremental` |
| CI/CD with fast internet and a registry | Registry (default) |
| Layer-only incremental sync | `incremental` |

---

## SSH Configuration

Meridian currently honors `ssh.user`, `ssh.port`, the first path in `ssh.keys`, `ssh.proxy_jump`, `ssh.connect_timeout`, `ssh.keepalive`, and `ssh.keepalive_interval` for deploys, setup, check, logs, exec, rollback, accessory commands, and remote health checks. Unknown config keys are rejected, and `build:` is reserved but not yet supported.

---

## Why Meridian?

[Kamal 2.0](https://kamal-deploy.org) is an excellent deployment tool, but it has two hard dependencies: Docker on every server, and a container registry for every deployment. Meridian removes both.

Running containers as Podman Quadlets means they appear in `journalctl`, restart automatically, and run rootless without a privileged daemon. Skipping the registry means you can deploy from a laptop to a server with nothing but SSH access.

Meridian is a single-server and small-cluster tool. It is not a Kubernetes replacement.

---

## Differences from Kamal 2.0

| Aspect | Kamal 2.0 | Meridian |
|--------|-----------|----------|
| Container runtime | Docker (required) | Podman (rootless) |
| Service management | Docker restart policies | systemd via Quadlets |
| Image transfer | Registry (always required) | Registry or direct SSH |
| Implementation language | Ruby | Crystal |
| Proxy | kamal-proxy | kamal-proxy (same) |
| Logging | `docker logs` | `journalctl` |

---

## Requirements

**On the machine running Meridian:**
- Crystal 1.17 or later (for building from source)
- SSH access to all target servers with key-based authentication
- `zstd` - only for stream transfer mode
- `rsync` and `skopeo` - only for incremental transfer mode

**On each target server:**
- Podman 4.4 or later (Quadlet support)
- systemd
- `zstd` - only for stream transfer mode; `meridian server bootstrap` installs it automatically
- `rsync` and `skopeo` - only for incremental transfer mode; `meridian server bootstrap` installs them automatically

---

## Roadmap

- [x] `meridian init` - detects project settings, prompts for the rest, generates `deploy.yml` and `.env`
- [x] `meridian status` / `meridian logs` / role-based `meridian exec` / `meridian rollback` - operational commands
- [x] `meridian plan` - read-only printout of the resolved deploy intent (roles, hosts, image, transfer mode, proxy, required secrets, hooks, files, assets, accessories)
- [x] `meridian check` - read-only preflight probes for SSH, Podman, lingering, Quadlet paths, transfer tools, secrets, and kamal-proxy state
- [x] `meridian quadlet --color green` - generates Quadlet files locally for inspection
- [x] `meridian deploy` - rolling multi-host deploy via kamal-proxy with registry pulls or per-host stream transfer
- [x] `meridian setup` / `meridian proxy remove` - installs and removes kamal-proxy as a Quadlet service
- [x] Multi-server rolling deploy - respects `boot.limit`, deploys in parallel batches
- [x] Registry-free stream transfer - `podman save | zstd | ssh | podman load`, no registry needed
- [x] Registry-free incremental transfer - OCI layout + rsync, transfers only changed layers
- [x] Accessory service management - databases, caches, and other infrastructure as standalone Quadlet units
- [x] Bootstrap completeness - `server bootstrap` now opens UFW, creates rootless Podman directories, and installs transfer-mode dependencies
- [x] Honest config contract - unknown keys fail fast, SSH config fields are wired through, and unsupported `build:` config is rejected clearly
- [x] Registry authentication - `podman login` runs before `podman pull` when `registry:` is configured; missing env vars abort with a clear error before any SSH work begins; `proxy.data_dir` is now wired into the kamal-proxy Quadlet as a bind-mount volume
- [x] Secret management - `meridian secret set/rm/ls` manages Podman secrets on remote hosts; `Secret=` directives are emitted in app and accessory Quadlets for each `env.secret` name
- [x] Quadlet completeness - app Quadlets support `volumes:` (`Volume=`) and `ports:` (`PublishPort=`) with a `[Unit]` description; accessory Quadlets support `network:` (`Network=`), direct `secrets:` (`Secret=`), and `depends_on:` (`Requires=`/`After=`)
- [x] Per-role images - each server role can declare its own `image:` to override the global image; workers, migration runners, and sidecars can use a different image from the main app
- [x] Arbitrary file sync - `files:` uploads supporting config files (Caddyfile, nginx snippets, env fragments) to remote hosts during deploy, with optional ECR template rendering
- [x] Deploy-managed static assets - `assets:` publishes fingerprinted static assets via a shared Podman volume, a `Type=oneshot` builder container, and a Caddy sidecar on a dedicated subdomain

---

## Contributing

Meridian is in active early development. Contributions, bug reports, and design feedback are welcome via GitHub Issues and Pull Requests.

Please open an issue before starting significant work so we can discuss the approach.

```bash
git clone https://github.com/treagod/meridian.git
cd meridian
shards install
crystal spec
```

---

## License

MIT. See [LICENSE](LICENSE) for details.
