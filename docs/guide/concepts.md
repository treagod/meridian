# Concepts

Meridian is an imperative deploy tool: one CLI process connects over SSH,
writes Podman Quadlets, asks user systemd to reload, and uses kamal-proxy for
proxied blue/green cutovers. This page is the mental model for reading deploy
logs, debugging failures, and running multiple apps on one host.

## Deploy Flow

Proxied web deploys follow this sequence on each selected host:

```text
operator
  |
  | meridian deploy
  v
lock -> verify service network -> transfer image -> upload Quadlets/files/assets -> daemon-reload
  -> wait_for_accessories -> before_start hooks -> asset build
  -> start new color -> temporary health probe
  -> before_switch hooks -> kamal-proxy deploy
  -> after_switch hooks -> stop old color
  -> record active color + release + manifest -> after_deploy hooks
  -> release lock
```

1. Acquire the deploy lock before remote mutation starts.
2. Verify the setup-created service network.
3. Transfer the selected image by registry pull, `stream`, or `incremental`.
4. Upload the new color `.container`, file syncs, and asset units.
5. Run `systemctl --user daemon-reload`.
6. Wait for co-network accessories to pass readiness probes.
7. Run remote `before_start` hooks.
8. Run the asset builder when `assets:` is configured.
9. Start the inactive color, for example `my-app-green.service`.
10. Poll the new container from a temporary probe container on `meridian-proxy` until `healthcheck.required_successes` consecutive HTTP successes pass.
11. Run remote `before_switch` hooks.
12. Run `kamal-proxy deploy` to atomically switch traffic to the new color.
13. Run remote `after_switch` hooks.
14. Stop the old color and remove its inactive Quadlet file.
15. Record `active-color`, `release-state.json`, and `manifest.json`.
16. Run remote `after_deploy` hooks and release the deploy lock.

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
  my-app-assets.volume
  my-app-assets-builder.container
  my-app-assets-server.container
  kamal-proxy.container
  meridian-proxy.network
```

| File | Purpose |
| --- | --- |
| `<service>.network` | Private Podman network for one app and its accessories. |
| `<service>-<color>.container` | Blue or green app container for a proxied managed role. |
| `<service>-<role>.container` | Stable restart-in-place container for a non-proxied managed role. |
| `<accessory>.container` | Standalone accessory service such as Postgres or Redis. |
| `<service>-assets-*` | Asset volume, builder, and static-server units when `assets:` is configured. |
| `kamal-proxy.container` | Shared host-level proxy container. |
| `meridian-proxy.network` | Shared network kamal-proxy and proxied app containers join. |

Use `meridian quadlet` to preview generated files locally.
`meridian setup` owns uploading and starting `<service>.network` on every host
that needs the private service network; deploys, one-off runs, and
service-networked accessories verify that the materialized Podman network
`<service>` exists before they use it.

## Deploy-Managed Static Assets

When `deploy.yml` declares an `assets:` block, Meridian publishes your built
front-end bundle as part of the deploy:

1. A one-shot builder container runs `assets.command` in the app image.
2. Its `assets.output_dir` output is copied into a timestamped release directory
   on the `<service>-assets` volume.
3. A `current` symlink is repointed to the new release.
4. A generated Caddy static server serves `current` and is registered with
   kamal-proxy under the `<service>-assets` route on `assets.host`.

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
| `release-state.json` | Current and previous rollback-safe proxied releases. | `status`, `rollback` | proxied `deploy`, `rollback` |
| `lock/meta.json` | Deploy lock holder, timestamp, and optional message. | `lock status`, `deploy` | `deploy`, `lock acquire`, `lock release` |
| `audit.log` | Line-oriented history of deploy, rollback, proxy, accessory, and lock operations. | `audit` | mutating commands |

This layout lets multiple Meridian services share a host without sharing state.
Non-proxied managed roles still contribute their role-named Quadlet to
`manifest.json` ownership, but do not read or write `active-color` or
`release-state.json`.

## Same-Host Multi-App Topology

Each app owns its private service network. Proxied app containers also join the
shared `meridian-proxy` network, where one kamal-proxy can reach all apps.

```text
                           public HTTP(S)
                                |
                                v
                         kamal-proxy.container
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
unless you explicitly configure something else. `manifest.json` collision
checks make `meridian check` fail if two services claim the same proxy host/path,
asset host, published host port, accessory name, generated file, or state path.

For a worked setup, see [Multi-App Hosting](/guide/multi-app).

## Blue/Green

Meridian keeps one active color and one candidate color for proxied managed
roles. If `active-color` says `blue`, the next deploy starts `green`; if it says
`green`, the next deploy starts `blue`.

```text
before deploy:  active-color=blue   proxy -> my-app-blue
during deploy:  blue serves traffic, green starts and passes health
after switch:   active-color=green  proxy -> my-app-green
cleanup:        old blue unit is stopped and its Quadlet is removed
```

The inactive Quadlet is removed after a successful switch, but release metadata
keeps the previous rollback-safe release. `meridian rollback` reads
`release-state.json`, starts the previous color if needed, runs kamal-proxy in
reverse, rewrites `active-color`, swaps current/previous release metadata, and
records an audit entry.

## Non-Proxied Managed Roles

A managed role without `proxy:` has one stable unit named
`<service>-<role>.service`. Deploy uploads the matching
`<service>-<role>.container` and restarts it in place, so a short interruption
is expected. `status`, `logs`, and `exec` target that role unit directly instead
of consulting active-colour state.

On the first role-named deploy to a host that has no configured proxied managed
role, Meridian stops and removes legacy `<service>-blue` and
`<service>-green` Quadlets if they exist. It skips that cleanup when the same
host still owns a proxied role, protecting the live blue/green units.
