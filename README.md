# Meridian

**A Kamal-inspired deployment CLI for Podman, written in Crystal.**

Meridian deploys containerised applications to remote Linux servers over SSH — no Kubernetes, no cloud platform, no Docker daemon. It uses [Podman Quadlets](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) to run containers as native systemd services, and performs zero-downtime blue/green deploys via [kamal-proxy](https://github.com/basecamp/kamal-proxy). Images can be pulled from a registry or transferred directly to servers over SSH with no registry at all.

> **Status:** Early development — not yet production-ready. Architecture and configuration format are subject to change.
> **Implemented:** `init`, `status`, `logs`, role-based `exec`, `rollback`, `quadlet`, multi-server rolling blue/green deploy, registry-free stream and incremental transfer, `setup` / `proxy remove`, and `accessory start|stop|logs`.

---

## Installation

### Binaries

Pre-built static binaries for Linux x86_64 and ARM64 are attached to each [GitHub Release](https://github.com/yourname/meridian/releases).

### From source

```bash
git clone https://github.com/yourname/meridian.git
cd meridian
shards install
crystal build src/meridian.cr --release -o meridian
sudo mv meridian /usr/local/bin/
```

---

## Quick start

```bash
# 1. Generate deploy.yml and .env from your project directory
meridian init

# 2. Install kamal-proxy on your servers
meridian setup

# 3. Deploy
meridian deploy
```

---

## Commands

Run `meridian COMMAND --help` for command-specific usage and options.

### `meridian init`

Detects what it can from the project directory (service name, Git remote, Dockerfile, framework), prompts for the rest, and generates `deploy.yml` and `.env`.

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

### `meridian rollback`

Switches kamal-proxy back to the inactive colour on every web host when that container still exists, then rewrites `.meridian-color`.

```bash
meridian rollback
```

### `meridian accessory`

Manages standalone accessory services on their configured hosts. `start` uploads the accessory Quadlet and starts the unit, `stop` only stops that accessory unit, and `logs` tails `journalctl` for that unit. Meridian currently renders accessory `image`, `port`, `volumes`, `env.clear`, and optional `cmd`. Secret environment variable injection for accessories is not implemented yet.

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

env:
  clear:
    RAILS_ENV: production
    DATABASE_HOST: db.internal
  secret:
    - SECRET_KEY_BASE     # generated into .env by `meridian init`; runtime injection is not implemented yet
    - DATABASE_URL

ssh:
  user: deploy
  port: 22
  # proxy_jump: bastion.example.com

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
```

---

## Registry-Free Deployment

Setting `transfer.mode` in `deploy.yml` switches Meridian to registry-free operation — no registry account or credentials needed.

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
- Crystal 1.13 or later (for building from source)
- SSH access to all target servers with key-based authentication
- `zstd` — only for stream transfer mode
- `rsync` and `skopeo` — only for incremental transfer mode

**On each target server:**
- Podman 4.4 or later (Quadlet support)
- systemd
- `zstd` — only for stream transfer mode
- `rsync` and `skopeo` — only for incremental transfer mode

---

## Roadmap

- [x] `meridian init` — detects project settings, prompts for the rest, generates `deploy.yml` and `.env`
- [x] `meridian status` / `meridian logs` / role-based `meridian exec` / `meridian rollback` — operational commands
- [x] `meridian quadlet --color green` — generates Quadlet files locally for inspection
- [x] `meridian deploy` — rolling multi-host deploy via kamal-proxy with registry pulls or per-host stream transfer
- [x] `meridian setup` / `meridian proxy remove` — installs and removes kamal-proxy as a Quadlet service
- [x] Multi-server rolling deploy — respects `boot.limit`, deploys in parallel batches
- [x] Registry-free stream transfer — `podman save | zstd | ssh | podman load`, no registry needed
- [x] Registry-free incremental transfer — OCI layout + rsync, transfers only changed layers
- [x] Accessory service management — databases, caches, and other infrastructure as standalone Quadlet units

---

## Contributing

Meridian is in active early development. Contributions, bug reports, and design feedback are welcome via GitHub Issues and Pull Requests.

Please open an issue before starting significant work so we can discuss the approach.

```bash
git clone https://github.com/yourname/meridian.git
cd meridian
shards install
crystal spec
```

---

## License

MIT. See [LICENSE](LICENSE) for details.
