# Quickstart

Three commands from repo to running app. No Kubernetes, no CI pipeline, no registry.

## 1. Install

For the official Linux releases, Meridian is a single executable:

```bash
curl -fsSL meridian-deploy.dev/install.sh | sh
```

Check the installation:

```bash
meridian --version
```

If you build Meridian yourself with Crystal, the result is still a native binary, but it is not automatically fully standalone. Depending on your toolchain, additional shared libraries may be required.

## 2. Initialize

Change into your project and let Meridian detect the framework (Marten, Rails, Elixir, Node, Go):

```bash
cd my-app
meridian init
```

For Marten projects, Meridian recognizes the standard project layout, sets `MARTEN_ENV=production`, and reuses `/health` if you have defined that route.

This writes a `deploy.yml` that you should review before the first deploy. Update at minimum the host address, public hostname, and image name:

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
      app_port: 3000

proxy:
  image: ghcr.io/basecamp/kamal-proxy:latest

transfer:
  mode: stream   # or 'incremental', or omit to pull from a registry

env:
  clear:
    MARTEN_ENV: production
  secret:
    - DATABASE_URL
```

## 3. Deploy

```bash
meridian deploy
```

What happens during deploy:

1. **You've already built the image locally** (`podman build` / `docker build`). Meridian does not build the image for you.
2. The image is transferred to the server - via `podman pull` from a registry, or registry-free with `transfer.mode: stream` (SSH + zstd) or `transfer.mode: incremental` (OCI layout + rsync).
3. Meridian writes a **Quadlet unit** under `~/.config/containers/systemd/` and `daemon-reload`s your user systemd.
4. **kamal-proxy** waits for the health check and atomically switches traffic from the old container color to the new one.
5. The old color is stopped and unused images are pruned.

This typically takes 10-20 seconds for a small app.

## 4. Rollback

Something went wrong? Switch back to the previous color:

```bash
meridian rollback
```

kamal-proxy switches traffic back without rebuilding any container.

## Where To Go Next

- [Guide overview](/guide/) - concepts and architecture
- [Reference](/reference/) - all `deploy.yml` options and CLI commands
