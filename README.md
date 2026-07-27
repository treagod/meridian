# Meridian

Deploy containers to Linux servers over SSH. No Docker, no Kubernetes, no registry required.

Meridian runs your containers as [Podman Quadlets](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html), so they're regular systemd services: they show up in `journalctl`, restart on failure, and run rootless without a daemon. Zero-downtime deploys go through [kamal-proxy](https://github.com/basecamp/kamal-proxy). Images can come from a registry, or you can skip the registry entirely and ship them straight over SSH. Fingerprinted static assets can be built during the deploy and served on a separate host as part of the same stack.

> **Don't run this in production yet.** It works and runs real deploys, but the config format isn't frozen, and breaking changes will land whenever a better shape turns up.

## Why this exists

[Kamal 2.0](https://kamal-deploy.org) is great. It would be the obvious choice if it didn't insist on Docker on every server and a registry for every deploy. Meridian skips both.

Podman rootless is genuinely better for the single-server, small-cluster case: no daemon, no root, and Quadlets give you systemd integration for free. And once you're on Podman, `podman save | ssh | podman load` is a perfectly fine image transfer mechanism. Registries are useful for collaboration, but they're overhead when you're deploying from your laptop to your VPS.

So: Kamal's deployment model, Podman instead of Docker, optional registry. Written in Crystal.

It is explicitly not a Kubernetes replacement. If you need that, you need that.

## Install

Pre-built binaries for Linux and macOS (x86_64 and ARM64) are on the [releases page](https://github.com/treagod/meridian/releases).

From source:

```bash
git clone https://github.com/treagod/meridian.git
cd meridian
shards install
crystal build src/meridian_cli.cr --release -o meridian
sudo mv meridian /usr/local/bin/
```

You'll need Crystal 1.17+ to build; CI builds and tests on 1.20.2 and 1.21.0, and release binaries are built with 1.21.0. Target servers need Podman 4.4+ and systemd. For registry-free transfers, you'll also need `zstd` (stream mode) or `rsync` + `skopeo` (incremental mode) on both ends. `meridian server bootstrap` installs the remote side automatically.

## Five minutes from zero to deployed

```bash
meridian init                              # generates .meridian/deploy.yml from your project
# edit .meridian/deploy.yml: set hosts, ssh.keys, image, and transfer mode
meridian server bootstrap --host 1.2.3.4   # provisions a fresh Debian/Ubuntu box
meridian setup                             # installs the service network, shared proxy network, and kamal-proxy
meridian check                             # preflight: SSH, Podman, secrets, proxy
meridian deploy
```

`init` tries to be useful: it sniffs out Marten, Rails, Elixir, Go, and Node projects and seeds sensible defaults. Whatever it can't guess, it asks.

## The interesting commands

Most commands do the obvious thing: `status`, `logs`, `exec`. See the [CLI reference](docs/reference/cli.md) for exact usage, flags, side effects, exit codes, and troubleshooting links. A few are worth explaining.

### `deploy`

Rolling deploy across `servers.web` in batches of `boot.limit`. When a web host finishes, secondary roles (workers, etc.) start releasing in parallel: they don't wait for every web batch to complete. If you've configured a proxy block, each host gets a blue/green swap through the shared host-level kamal-proxy and the active colour is recorded under `~/.local/state/meridian/services/<service>/active-color` (with a temporary legacy `.meridian-color` write for older CLIs). Without a proxy block, you get a stop/start with brief downtime, which is fine for some things. `deploy` verifies that `meridian setup` has already materialized the service network before it transfers an image.

Before touching any host, `deploy` acquires a remote deploy lock (an atomic `mkdir` on the first web host) and releases it at the end. A second deploy started while the first is running exits non-zero and prints who holds the lock. See `lock` and `audit` below.

### `rollback`

Restores the previously deployed release on each proxied web host. The old container does not survive a successful deploy (its unit is stopped and its Quadlet file removed), so `rollback` doesn't try to revive it: it reconstructs the release from `~/.local/state/meridian/services/<service>/release-state.json` — regenerating the Quadlet for the previous image and colour, uploading it, starting it, and health-checking it exactly like a deploy. Traffic switches back only after the health check passes; a failed rollback tears the candidate down and leaves the current release serving. After the switch, the rolled-back-from release is stopped, the state files swap current and previous, and the rollback is audit-logged.

Two things to know. Rollback covers the proxied web role only for now; secondary roles are rolled back by deploying the previous image. And it needs the previous release's image to still exist on the host, so use unique image tags per release — with a reused tag like `:latest`, the next deploy retags the name and prunes the old image, and rollback refuses rather than silently restoring the wrong content. Env, volumes, ports, and command come from your current `deploy.yml`; only image and colour come from the recorded release.

Prints exactly what Meridian resolved from your `deploy.yml` (roles, hosts, image, transfer mode, required secrets, hooks, everything) without touching a server. Handy whenever you're editing config. Secret *values* are never printed, only their names.

### `check`

Read-only preflight. SSH reachable? Podman new enough? Lingering on? Quadlet directory writable? Transfer tools installed? Podman secrets present? kamal-proxy and the shared `meridian-proxy` network running on web hosts? Any same-host route or ownership collisions with other Meridian service manifests? Is every local `files:` source readable? For `transfer.mode: stream` and `incremental`, are the selected images present in the *local* Podman storage so the deploy doesn't fail mid-transfer? Any failure exits non-zero, so this is the thing to put in CI before `deploy`. `deploy` itself re-runs the local checks up front — images, `files:` sources, accessory readiness, registry credentials — so users who skip `check` still fail before any remote mutation or lock acquisition.

### Same-host apps

Multiple independent Meridian projects can target the same VPS as long as their `service:` names and proxy hosts/paths do not collide. Meridian keeps per-service runtime state in `~/.local/state/meridian/services/<service>/`, registers a compact manifest there after deploy, and makes `meridian check` compare that manifest against other services on the host. `meridian proxy remove` removes the current service's proxy routes and manifest, but leaves the shared proxy running when other services are still registered unless `--force` is passed.

### `quadlet`

Generates the `.container` files locally without contacting any server. Useful for inspecting what Meridian will actually do, and for cases where you want to commit the generated units somewhere for review.

### `secret`

Podman secrets, managed remotely. Names go in `env.secret` in `deploy.yml`, values are generated with `meridian secret gen NAME` or set explicitly with `meridian secret set NAME` (reads from stdin if you don't pass `--value`). `secret gen` refuses to overwrite an existing remote secret unless you pass `--force`.

```bash
meridian secret gen SECRET_KEY_BASE       # 32 random bytes, hex-encoded
meridian secret gen JWT_SECRET --format base64url
meridian secret gen API_TOKEN --print     # print locally; do not store remotely
meridian secret set DATABASE_URL          # stdin
meridian secret set DATABASE_URL --value 's3cr3t' --role workers
meridian secret ls
meridian secret rm DATABASE_URL
```

### `accessory`

Standalone services that aren't part of your app deploy: databases, caches, that kind of thing. They get their own Quadlet, their own lifecycle.

```bash
meridian accessory start db
meridian accessory logs db
```

### `lock`

`deploy` takes a remote deploy lock automatically, but you can also drive it by hand: hold the lock during a maintenance window, or clear a stale lock left behind by an interrupted deploy. A stale lock is only ever cleared by an explicit `lock release` — never silently — and the release announces who held it.

```bash
meridian lock status                       # is a deploy lock held, and by whom?
meridian lock acquire --message 'db migration'
meridian lock release
```

### `audit`

Deploys, rollbacks, proxy lifecycle, and accessory lifecycle append a concise, line-oriented audit entry to each host they touch (under `~/.local/state/meridian/services/<service>/audit.log`). `meridian audit` tails those entries so you can reconstruct what happened after an incident.

```bash
meridian audit                             # recent entries for every host
meridian audit --host 1.2.3.4 --lines 50
```

## Image transfer

Three options. Pick whichever fits.

**Registry pull (default).** Meridian runs `podman login` and `podman pull` on each host. Standard story, works fine when you have a registry and decent bandwidth.

**`transfer.mode: stream`.** `podman save | zstd | ssh | podman load`. The whole image goes over the wire on every deploy, but there's nothing to set up beyond `zstd` on both ends. Best for single-server setups where you'd rather not run a registry.

**`transfer.mode: incremental`.** Exports the image to a local OCI layout, rsyncs it to the host, imports it remotely with `skopeo`. The first deploy is a full transfer; subsequent deploys send only changed layers. Best when you redeploy often with small changes: Crystal projects with one slow base layer and a thin top layer, for example.

Rough decision tree: registry if you have one and it's fast, `stream` for small simple setups, `incremental` if you're shipping repeatedly across slow links.

## A realistic `deploy.yml`

```yaml
service: myapp
image: registry.example.com/myorg/myapp

servers:
  web:
    hosts: [192.168.1.10, 192.168.1.11]
    proxy:
      app_port: 3000
      host: myapp.example.com
      ssl: true
      healthcheck:
        path: /health
        interval: 2
        timeout: 5
        retries: 10
        probe_image: docker.io/library/alpine:3.21
        required_successes: 3
  workers:
    hosts: [192.168.1.12]
    cmd: bin/sidekiq

accessories:
  postgres:
    image: docker.io/library/postgres:18-alpine
    host: 192.168.1.10
    network: myapp.network
    volumes:
      - myapp-pgdata:/var/lib/postgresql
    env:
      clear:
        POSTGRES_DB: app
        POSTGRES_USER: app
        POSTGRES_PASSWORD_FILE: /run/secrets/POSTGRES_PASSWORD
    secrets:
      - POSTGRES_PASSWORD
    # readiness inferred from the postgres image (pg_isready -q)
  dragonfly:
    image: ghcr.io/dragonflydb/dragonfly:v1.39.0
    host: 192.168.1.10
    network: myapp.network
    ready:
      tcp: 6379

registry:
  server: registry.example.com
  username: deploy
  password: [REGISTRY_PASSWORD]   # env var name

env:
  clear:
    RAILS_ENV: production
    DATABASE_HOST: db.internal
  secret:
    - SECRET_KEY_BASE
    - DATABASE_URL

ssh:
  user: deploy
  port: 22

boot:
  limit: 1
  wait: 10
```

That's a working config. Everything else is opt-in: `volumes`, `ports`, `accessories`, `transfer`, `files` (upload supporting config to hosts, optionally template-rendered with ECR), `hooks` (run commands on hosts at deploy phases), and `assets` (fingerprinted static asset hosting via a Caddy sidecar on a separate subdomain). See the [`deploy.yml` reference](docs/reference/deploy-yml.md) for the complete schema, defaults, and validation rules.

Two things worth knowing: per-role `image:` overrides the global one (useful when your worker image differs from your web image), and unknown config keys fail fast rather than getting silently ignored. `build:` is reserved but not implemented. There's no `meridian build` yet, so bring your own image.

The zero-downtime readiness check runs a small one-shot probe container (`healthcheck.probe_image`, default `docker.io/library/alpine:3.21`) on the proxy network to poll the new container before switching traffic. The image is pinned, not floating, so a rollout can't drift or stall on a `:latest` pull mid-deploy. On registry-free or air-gapped hosts, pre-pull it once (`podman pull docker.io/library/alpine:3.21`) — `meridian check` verifies its presence on each proxied host and fails preflight if it's missing, rather than failing mid-rollout. Override `probe_image` to use a host-local or mirrored image. `healthcheck.required_successes` (default 3) is how many *consecutive* successful probes the new container must answer before traffic switches — it absorbs the brief window where rootless Podman's aardvark-dns flips between fresh and stale just after a container starts.

**Accessory readiness gate.** Any accessory you put on the service network (`network: <service>.network`) becomes a hard dependency of the app: Meridian will not start the new app color until every co-network accessory answers a readiness probe, so the first requests after a deploy don't 5xx with DNS/connection failures while aardvark-dns warms up. Declare the probe per accessory under `ready:` — `tcp: <port>` (or a list), `cmd: [...]` (run inside the accessory), or `http: { path:, port: }`, with optional `timeout`/`interval`/`retries`. If you omit `ready:`, Meridian infers a default from the image (`postgres` → `pg_isready`, `redis`/`valkey`/`dragonfly`/`keydb` → TCP 6379, `mysql`/`mariadb` → `mysqladmin ping`, otherwise a TCP probe on the first declared port); an unknown image with no port fails at `meridian plan`/`deploy` asking you to declare `ready:` explicitly. HTTP/TCP probes use the same pinned temporary probe image as the app health check, so accessories built `FROM scratch` don't need their own shell. The generated app Quadlet also gains `Wants=`/`After=` on each co-network accessory unit (systemd ordering on reboot/manual start), and `cmd:` accessories get a Podman `HealthCmd=` so `podman inspect` reflects their health. Accessories must already be running (`meridian accessory start <name>`); the gate fails fast naming any that aren't ready.

## Meridian vs. Kamal 2.0

|                | Kamal 2.0                 | Meridian                       |
| -------------- | ------------------------- | ------------------------------ |
| Runtime        | Docker (required)         | Podman (rootless)              |
| Service mgmt   | Docker restart policies   | systemd via Quadlets           |
| Image transfer | Registry (always)         | Registry, stream, or rsync     |
| Logs           | `docker logs`             | `journalctl`                   |
| Language       | Ruby                      | Crystal                        |
| Proxy          | kamal-proxy               | kamal-proxy                    |

If you're already happy on Kamal, stay on Kamal. The interesting reason to look at Meridian is if Docker or the registry requirement is actively in your way.

## Testing recipes locally

Recipe YAML is covered by `crystal spec`: every documented `deploy.yml` block is
strictly loaded and used to generate its Quadlets. The verified recipes also
have full local deployment tests:

```bash
make e2e-marten
make e2e-marten-postgres
make e2e-rails-postgres
make e2e-go
```

Each E2E test creates an ephemeral Ubuntu 24.04 VM with
[Lima](https://lima-vm.io/), then runs the real `server bootstrap`, secret,
proxy setup, check, deploy, asset, migration, and redeploy paths. The SQLite
test verifies volume-backed persistence; the Postgres/Dragonfly test also
starts both accessories and verifies database and Dragonfly access through the
deployed app; the Rails test verifies a non-Crystal stack with a Postgres
accessory, `db:prepare` before app start, and fingerprinted assets served from
the app container; the Go test verifies a `scratch` image with no shell, whose
health checks run entirely from Meridian's probe sidecar. The SQLite test
additionally deploys two distinctly tagged releases and verifies that
`meridian rollback` reconstructs and serves the first one again. A successful run removes the VM. Requirements are macOS, Lima 2+,
Podman, Crystal, `curl`, and `expect`, plus the standard `ssh-keygen` and `nc`
command-line tools. Set `KEEP_VM=1` to retain the VM and temporary logs for
inspection.

## What's next

The current focus is shaking out config-format mistakes before tagging anything as stable. After that, in rough priority order: a `build:` section, better error messages on the failure paths in `check`, and more verified recipes as real deployments are exercised.

Issues and PRs welcome. For anything non-trivial, please open an issue first. Better to have the design conversation before code gets written.

```bash
git clone https://github.com/treagod/meridian.git
cd meridian
shards install
crystal spec
```

## License

MIT.
