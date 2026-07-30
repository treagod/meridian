# Meridian

Deploy containers to Linux servers over SSH. No Docker, no Kubernetes, no registry required.

Meridian runs your containers as [Podman Quadlets](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html), so they end up as ordinary systemd services: they show up in `journalctl`, restart on failure, and run rootless without a daemon. Traffic switches through [kamal-proxy](https://github.com/basecamp/kamal-proxy) with no dropped requests. Images can come from a registry, or you can skip the registry entirely and ship them straight over SSH.

> **Don't run this in production yet.** It works and runs real deploys, but the config format isn't frozen, and breaking changes will land whenever a better shape turns up.

## Why this exists

[Kamal 2.0](https://kamal-deploy.org) is great. It would be the obvious choice if it didn't insist on Docker on every server and a registry for every deploy. Meridian skips both.

Podman rootless is a better fit for the single-server and small-cluster case. There's no daemon to babysit, nothing runs as root, and Quadlets hand you systemd integration for free. Once you're on Podman, `podman save | ssh | podman load` turns out to be a perfectly good image transfer mechanism. Registries earn their keep when a team shares them; they're mostly overhead when you're deploying from a laptop to your own VPS.

So: Kamal's deployment model, Podman instead of Docker, optional registry. Written in Crystal.

It is explicitly not a Kubernetes replacement. If you need that, you need that.

## Install

```bash
curl -fsSL meridian-deploy.dev/install.sh | sh
```

The installer covers Linux on x86_64 and ARM64, verifies the release checksum, and drops the binary in `/usr/local/bin`. macOS builds are on the [releases page](https://github.com/treagod/meridian/releases).

## From source

```bash
git clone https://github.com/treagod/meridian.git
cd meridian
shards install
crystal build src/meridian_cli.cr --release -o meridian
sudo mv meridian /usr/local/bin/
```

Building needs Crystal 1.17+; CI runs on 1.20.2 and 1.21.0, and release binaries are built with 1.21.0. Target servers need Podman 4.4+ and systemd. Registry-free transfers also want `zstd` (stream mode) or `rsync` plus `skopeo` (incremental mode) on both ends — `meridian server bootstrap` installs the remote side for you.

## Five minutes from zero to deployed

```bash
meridian init                              # generates .meridian/deploy.yml from your project
# edit .meridian/deploy.yml: set hosts, ssh.keys, image, and transfer mode
meridian server bootstrap --host 1.2.3.4   # provisions a fresh Debian/Ubuntu box
meridian setup                             # installs the service network, shared proxy network, and kamal-proxy
meridian check                             # preflight: SSH, Podman, secrets, proxy
meridian deploy
```

`init` sniffs out Marten, Rails, Elixir, Go, and Node projects and seeds sensible defaults. Whatever it can't guess, it asks.

## Commands

| Command | What it does |
| --- | --- |
| [`init`](https://meridian-deploy.dev/reference/cli#init) | Generate the `.meridian/` project layout |
| [`server bootstrap`](https://meridian-deploy.dev/reference/cli#server-bootstrap) | Provision a fresh box: packages, deploy user, lingering, SSH keys |
| [`setup`](https://meridian-deploy.dev/reference/cli#setup) | Install the service network and kamal-proxy on web hosts |
| [`check`](https://meridian-deploy.dev/reference/cli#check) | Read-only preflight against every configured host |
| [`plan`](https://meridian-deploy.dev/reference/cli#plan) | Print what Meridian resolved from `deploy.yml`, touching no server |
| [`deploy`](https://meridian-deploy.dev/reference/cli#deploy) | Rolling deploy across all roles |
| [`rollback`](https://meridian-deploy.dev/reference/cli#rollback) | Restore the previous release on proxied web hosts |
| [`status`](https://meridian-deploy.dev/reference/cli#status) / [`logs`](https://meridian-deploy.dev/reference/cli#logs) | Inspect deployed state, stream `journalctl` |
| [`exec`](https://meridian-deploy.dev/reference/cli#exec) / [`run`](https://meridian-deploy.dev/reference/cli#run) | Run a command in the live container, or in a fresh one-off container |
| [`quadlet`](https://meridian-deploy.dev/reference/cli#quadlet) | Generate `.container` files locally for inspection or review |
| [`secret`](https://meridian-deploy.dev/reference/cli#secret-gen) | Manage Podman secrets remotely: `gen`, `set`, `ls`, `rm` |
| [`accessory`](https://meridian-deploy.dev/reference/cli#accessory-start) | Databases, caches, and friends: `start`, `stop`, `logs` |
| [`lock`](https://meridian-deploy.dev/reference/cli#lock-status) | Hold or clear the remote deploy lock: `status`, `acquire`, `release` |
| [`audit`](https://meridian-deploy.dev/reference/cli#audit) | Tail the per-host audit log written by deploys and rollbacks |
| [`proxy remove`](https://meridian-deploy.dev/reference/cli#proxy-remove) | Drop this service's proxy routes and manifest |

`deploy`, `status`, and `logs` take `--role` and `--host` to narrow what they act on. The [CLI reference](https://meridian-deploy.dev/reference/cli) has exact usage, flags, side effects, and exit codes for all of them. Three are worth explaining here.

### deploy

Rolling deploy across `servers.web` in batches of `boot.limit`. Secondary roles start releasing as soon as the first web host finishes, rather than waiting for every batch. With a `proxy` block configured, each host gets a blue/green swap through the shared kamal-proxy and the active colour is recorded under `~/.local/state/meridian/services/<service>/active-color`. Without one, you get a stop/start and a short gap.

Before touching any host, `deploy` takes a remote deploy lock — an atomic `mkdir` on the first web host — and releases it at the end. A second deploy started while the first is running exits non-zero and prints who's holding it.

### rollback

The old container doesn't survive a successful deploy: its unit is stopped and its Quadlet removed. So `rollback` rebuilds the previous release from `~/.local/state/meridian/services/<service>/release-state.json`, regenerating the Quadlet for the recorded image and colour, then starting and health-checking it exactly like a deploy. Traffic moves back only after the health check passes; a failed rollback tears the candidate down and leaves the current release serving.

This needs the previous image to still exist on the host, so **tag every release uniquely**. With a reused tag like `:latest`, the next deploy retags the name and prunes the old image — rollback then refuses rather than quietly serving the wrong code. Only image and colour come from the recorded release; env, volumes, ports, and command always come from your current `deploy.yml`. Rollback covers the proxied web role; secondary roles roll back by deploying the previous image.

### check

Read-only preflight, and the thing to put in CI ahead of `deploy`. Any failure exits non-zero. It verifies:

- SSH reachability, Podman version, lingering, and a writable Quadlet directory
- Transfer tooling and Podman secrets on every host
- kamal-proxy and the shared `meridian-proxy` network on web hosts
- Route and ownership collisions against other Meridian services on the same host
- Local `files:` sources are readable, and for `stream` and `incremental` transfers, that the images exist in *local* Podman storage

`deploy` re-runs the local half of this — images, `files:` sources, accessory readiness, registry credentials — so skipping `check` still fails before any remote change or lock acquisition.

## Image transfer

**Registry pull (default).** Meridian runs `podman login` and `podman pull` on each host. Nothing surprising; a good default when you already have a registry and decent bandwidth.

**`transfer.mode: stream`.** `podman save | zstd | ssh | podman load`. The whole image crosses the wire every deploy, but there's nothing to set up beyond `zstd` on both ends. Best for single-server setups where running a registry isn't worth it.

**`transfer.mode: incremental`.** Exports to a local OCI layout, rsyncs to the host, imports remotely with `skopeo`. The first deploy transfers everything; later ones send only changed layers. This is the one to pick when you redeploy often over a slow link — a Crystal project with one heavy base layer and a thin top layer, say.

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
    # readiness inferred from the image: pg_isready -q
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

That's a working config. Everything else is opt-in: `volumes`, `ports`, `transfer`, `files` (upload supporting config, optionally ECR-templated), `hooks` (run commands on hosts at deploy phases), and `assets` (fingerprinted static assets served by a Caddy sidecar on its own subdomain).

Per-role `image:` overrides the global one, which helps when your worker image differs from your web image. Unknown keys fail fast instead of being silently ignored. `build:` is reserved but not implemented, so bring your own image for now.

The [`deploy.yml` reference](https://meridian-deploy.dev/reference/deploy-yml) has the complete schema, defaults, and validation rules. Two behaviours in it tend to surprise people on a first deploy.

**Health checks run from a probe sidecar.** A small one-shot container (`healthcheck.probe_image`, default `docker.io/library/alpine:3.21`) polls the new container on the proxy network before traffic switches, which is why apps built `FROM scratch` need no shell of their own. The image is pinned rather than floating so a rollout can't stall on a `:latest` pull mid-deploy. On air-gapped hosts, pre-pull it once — `check` fails preflight if it's missing. Traffic switches after `healthcheck.required_successes` consecutive passes (default 3), which absorbs the window where rootless aardvark-dns flips between fresh and stale records.

**Co-network accessories gate the deploy.** Any accessory on the service network becomes a hard dependency: the new app colour won't start until each one answers a readiness probe, so the first requests after a deploy don't 5xx while DNS warms up. Declare it per accessory under `ready:` as `tcp:`, `http:`, or `cmd:`. Omit it and Meridian infers one from the image — `postgres` gets `pg_isready`, `redis`/`valkey`/`dragonfly`/`keydb` get TCP 6379, `mysql`/`mariadb` get `mysqladmin ping`, anything else gets a TCP probe on the first declared port. An unrecognised image with no port fails at `plan` and asks you to be explicit.

## Meridian vs. Kamal 2.0

|                | Kamal 2.0                 | Meridian                       |
| -------------- | ------------------------- | ------------------------------ |
| Runtime        | Docker (required)         | Podman (rootless)              |
| Service mgmt   | Docker restart policies   | systemd via Quadlets           |
| Image transfer | Registry (always)         | Registry, stream, or rsync     |
| Logs           | `docker logs`             | `journalctl`                   |
| Language       | Ruby                      | Crystal                        |
| Proxy          | kamal-proxy               | kamal-proxy                    |

If you're already happy on Kamal, stay on Kamal. The reason to look at Meridian is if Docker or the registry requirement is actively in your way.

## Documentation

Full docs live at [meridian-deploy.dev](https://meridian-deploy.dev).

- [Quickstart](https://meridian-deploy.dev/guide/quickstart) — install through first deploy
- [Concepts](https://meridian-deploy.dev/guide/concepts) — deploy flow, Quadlets, runtime state, blue/green
- [Multi-app hosting](https://meridian-deploy.dev/guide/multi-app) — a second service on a host that already runs one
- [Recipes](https://meridian-deploy.dev/recipes/) — working starters for Marten, Rails, Go, Kemal, and static sites
- [Troubleshooting](https://meridian-deploy.dev/guide/troubleshooting) — failure messages mapped to diagnostic commands
- [CLI reference](https://meridian-deploy.dev/reference/cli) and [`deploy.yml` reference](https://meridian-deploy.dev/reference/deploy-yml)

## Contributing

The current focus is shaking out config-format mistakes before anything gets tagged stable. After that, roughly in order: a `build:` section, better error messages on the failure paths in `check`, and more verified recipes as real deployments exercise them.

Issues and PRs are welcome. For anything non-trivial, open an issue first — better to have the design conversation before the code gets written.

```bash
git clone https://github.com/treagod/meridian.git
cd meridian
shards install
crystal spec
```

### End-to-end tests

Every documented `deploy.yml` block is strictly loaded and used to generate Quadlets in `crystal spec`. The verified recipes go further and deploy for real:

```bash
make e2e-marten            # SQLite volume persistence, assets, and rollback across two tagged releases
make e2e-marten-postgres   # Postgres and Dragonfly accessories, verified through the deployed app
make e2e-rails-postgres    # non-Crystal stack, db:prepare before app start, app-served assets
make e2e-go                # scratch image with no shell, health-checked entirely from the probe sidecar
make e2e-all               # all four, in sequence
```

Each one builds an ephemeral Ubuntu 24.04 VM with [Lima](https://lima-vm.io/), then runs the real bootstrap, secret, proxy setup, check, deploy, migration, and redeploy paths against it. A successful run removes the VM; set `KEEP_VM=1` to keep it and the temporary logs around for inspection. You'll need macOS, Lima 2+, Podman, Crystal, `curl`, `expect`, plus `ssh-keygen` and `nc`.

## License

MIT.
