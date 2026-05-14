# Meridian

Deploy containers to Linux servers over SSH. No Docker, no Kubernetes, no registry required.

Meridian runs your containers as [Podman Quadlets](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html), so they're regular systemd services: they show up in `journalctl`, restart on failure, and run rootless without a daemon. Zero-downtime deploys go through [kamal-proxy](https://github.com/basecamp/kamal-proxy). Images can come from a registry, or you can skip the registry entirely and ship them straight over SSH.

> **Don't run this in production yet.** It works and runs real deploys, but the config format isn't frozen, and breaking changes will land whenever a better shape turns up.

## Why this exists

[Kamal 2.0](https://kamal-deploy.org) is great. It would be the obvious choice if it didn't insist on Docker on every server and a registry for every deploy. Meridian skips both.

Podman rootless is genuinely better for the single-server, small-cluster case: no daemon, no root, and Quadlets give you systemd integration for free. And once you're on Podman, `podman save | ssh | podman load` is a perfectly fine image transfer mechanism. Registries are useful for collaboration, but they're overhead when you're deploying from your laptop to your VPS.

So: Kamal's deployment model, Podman instead of Docker, optional registry. Written in Crystal.

It is explicitly not a Kubernetes replacement. If you need that, you need that.

## Install

Pre-built binaries for Linux x86_64 and ARM64 are on the [releases page](https://github.com/treagod/meridian/releases).

From source:

```bash
git clone https://github.com/treagod/meridian.git
cd meridian
shards install
crystal build src/meridian_cli.cr --release -o meridian
sudo mv meridian /usr/local/bin/
```

You'll need Crystal 1.17+ to build. Target servers need Podman 4.4+ and systemd. For registry-free transfers, you'll also need `zstd` (stream mode) or `rsync` + `skopeo` (incremental mode) on both ends. `meridian server bootstrap` installs the remote side automatically.

## Five minutes from zero to deployed

```bash
meridian server bootstrap --host 1.2.3.4   # provisions a fresh Debian/Ubuntu box
meridian init                              # generates deploy.yml from your project
meridian setup                             # installs kamal-proxy on the servers
meridian check                             # preflight: SSH, Podman, secrets, proxy
meridian deploy
```

`init` tries to be useful: it sniffs out Marten, Rails, Elixir, Go, and Node projects and seeds sensible defaults. Whatever it can't guess, it asks.

## The interesting commands

Most commands do the obvious thing: `status`, `logs`, `exec`, `rollback`. Run `meridian COMMAND --help` for flags. A few are worth explaining.

### `deploy`

Rolling deploy across `servers.web` in batches of `boot.limit`. When a web host finishes, secondary roles (workers, etc.) start releasing in parallel: they don't wait for every web batch to complete. If you've configured a proxy block, each host gets a blue/green swap through kamal-proxy and the active colour is recorded in `~/.config/containers/systemd/.meridian-color`. Without a proxy block, you get a stop/start with brief downtime, which is fine for some things.

### `plan`

Prints exactly what Meridian resolved from your `deploy.yml` (roles, hosts, image, transfer mode, required secrets, hooks, everything) without touching a server. Handy whenever you're editing config. Secret *values* are never printed, only their names.

### `check`

Read-only preflight. SSH reachable? Podman new enough? Lingering on? Quadlet directory writable? Transfer tools installed? Podman secrets present? kamal-proxy running on web hosts? Any failure exits non-zero, so this is the thing to put in CI before `deploy`.

### `quadlet`

Generates the `.container` files locally without contacting any server. Useful for inspecting what Meridian will actually do, and for cases where you want to commit the generated units somewhere for review.

### `secret`

Podman secrets, managed remotely. Names go in `env.secret` in `deploy.yml`, values are set with `meridian secret set NAME` (reads from stdin if you don't pass `--value`).

```bash
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
  workers:
    hosts: [192.168.1.12]
    cmd: bin/sidekiq

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

That's a working config. Everything else is opt-in: `volumes`, `ports`, `accessories`, `transfer`, `files` (upload supporting config to hosts, optionally template-rendered with ECR), `hooks` (run commands on hosts at deploy phases), and `assets` (fingerprinted static asset hosting via a Caddy sidecar on a separate subdomain). Run `meridian init` and read the comments in the generated file. They're the closest thing this project has to reference docs right now.

Two things worth knowing: per-role `image:` overrides the global one (useful when your worker image differs from your web image), and unknown config keys fail fast rather than getting silently ignored. `build:` is reserved but not implemented. There's no `meridian build` yet, so bring your own image.

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

## What's next

The current focus is shaking out config-format mistakes before tagging anything as stable. After that, in rough priority order: a `build:` section, better error messages on the failure paths in `check`, and probably a hosted docs site so the README can stop being a reference manual.

Issues and PRs welcome. For anything non-trivial, please open an issue first. Better to have the design conversation before code gets written.

```bash
git clone https://github.com/treagod/meridian.git
cd meridian
shards install
crystal spec
```

## License

MIT.
