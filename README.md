# Meridian

**A Kamal-inspired deployment CLI for Podman, written in Crystal.**

Meridian deploys containerised applications to remote Linux servers over SSH — no Kubernetes, no cloud platform, no Docker daemon. It uses [Podman Quadlets](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) to run containers as native systemd services, and performs zero-downtime blue/green deploys via [kamal-proxy](https://github.com/basecamp/kamal-proxy). Images can be pulled from a registry or transferred directly to servers over SSH with no registry at all.

> **Status:** Early development — not yet production-ready. Architecture and configuration format are subject to change.
> **Implemented:** `init`, `config`, `exec --host`, `healthcheck`, `quadlet`, multi-server rolling blue/green deploy, `setup` / `proxy remove`.
> Registry-free transfer and operational commands are still planned.

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

Commands marked *(planned)* are not yet implemented.

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

Deploys all hosts in `servers.web` in rolling batches controlled by `boot.limit` and `boot.wait`. As soon as the first web host succeeds, Meridian releases any secondary roles so workers can overlap with later web batches. When `servers.web.proxy` is configured, each web host uses a zero-downtime blue/green deploy through kamal-proxy and records the active colour in `~/.config/containers/systemd/.meridian-color`. If no web proxy config is present, Meridian falls back to the older stop/start flow with brief downtime.

```bash
meridian deploy
```

### `meridian config`

Validates and pretty-prints the parsed `deploy.yml`.

```bash
meridian config
meridian config --file path/to/other.yml
```

### `meridian rollback` *(planned)*

Switches kamal-proxy back to the previous container if it is still present.

### `meridian status` / `meridian logs` / `meridian exec` *(planned)*

```bash
meridian status
meridian logs
meridian logs --host 192.168.1.10
meridian exec web -- bash
```

### Accessories *(planned)*

```bash
meridian accessory start db
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
    - SECRET_KEY_BASE     # read from environment at deploy time
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
      secret:
        - POSTGRES_PASSWORD
```

---

## Registry-Free Deployment

Setting `transfer.mode` in `deploy.yml` switches Meridian to registry-free operation — no registry account or credentials needed.

### Stream mode (`mode: stream`)

The image is serialised with `podman save`, compressed with `zstd`, and piped over SSH to `podman load` on the remote host. Simple, no extra infrastructure. The full image is transferred on every deploy.

### Incremental mode (`mode: incremental`)

Meridian exports the image to an OCI layout directory and rsyncs only the changed layers to each server. For a typical application update where only the top layer changes, this reduces a 500 MB transfer to approximately 5–10 MB. Requires `rsync` on the deploy machine and `skopeo` on each server.

### Choosing a mode

| Scenario | Recommended mode |
|----------|-----------------|
| Single server, any image size | `stream` |
| Multiple servers, first deploy | `stream` |
| Multiple servers, repeated deploys | `incremental` |
| Large images (>1 GB) with frequent updates | `incremental` |
| CI/CD with fast internet and a registry | Registry (default) |

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
- `skopeo` — only for incremental transfer mode

---

## Roadmap

- [x] `meridian init` — detects project settings, prompts for the rest, generates `deploy.yml` and `.env`
- [x] `meridian config` — validates and pretty-prints the parsed configuration
- [x] `meridian exec --host … -- <cmd>` — runs a command on a remote host over SSH
- [x] `meridian healthcheck --url …` — polls an HTTP endpoint until it returns 200
- [x] `meridian quadlet --color green` — generates Quadlet files locally for inspection
- [x] `meridian deploy` — rolling multi-host deploy via kamal-proxy when `servers.web.proxy` is configured
- [x] `meridian setup` / `meridian proxy remove` — installs and removes kamal-proxy as a Quadlet service
- [x] Multi-server rolling deploy — respects `boot.limit`, deploys in parallel batches
- [ ] Registry-free stream transfer — `podman save | zstd | ssh | podman load`, no registry needed
- [ ] Registry-free incremental transfer — OCI layout + rsync, transfers only changed layers
- [ ] `meridian status` / `meridian logs` / `meridian rollback` — operational commands
- [ ] Accessory service management — databases, caches, and other infrastructure as Quadlet units

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
