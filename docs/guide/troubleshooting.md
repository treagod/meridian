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

## Recreate Deploy Left The Route In Maintenance

Problem: a `strategy: recreate` deploy reports that maintenance began and the
service remains in maintenance.

This is deliberate. Once Meridian has stopped old app processes, hooks or the new
container may have migrated the database or persistent volumes. Meridian therefore
does not restart the old image, perform an image-only rollback, or replace the persisted Caddy 503 route automatically.

If the final route switch was uncertain or a later step failed, the candidate
may already be serving; the error alone does not prove maintenance is active.
Inspect Caddy before assuming the route is blocked.

Diagnose every app role named in the deploy error:

```bash
ssh deploy@prod-01.example.com \
  'systemctl --user status my-app-blue.service my-app-green.service my-app-cron.service'
ssh deploy@prod-01.example.com \
  'journalctl --user -u my-app-blue.service -u my-app-green.service -u my-app-cron.service -n 100 --no-pager'
meridian audit --host prod-01.example.com --lines 50
```

Repair and verify the new release in place. If data restoration is required,
restore the matching image, database, and persistent volumes from the same backup.
Only after the service is healthy should you rerun the deploy, which atomically replaces maintenance with the verified target:

```bash
meridian deploy
```

Do not edit the fragment merely to clear the maintenance response. Recreate is single-host-only in this release, and
Accessories remain active while the app route is stopped.

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
ssh deploy@prod-01.example.com 'podman network inspect my-app'
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

The accessory readiness gate waits before starting the new app color; see [Accessory readiness](/reference/deploy-yml#accessory-readiness).

## Caddy `bind: permission denied` On Port 80

Problem: `meridian setup` or Caddy startup fails with `bind: permission denied` for `:80`.

Root cause: rootless containers need low-port binding enabled before Caddy can listen on ports 80 and 443.

Diagnose:

```bash
ssh deploy@prod-01.example.com 'systemctl --user status meridian-caddy.service'
ssh deploy@prod-01.example.com 'journalctl --user -u meridian-caddy.service -n 100 --no-pager'
ssh deploy@prod-01.example.com 'sysctl net.ipv4.ip_unprivileged_port_start'
```

Fix:

```bash
meridian server bootstrap --host prod-01.example.com
meridian setup
meridian check
```

Bootstrap is what sets `net.ipv4.ip_unprivileged_port_start`; re-running it on an
already-provisioned host is safe. `setup` then writes and starts the proxy Quadlet.

## Lets Encrypt Issuance Hangs

Problem: deploy reaches the proxy switch but HTTPS certificate issuance appears to hang or fail.

Root cause: `proxy.host` and, when configured, `assets.host` must already resolve to the server before Caddy asks Let's Encrypt for certificates.

Diagnose:

```bash
dig +short my-app.example.com
dig +short assets.my-app.example.com
ssh deploy@prod-01.example.com 'curl -I http://my-app.example.com'
ssh deploy@prod-01.example.com 'journalctl --user -u meridian-caddy.service -n 100 --no-pager'
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

Not actually a problem, but it comes up often enough to answer here: Meridian never
runs `curl` or `wget` inside your app image. The health probe runs from a temporary
container on `meridian-proxy` and reaches the app over the network, so a distroless or
`FROM scratch` image with no shell works fine.

The one case where it does break is when the *probe* image cannot be pulled on the
host.

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

The relevant field is `servers.<role>.proxy.healthcheck.probe_image`; see [Health check tuning](/reference/deploy-yml#healthcheck).

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

## CSS `url()` Assets 404 Against The Asset CDN

Problem: after enabling `assets:`, the page's HTML loads, but images or fonts referenced from *inside* a CSS file (`url("../images/logo.png")`) return 404 from the asset host.

First verify the Marten production settings. The app image must contain the
manifest generated by `collectassets --fingerprint`, and Marten must use the
same hostname as Meridian's `assets.host`:

```crystal
config.assets.url = "https://assets.my-app.example.com/"
config.assets.manifests = ["src/manifest.json"]
```

If HTML template assets already resolve to that host with fingerprinted names,
the remaining root cause is CSS processing. Marten's `{% asset %}` tag runs in
HTML templates, but it does not rewrite references inside `.css` files. A raw
`url("../images/logo.png")` therefore keeps its un-fingerprinted name, which is
not present in the published asset release.

Diagnose:

```bash
# the rendered HTML points at the asset host and fingerprinted names…
curl -s https://my-app.example.com | grep -o 'https://assets\.my-app\.example\.com/[^"]*'
# …but the CSS still references the raw, un-fingerprinted path
curl -s https://assets.my-app.example.com/app-<hash>.css | grep -o 'url([^)]*)'
```

Fix: don't reference fingerprinted assets from inside CSS files. Resolve the URL in the HTML layer, where the framework can fingerprint it, and hand it to CSS via a custom property set from a `<style>` block in `base.html`:

```html
<!-- base.html -->
<style>
  :root {
    --logo-url: url("{% asset "images/logo.png" %}");
  }
</style>
```

```css
.brand { background-image: var(--logo-url); }
```

The path is resolved through Marten's manifest in the template; the CSS just
consumes the resulting URL.

## Asset Build Fails With A DNS Or Connection Error

Problem: deploy stops at `Running asset builder`, and the journal shows a DNS or
connection error for an accessory such as `redis` or `postgres`.

Cause: the asset builder has no container network. Settings that connect to a
cache or database while loading fail before the asset command runs.

Diagnose:

```bash
ssh deploy@prod-01.example.com 'journalctl --user -u my-app-assets-builder.service -n 60 --no-pager'
ssh deploy@prod-01.example.com 'grep -c "^Network=" ~/.config/containers/systemd/my-app-assets-builder.container'
```

The second command should print `0`.

Fix: skip the connection for asset commands in every environment that builds
assets:

```crystal
# config/settings/production.cr
config.cache_store =
  if ENV["MARTEN_BUILDING_IMAGE"]? || %w(collectassets collectassets_minified).includes?(ARGV.first?)
    Marten::Cache::Store::Null.new
  else
    MartenRedisCache::Store.new(uri: ENV.fetch("REDIS_URL", "redis://redis:6379"))
  end
```

The same applies to eager cache clients and connection pools in other frameworks.
See [`assets.command`](/reference/deploy-yml#assets).

## `meridian server bootstrap` Cannot Log In As root

Problem: bootstrap fails at upload with `Permission denied (publickey,password)`.

Cause: bootstrap uses the root password because the key is not installed yet.
OpenSSH's common `PermitRootLogin prohibit-password` default rejects that login.

Diagnose:

```bash
ssh deploy@prod-01.example.com 'grep -rE "^\s*PermitRootLogin" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null'
```

No output usually means the `prohibit-password` default applies.

Fix, in order of preference:

1. **Use the provider console.** Set a root password, temporarily enable
   `PermitRootLogin yes` and `PasswordAuthentication yes`, run bootstrap, then
   restore the SSH settings. Meridian does not change sshd configuration.
2. **Provision by hand** if the intended deploy user already runs rootless
   Podman and has your SSH key:

   ```bash
   sudo apt-get install -y ca-certificates curl podman uidmap slirp4netns fuse-overlayfs zstd
   echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-rootless-low-ports.conf
   sudo sysctl --system
   sudo loginctl enable-linger deploy
   ```

3. **Keep an existing port forwarder.** Point
   [`proxy.http_port` and `proxy.https_port`](/reference/deploy-yml#proxy) at its
   higher ports.

Run `meridian check` afterward to verify Podman, lingering, and the Quadlet
directory.
