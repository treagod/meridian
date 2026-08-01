# Quickstart

From an empty server to a running app. No Kubernetes, no CI pipeline, no registry.

Steps 1-3 are the same everywhere. Step 4 provisions a **fresh host**; if this
server already runs another Meridian service, skip it and start at step 5.

## 1. Install

```bash
curl -fsSL https://meridian-deploy.dev/install.sh | sh
```

The installer covers Linux on x86_64 and ARM64, verifies the release checksum,
and drops the binary in `/usr/local/bin`.

macOS builds, and any install you would rather do by hand, come from the
[releases page](https://github.com/treagod/meridian/releases) - grab the binary
for your platform and put it on your `PATH`:

```bash
sudo mv meridian /usr/local/bin/
meridian --version
```

If you build Meridian yourself with Crystal, the result is still a native binary, but it is not automatically fully standalone. Depending on your toolchain, additional shared libraries may be required.

## 2. Initialize

Change into your project and let Meridian detect the framework (Marten, Rails, Elixir, Node, Go):

```bash
cd my-app
meridian init
```

For Marten projects, Meridian recognizes the standard project layout, sets `MARTEN_ENV=production`, and reuses `/health` if you have defined that route. Rails projects get `RAILS_ENV=production` and the generated `/up` route when your `config/routes.rb` declares it.

Everything Meridian owns lives under a single `.meridian/` directory, so your repo root stays uncluttered:

```
.meridian/
  deploy.yml      # your deploy config — commit this
  hooks/          # optional deploy hooks
  .gitignore      # ignores secrets, cache/, tmp/
```

This writes a `.meridian/deploy.yml` that you should review before the first deploy. Update at minimum the host address, public hostname, and image name:

```yaml
service: my-app
image: ghcr.io/acme/my-app:2026-08-01-a1b2c3d

servers:
  web:
    hosts:
      - prod-01.example.com
    proxy:
      host: my-app.example.com
      ssl: true
      app_port: 8000
transfer:
  mode: stream   # or 'incremental', or omit to pull from a registry

env:
  clear:
    MARTEN_ENV: production
  secret:
    - SECRET_KEY_BASE
    - DATABASE_URL
```

Tag every release uniquely, as above. With a reused tag like `:latest`, the next
deploy retags the name and prunes the old image - and
[rollback](#_9-rollback) needs that image to reconstruct the previous release.

For every available field, default, and validation rule, see the
[`deploy.yml` reference](/reference/deploy-yml).

## 3. Configure The SSH Key And Image

`meridian server bootstrap` installs your public key on the server, so
`deploy.yml` has to name the private key first. The `.pub` sibling must sit next
to it:

```yaml
ssh:
  user: deploy
  keys:
    - ~/.ssh/id_ed25519
```

Then build the image you referenced under `image:`. Meridian never builds it for
you:

```bash
podman build -t ghcr.io/acme/my-app:2026-08-01-a1b2c3d .
```

With `transfer.mode: stream` or `incremental` the image must exist in your
**local** Podman storage - that is what gets shipped over SSH. Omit `transfer`
entirely to have the host pull from a registry instead, and add a
[`registry`](/reference/deploy-yml#registry) block for the credentials.

## 4. Bootstrap The Server

Fresh Debian or Ubuntu box:

```bash
meridian server bootstrap --host 1.2.3.4
```

It expects root SSH with password login still enabled - it prompts for that
password, then turns both off when it is done. Pass `--root-user` if the
privileged user is not `root`, and `--deploy-user` to override the `ssh.user`
from `deploy.yml`.

Bootstrap installs Podman, UFW, and the transfer tools your `transfer.mode`
needs, creates the deploy user with your public key, enables lingering so
rootless units survive logout, prepares `~/.config/containers/systemd/`, and
finally hardens SSH by disabling root login and password authentication.

Already running another Meridian service on this host? Skip this step - the
server is provisioned. See [Multi-App Hosting](/guide/multi-app) for what a
second service on the same box does and does not share.

## 5. Set Secrets

Every name under `env.secret` must exist as a Podman secret on the host before
you deploy - the generated Quadlet references it, and the container will not
start without it:

```bash
meridian secret gen SECRET_KEY_BASE
printf '%s' "$DATABASE_URL" | meridian secret set DATABASE_URL
```

Secrets are stored per role, defaulting to `web`. Repeat with `--role workers`
for a secondary role, and for any accessory that runs on a different host.
`secret gen` refuses to overwrite an existing name unless you pass `--force`;
`secret set` always replaces.

## 6. Run Setup

```bash
meridian setup
```

This creates the `my-app` service network on every role host - and on any
accessory host that shares it - creates the shared `meridian-proxy` network, and
installs and starts kamal-proxy on your web hosts. Run it once per service; it
takes no `--role` or `--host`, and it is safe to re-run.

## 7. Start Accessories

Databases, caches, and anything else under `accessories:` are started explicitly,
once per accessory:

```bash
meridian accessory start postgres
meridian accessory start dragonfly
```

`meridian deploy` never starts them. It waits for accessories on the service
network to pass their readiness probe and then fails, telling you to run this
command. Each accessory needs step 6 (the service network) and any secrets it
references from step 5.

## 8. Plan, Check, And Deploy

Inspect the resolved deploy intent locally first - no SSH, no registry calls:

```bash
meridian plan
```

Before the first deploy for a new project or host, run through the
[Pre-Flight Checklist](/guide/preflight). It catches DNS, image, app-port,
and accessory issues that `meridian check` cannot fully infer.

Then probe the remote hosts, including same-host route collisions with any other Meridian service manifests, then deploy:

```bash
meridian check
meridian deploy
```

On a brand-new host, `check` reports the `probe-image` probe as missing: the
health-check sidecar image is only pulled when the first deploy runs its health
check. Pull it once to get a clean check, or deploy and re-run `check` afterwards:

```bash
ssh deploy@prod-01.example.com 'podman pull docker.io/library/alpine:3.21'
```

If `check` or `deploy` fails here, start with [Troubleshooting](/guide/troubleshooting):
[local image missing](/guide/troubleshooting#image-not-known-during-stream-or-incremental-transfer),
[manifest collisions](/guide/troubleshooting#manifest-collisions-fail),
[healthcheck timeouts](/guide/troubleshooting#healthcheck-timeout), and
[stale locks](/guide/troubleshooting#stale-deploy-lock) are the most common first-deploy failures.

What happens during deploy:

1. **You've already built the image locally** (`podman build` / `docker build`). Meridian does not build the image for you.
2. The image is transferred to the server - via `podman pull` from a registry, or registry-free with `transfer.mode: stream` (SSH + zstd) or `transfer.mode: incremental` (OCI layout + rsync).
3. Meridian writes **Quadlet units** under `~/.config/containers/systemd/`, including the shared `meridian-proxy` network for proxied services, and `daemon-reload`s your user systemd.
4. **kamal-proxy** waits for the health check and atomically switches traffic from the old container color to the new one.
5. The old color is stopped, service-scoped runtime state is recorded under `~/.local/state/meridian/services/<service>/`, and unused images are pruned.

This typically takes 10-20 seconds for a small app.

### Static assets

`assets:` is optional. When you declare it, the `assets.command` runs in your app
image during the deploy, and the files it writes to `assets.output_dir` are copied
into a deploy-managed volume as a fingerprinted release. Requests to `assets.host`
are routed by kamal-proxy to a generated Caddy asset server that serves the current
release. Typical small and medium Rails or Marten apps do not need separate asset
infrastructure - object storage or a CDN - to reach production; see
[`assets`](/reference/deploy-yml#assets).

## 9. Rollback

Something went wrong in the release you just shipped?

```bash
meridian rollback
```

The previous container does not survive a successful deploy - its unit is stopped
and its Quadlet removed. So rollback **reconstructs** it: Meridian reads the
recorded release state, regenerates the Quadlet for the previous image and color,
starts it, and polls it with the same health check your `deploy.yml` configures.
Traffic moves back only after that health check passes. If the candidate fails,
Meridian tears it down and the current release keeps serving.

Two things decide whether rollback is available:

- **A previous release must be recorded.** The first deploy of a service has
  nothing to roll back to; rollback becomes available after the second.
- **The previous image must still be on the host.** This is why you tag every
  release uniquely - with a reused tag the old image is gone and rollback refuses
  rather than quietly serving the wrong code.

Only the image and color come from recorded state. Env, volumes, ports, and
command always come from your current `deploy.yml`. Rollback covers the proxied
`web` role; secondary roles go back by deploying the previous image. See
[Blue/Green](/guide/concepts#blue-green) and
[`rollback`](/reference/cli#rollback).

## Where To Go Next

- [Guide overview](/guide/) - concepts and architecture
- [Pre-Flight Checklist](/guide/preflight) - what to verify before deploy
- [Troubleshooting](/guide/troubleshooting) - common deploy failures and fixes
- [Reference](/reference/) - all `deploy.yml` options and CLI commands
