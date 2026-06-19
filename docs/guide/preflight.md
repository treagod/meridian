# Pre-Flight Checklist

Run this before the first `meridian deploy` for a new project or host. It is
not a replacement for `meridian check`; it covers things Meridian cannot fully
know from your local filesystem, DNS provider, Containerfile, or app code.

Examples use `my-app`, `prod-01.example.com`, `my-app.example.com`, and
`assets.my-app.example.com`. Replace them with your service, host, and domains.

## Infrastructure

| Check | Verify | Failure you avoid |
| --- | --- | --- |
| `proxy.host` resolves to the server | `dig +short my-app.example.com` | Lets Encrypt hangs or fails because the public hostname points somewhere else. |
| `assets.host` resolves to the server, if `assets:` is configured | `dig +short assets.my-app.example.com` | Asset HTTPS issuance fails even though the app domain works. |
| Server architecture matches your image platform | `ssh deploy@prod-01.example.com 'uname -m'` and `podman image inspect ghcr.io/acme/my-app:latest | rg '"Architecture"'` | The container fails to start with an architecture mismatch. |
| SSH key exists locally and the agent can use it | `test -f /Users/me/.ssh/id_ed25519 && ssh-add -l` | Bootstrap, setup, or deploy fails before any Podman work starts. |
| `ssh.keys` uses an absolute path | `rg -n '^\s+- /' .meridian/deploy.yml` | A relative key path works from one directory and fails from another. |
| Local Podman has enough disk space | `podman system df` | `podman build`, `podman save`, or incremental export fails with no space left. |

If the local Podman cache is too large:

```bash
podman system prune -af
podman system df
```

## App Code

| Check | Verify | Failure you avoid |
| --- | --- | --- |
| Health route exists and returns 200 without a database call | `curl -i http://localhost:8000/health` | Deploy reaches the healthcheck phase and times out. |
| Production settings read every required environment variable | `rg -n 'ENV\.(fetch|\[)' config src` | The container crashloops because a required env var is absent from `deploy.yml`. |
| App listens on every interface, not only localhost | `podman run --rm -p 127.0.0.1:8000:8000 ghcr.io/acme/my-app:latest` then `curl -i http://127.0.0.1:8000/health` | Meridian's temporary probe container cannot reach the app container. |
| App port matches `servers.web.proxy.app_port` | `rg -n 'app_port|PORT|port' .meridian/deploy.yml config src` | kamal-proxy routes to the wrong port and the healthcheck fails. |

For Marten apps, define a cheap `/health` route yourself and make production
bind to `0.0.0.0:<app_port>`.

## Containerfile

| Check | Verify | Failure you avoid |
| --- | --- | --- |
| Image is built with the tag in `.meridian/deploy.yml` | `podman image exists ghcr.io/acme/my-app:latest` | `transfer.mode: stream` or `incremental` fails before upload. |
| Image architecture matches the server | `podman image inspect ghcr.io/acme/my-app:latest | rg '"Os"|"Architecture"'` | The unit starts, then the runtime rejects the image. |
| Registry-free transfer has a local Podman image | `meridian check` | Missing local image is caught before any remote mutation. |
| Build-time commands have dummy env vars when the framework validates settings | `rg -n 'ENV\.(fetch|\[)|collectassets|migrate|setup' Containerfile Dockerfile` | The image build fails, or generated assets are missing from the final image. |

If the image is missing locally:

```bash
podman build --platform linux/arm64 -t ghcr.io/acme/my-app:latest .
podman image exists ghcr.io/acme/my-app:latest
meridian check
```

For the failure shape, see [image not known during stream or incremental transfer](/guide/troubleshooting#image-not-known-during-stream-or-incremental-transfer).

## `deploy.yml`

| Check | Verify | Failure you avoid |
| --- | --- | --- |
| `ssh.keys` is absolute | `rg -n '^\s+- /' .meridian/deploy.yml` | SSH auth depends on the current working directory. |
| `servers.web.proxy.app_port` matches the container port | `meridian plan` and `rg -n 'app_port' .meridian/deploy.yml` | Healthcheck and proxy target the wrong port. |
| `servers.web.proxy.ssl: true` is only set after DNS is live | `dig +short my-app.example.com` | Lets Encrypt issuance hangs during deploy. |
| Each accessory declares `host:` | `rg -n '^\s+host:' .meridian/deploy.yml` | Accessory commands cannot decide which host to mutate. |
| Same-host services use per-service env and secret prefixes | `rg -n 'DATABASE|SECRET|PASSWORD|TOKEN' .meridian/deploy.yml` | Two apps on one host accidentally share secret names or env meaning. |
| Accessories on the app network have readiness probes or inferable ports | `meridian plan` | The app starts before Postgres, Redis, or another accessory is reachable. |

Start accessories before the first app deploy:

```bash
meridian accessory start postgres
meridian accessory start dragonfly
meridian check
```

## Copy This Into Your Wiki

```markdown
# Meridian pre-flight checklist

## Infrastructure
- [ ] `dig +short my-app.example.com` returns the server IP.
- [ ] `dig +short assets.my-app.example.com` returns the server IP, if `assets:` is configured.
- [ ] `ssh deploy@prod-01.example.com 'uname -m'` matches the image platform.
- [ ] `test -f /Users/me/.ssh/id_ed25519 && ssh-add -l` succeeds.
- [ ] `.meridian/deploy.yml` uses absolute paths under `ssh.keys`.
- [ ] `podman system df` shows enough local disk space.

## App code
- [ ] `/health` exists and returns 200 without database access.
- [ ] Production settings read only env vars declared in `.meridian/deploy.yml`.
- [ ] The app listens on `0.0.0.0:<app_port>`.
- [ ] The app's runtime port matches `servers.web.proxy.app_port`.

## Containerfile
- [ ] `podman image exists ghcr.io/acme/my-app:latest` succeeds.
- [ ] The image was built for the server architecture.
- [ ] `stream` or `incremental` transfer has a local Podman image.
- [ ] Build-time framework commands have dummy env vars if settings are validated during build.

## deploy.yml
- [ ] `ssh.keys` paths are absolute.
- [ ] `proxy.app_port` matches the app container port.
- [ ] `proxy.ssl: true` is used only after DNS is live.
- [ ] Every accessory has an explicit `host:`.
- [ ] Env and secret names are prefixed per service for same-host deployments.
- [ ] Accessories are started before first deploy.
- [ ] `meridian check` passes.
```
