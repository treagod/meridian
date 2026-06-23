# Quickstart

From repo to running app with a read-only preflight check. No Kubernetes, no CI pipeline, no registry.

## 1. Install

Grab the prebuilt Linux or macOS binary (x86_64 or ARM64) from the [releases page](https://github.com/treagod/meridian/releases) and put it on your `PATH`:

```bash
sudo mv meridian /usr/local/bin/
meridian --version
```

(A one-line `curl … | sh` installer will be available once the landing site is live.)

If you build Meridian yourself with Crystal, the result is still a native binary, but it is not automatically fully standalone. Depending on your toolchain, additional shared libraries may be required.

## 2. Initialize

Change into your project and let Meridian detect the framework (Marten, Rails, Elixir, Node, Go):

```bash
cd my-app
meridian init
```

For Marten projects, Meridian recognizes the standard project layout, sets `MARTEN_ENV=production`, and reuses `/health` if you have defined that route.

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
image: ghcr.io/acme/my-app:latest

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

For every available field, default, and validation rule, see the
[`deploy.yml` reference](/reference/deploy-yml).

Set any remote secrets listed in `env.secret` before checking or deploying:

```bash
meridian secret gen SECRET_KEY_BASE
printf '%s' "$DATABASE_URL" | meridian secret set DATABASE_URL
```

## 3. Plan, Check, And Deploy

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

## 4. Rollback

Something went wrong? Switch back to the previous color:

```bash
meridian rollback
```

kamal-proxy switches traffic back without rebuilding any container.

## Where To Go Next

- [Guide overview](/guide/) - concepts and architecture
- [Pre-Flight Checklist](/guide/preflight) - what to verify before deploy
- [Troubleshooting](/guide/troubleshooting) - common deploy failures and fixes
- [Reference](/reference/) - all `deploy.yml` options and CLI commands
