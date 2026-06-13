# Troubleshooting

This page maps common Meridian failure messages to the fastest diagnostic path.
Examples use `my-app`, `prod-01.example.com`, and `my-app.example.com`; replace
them with your service, host, and domain.

## Healthcheck Timeout

Problem: deploy fails with `Health check failed for my-app-green: needed 3 consecutive successes`.

Root cause: the new app container did not return enough consecutive successful responses from `servers.web.proxy.healthcheck.path` before the rollout timeout.

Diagnose:

```bash
meridian logs --host prod-01.example.com
ssh deploy@prod-01.example.com 'systemctl --user status my-app-green.service'
ssh deploy@prod-01.example.com 'journalctl --user -u my-app-green.service -n 100 --no-pager'
ssh deploy@prod-01.example.com 'podman run --rm --network=meridian-proxy docker.io/library/alpine:3.21 wget -S -O- http://my-app-green:8000/health'
```

Fix:

```bash
# Fix the app so the health route returns 200 without depending on slow startup work.
curl -i http://localhost:8000/health

# If the route or port is different, update .meridian/deploy.yml:
# servers.web.proxy.app_port and servers.web.proxy.healthcheck.path
meridian check
meridian deploy
```

See the [`deploy.yml` healthcheck reference](/reference/deploy-yml#healthcheck) for field details.

## `manifest-collisions: fail`

Problem: `meridian check` reports `manifest-collisions: fail` for a host that already runs Meridian services.

Root cause: Meridian found another service manifest claiming the same proxy host/path, or found a stale manifest written by an older deploy shape.

Diagnose:

```bash
meridian check
ssh deploy@prod-01.example.com 'find ~/.local/state/meridian/services -name manifest.json -maxdepth 3 -print'
ssh deploy@prod-01.example.com 'cat ~/.local/state/meridian/services/my-app/manifest.json'
```

Fix:

```bash
# If another live service owns the same proxy host/path, change one deploy.yml first.
meridian plan

# If this is only a stale manifest for the affected service, redeploy that service.
meridian deploy
meridian check
```

Per-service manifests live under `~/.local/state/meridian/services/<service>/manifest.json` and are refreshed on the next successful deploy of that service.

## `image not known` During Stream Or Incremental Transfer

Problem: deploy fails mid-transfer with `image not known`, or `meridian check` reports a missing local image.

Root cause: `transfer.mode: stream` and `transfer.mode: incremental` read from local Podman image storage; Meridian cannot stream an image that only exists in a registry or Docker storage.

Diagnose:

```bash
meridian plan
podman image exists ghcr.io/acme/my-app:latest
meridian check
```

Fix:

```bash
podman build -t ghcr.io/acme/my-app:latest .
podman image exists ghcr.io/acme/my-app:latest
meridian check
meridian deploy
```

If you want hosts to pull from a registry instead, remove `transfer.mode` or set it to `registry`; see the [`transfer` reference](/reference/deploy-yml#transfer).

## `Hostname Lookup ... Try Again` In App Logs

Problem: app logs contain messages like `Hostname lookup for postgres failed: Try again` right after a deploy or restart.

Root cause: rootless Podman's `aardvark-dns` can briefly lag behind container startup, especially when the app starts before its co-network accessories are ready.

Diagnose:

```bash
meridian logs --host prod-01.example.com
meridian accessory logs postgres
ssh deploy@prod-01.example.com 'podman ps --format "{{.Names}}\t{{.Networks}}"'
ssh deploy@prod-01.example.com 'podman network inspect my-app.network'
```

Fix:

```bash
# Start the accessory before deploying the app.
meridian accessory start postgres

# Declare readiness for accessories on my-app.network, then verify before deploy.
meridian plan
meridian check
meridian deploy
```

The accessory readiness gate waits before starting the new app color; see [Accessory readiness](/reference/#accessory-readiness).

## kamal-proxy `bind: permission denied` On Port 80

Problem: `meridian setup` or kamal-proxy startup fails with `bind: permission denied` for `:80`.

Root cause: rootless containers need low-port binding enabled on the server before kamal-proxy can listen on ports 80 and 443.

Diagnose:

```bash
ssh deploy@prod-01.example.com 'systemctl --user status kamal-proxy.service'
ssh deploy@prod-01.example.com 'journalctl --user -u kamal-proxy.service -n 100 --no-pager'
ssh deploy@prod-01.example.com 'sysctl net.ipv4.ip_unprivileged_port_start'
```

Fix:

```bash
meridian server bootstrap --host prod-01.example.com
meridian setup
meridian check
```

`meridian server bootstrap` provisions the low-port setting; `meridian setup` writes and starts the shared proxy Quadlet.

## Lets Encrypt Issuance Hangs

Problem: deploy reaches the proxy switch but HTTPS certificate issuance appears to hang or fail.

Root cause: `proxy.host` and, when configured, `assets.host` must already resolve to the server before kamal-proxy asks Lets Encrypt for certificates.

Diagnose:

```bash
dig +short my-app.example.com
dig +short assets.my-app.example.com
ssh deploy@prod-01.example.com 'curl -I http://my-app.example.com'
ssh deploy@prod-01.example.com 'journalctl --user -u kamal-proxy.service -n 100 --no-pager'
```

Fix:

```bash
# In your DNS provider, point my-app.example.com and assets.my-app.example.com at prod-01.
dig +short my-app.example.com
dig +short assets.my-app.example.com
meridian deploy
```

Do not enable `ssl: true` until public DNS points at the target host.

## Distroless Or Scratch Image Has No `curl` Or `wget`

Problem: the app starts, but you expect Meridian's health probe to fail because the app image is distroless or `FROM scratch`.

Root cause: this is usually not a problem. Meridian does not run `curl` or `wget` inside the app image; it runs a sidecar probe image on `meridian-proxy`.

Diagnose:

```bash
meridian plan
ssh deploy@prod-01.example.com 'podman image exists docker.io/library/alpine:3.21'
ssh deploy@prod-01.example.com 'podman run --rm --network=meridian-proxy docker.io/library/alpine:3.21 wget -S -O- http://my-app-green:8000/health'
```

Fix:

```bash
# Do not add shell tools to the app image just for Meridian.
# If the default probe image is unavailable on your hosts, mirror or override it.
podman pull docker.io/library/alpine:3.21
meridian check
meridian deploy
```

The relevant field is `servers.<role>.proxy.healthcheck.probe_image`; see [Health check tuning](/reference/#health-check-tuning).

## Stale Deploy Lock

Problem: deploy exits because another deploy lock is held, but no deploy appears to be running.

Root cause: a previous deploy was interrupted after acquiring the remote lock and before releasing it.

Diagnose:

```bash
meridian lock status
meridian audit --host prod-01.example.com --lines 50
ssh deploy@prod-01.example.com 'ps -fu "$USER" | grep meridian'
```

Fix:

```bash
# Only release the lock after confirming no deploy/rollback/proxy mutation is still running.
meridian lock release
meridian check
meridian deploy
```

If you are not sure whether a mutation is still active, inspect the audit log and systemd state before releasing the lock.
