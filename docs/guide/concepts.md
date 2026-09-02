# Concepts

Meridian is an imperative deploy tool: one CLI process connects over SSH,
writes Podman Quadlets, asks user systemd to reload, and uses Caddy for
proxied traffic. Blue/Green remains the default; `strategy: recreate` adds a
deliberate-downtime path for stateful single-instance services. This page is the mental model for reading deploy
logs, debugging failures, and running multiple apps on one host.

## Deploy Flow

### Default Blue/Green Flow

Proxied web deploys use Blue/Green when `strategy` is omitted and run this
sequence on each selected host:

1. Validate locally and run `pre_deploy`.
2. Acquire the deploy lock before remote mutation starts.
3. Verify the setup-created service network.
4. Transfer the selected image by registry pull, `stream`, or `incremental`.
5. Upload the new color `.container`, file syncs, and asset units.
6. Run `systemctl --user daemon-reload`.
7. Wait for co-network accessories to pass readiness probes.
8. Run remote `before_start` hooks.
9. Run the asset builder when `assets:` is configured.
10. Start and directly healthcheck the inactive color.
11. Atomically reload the service's Caddy fragment.
12. Wait for the removed upstream's requests to drain, then stop the old color and remove its Quadlet.
13. Record `active-color`, `release-state.json`, and `manifest.json`.
14. Run final hooks and release the deploy lock.

### Recreate Flow

`strategy: recreate` is one serial transaction across every app role on one
host. Images, networks, candidate Quadlets, systemd reload, and accessory
readiness are prepared while the old release still runs. A first deploy has no
existing route, so it skips maintenance.

On a redeploy Meridian installs a persisted Caddy 503 route, drains the old upstream, stops all active
secondary roles, and then stops the old web color. Only after those stops
complete does it upload `files:`, run `after_upload`/`before_start`, and start
the candidate web color. The web healthcheck must pass before cron, worker, or
other secondary roles start. Meridian then updates the proxy target and runtime
state by atomically replacing maintenance with the candidate route, then removes the old Quadlet.

Old and new web colors are never active together. Accessories are not app roles:
they remain running throughout the transaction and only participate through
their readiness checks.

If anything fails after maintenance begins, Meridian does not restart the old
release, roll back an image, or resume traffic. Persistent data may already have
been migrated. An unhealthy candidate is stopped; a healthy candidate is kept
for diagnosis and repair. The route remains intentionally blocked until the
operator repairs the service or restores image, database, and volumes from a
matching backup, then reruns `meridian deploy` to replace the maintenance route.

For field-level details, see [`servers.<role>.proxy.healthcheck`](/reference/deploy-yml#healthcheck),
[`accessories.<name>.ready`](/reference/deploy-yml#accessory-readiness),
and [`hooks`](/reference/deploy-yml#hooks).

## What Is A Quadlet

A Quadlet is a declarative Podman file under `~/.config/containers/systemd/`.
After `systemctl --user daemon-reload`, systemd generates normal user units
from those files, so containers are started, stopped, logged, and restarted
through systemd.

```text
~/.config/containers/systemd/
  my-app.network
  my-app-blue.container
  my-app-green.container
  my-app-workers.container
  my-app-postgres.container
  my-app-assets-builder.container
  meridian-caddy.container
  meridian-proxy.network
```

| File | Purpose |
| --- | --- |
| `<service>.network` | Private Podman network for one app and its accessories. |
| `<service>-<color>.container` | Blue or green app container for a proxied managed role. |
| `<service>-<role>.container` | Stable restart-in-place container for a non-proxied managed role. |
| `<accessory>.container` | Standalone accessory service such as Postgres or Redis. |
| `<service>-assets-builder.container` | One-shot asset build unit when `assets:` is configured. |
| `meridian-caddy.container` | Shared host-level Caddy container. |
| `meridian-proxy.network` | Shared network Caddy and proxied app containers join. |

Use `meridian quadlet` to preview generated files locally.
`meridian setup` owns uploading and starting `<service>.network` on every host
that needs the private service network; deploys, one-off runs, and
service-networked accessories verify that the materialized Podman network
`<service>` exists before they use it.

Custom accessory networks are different. A `network: postgres` on an accessory
names a plain shared Podman network with no Quadlet unit, so
`meridian accessory start` creates it if it is missing. `deploy` requires it to
already exist and tells you which accessory to start.

## Deploy-Managed Static Assets

When `deploy.yml` declares an `assets:` block, Meridian publishes your built
front-end bundle as part of the deploy:

1. A one-shot builder container runs `assets.command` in the app image.
2. Its `assets.output_dir` output is copied into a timestamped release directory
   under `~/.local/state/meridian/assets/<service>/`.
3. A `current` symlink is repointed to the new release.
4. The shared Caddy proxy serves `current` directly, through an independent
   `<service>-assets.caddy` route on `assets.host`.

There is no separate asset server: `meridian-caddy` bind-mounts
`~/.local/state/meridian/assets` read-only at `/srv/assets`, so one mount covers
every service on the host. Because the cache, CORS, and compression directives
live in the route fragment, changing them takes effect on the next deploy's
config reload rather than needing a container restart.

Old releases are retained (`assets.retain_releases`) so fingerprinted URLs from
the previous version keep resolving during the rollout window. The framework's
asset URL setting must point at `assets.host`; see
[`assets`](/reference/deploy-yml#assets) and, for fingerprinted-URL mistakes,
[CSS `url()` 404s](/guide/troubleshooting#css-url-assets-404-against-the-asset-cdn).

## Per-Service Runtime State

Meridian stores runtime state per service, not globally:

```text
~/.local/state/meridian/services/my-app/
  active-color
  manifest.json
  release-state.json
  lock/
    meta.json
  audit.log
```

| File | Purpose | Read by | Written by |
| --- | --- | --- | --- |
| `active-color` | Current proxied color, `blue` or `green`. | `status`, `exec`, `rollback` | proxied `deploy`, `rollback` |
| `manifest.json` | Ownership manifest for proxy routes, assets, ports, accessories, generated files, and state paths. | `check`, `proxy remove` | `deploy` |
| `release-state.json` | Current and previous proxied releases; only Blue/Green releases are image-rollback-safe. | `status`, `rollback` | proxied `deploy`, `rollback` |
| `lock/meta.json` | Deploy lock holder, timestamp, and optional message. | `lock status`, `deploy` | `deploy`, `lock acquire`, `lock release` |
| `audit.log` | Line-oriented history of deploy, rollback, proxy, accessory, and lock operations. | `audit` | mutating commands |

This layout lets multiple Meridian services share a host without sharing state.
Non-proxied managed roles still contribute their role-named Quadlet to
`manifest.json` ownership, but do not read or write `active-color` or
`release-state.json`.

## Same-Host Multi-App Topology

Each app owns its private service network. Proxied app containers also join the
shared `meridian-proxy` network, where one Caddy can reach all apps.

```text
                           public HTTP(S)
                                |
                                v
                         meridian-caddy.container
                                |
                         meridian-proxy.network
                         /                    \
              my-app-green               my-blog-blue
                   |                           |
            my-app.network              my-blog.network
              /        \                    /        \
        postgres     dragonfly          sqlite      redis
```

Accessories attach to their app's private network, not to `meridian-proxy`,
unless you explicitly configure something else. An app automatically joins every
network its accessories declare, so an accessory on a shared `postgres` network
puts the app on `postgres` alongside its own private network.

`manifest.json` collision checks make `meridian check` fail if two services claim
the same proxy host/path, asset host, published host port, generated file, or
state path. Accessory names are the exception: two services may name the same
accessory on the same host as long as their definitions match, which is how
[shared accessories](/reference/deploy-yml#shared-accessories) work. Differing
definitions are still a hard conflict.

For a worked setup, see [Multi-App Hosting](/guide/multi-app).

## Blue/Green

Meridian keeps one active color and one candidate color for the proxied managed
role. `web` is a reserved role name: it is the only role that may declare
`proxy:`, so exactly one role per service is deployed this way. If `active-color`
says `blue`, the next deploy starts `green`; if it says `green`, the next deploy
starts `blue`.

```text
before deploy:  active-color=blue   proxy -> my-app-blue
during deploy:  blue serves traffic, green starts and passes health
after switch:   active-color=green  proxy -> my-app-green
cleanup:        old blue unit is stopped and its Quadlet is removed
```

The inactive Quadlet is removed after a successful switch, but release metadata
keeps the previous rollback-safe release. `meridian rollback` reads
`release-state.json`, starts the previous color if needed, reloads Caddy, drains the replaced upstream, rewrites `active-color`, swaps current/previous release metadata, and
records an audit entry.

## Recreate

Recreate reuses the same color-named Web Quadlets and healthcheck, but it changes
their ordering: the old color is stopped before the candidate starts. This creates
intentional downtime and prevents two versions from sharing a mutable database or
volume. The first implementation is single-host-only, requires every app role to
be managed, rejects `assets:`, and does not support selective deploys or automatic
rollback.

## Non-Proxied Managed Roles

Every managed role other than `web` — and `web` itself when it has no `proxy:` —
has one stable unit named `<service>-<role>.service`. Deploy uploads the matching
`<service>-<role>.container` and restarts it in place, so a short interruption
is expected. `status`, `logs`, and `exec` target that role unit directly instead
of consulting active-colour state.

On the first role-named deploy to a host that has no configured proxied managed
role, Meridian stops and removes legacy `<service>-blue` and
`<service>-green` Quadlets if they exist. It skips that cleanup when the same
host still owns a proxied role, protecting the live blue/green units.
