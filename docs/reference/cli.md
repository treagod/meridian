# CLI

Every command in the current Meridian CLI. Run `meridian COMMAND --help` for the
authoritative flag list.

## Common Flags

Every config-backed command accepts these, so they are not repeated per command:

| Flag | Default | What it does |
| --- | --- | --- |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `-h`, `--help` | n/a | Print help and exit. |

`init` takes no `--config` — it is what writes the config in the first place.

## Exit Codes

`0` means the command completed, anything else means it failed. Validation errors,
SSH failures, preflight probe failures, missing secrets, healthcheck timeouts, and
deploy-lock contention all return non-zero. Two groups deviate and say so in their
own section: `check` returns `1` specifically when a probe fails, and the streaming
commands pass the remote exit code through.

## Target Selectors

Commands that operate on configured role hosts can narrow the target set.

| Flag | Default | What it does |
| --- | --- | --- |
| `--role ROLE` | all roles | Select every host of one configured role. |
| `--host HOST` | all selected hosts | Select one configured host. |
| `--primary` | `false` | Select the first host of the `web` role. Cannot be combined with `--role` or `--host`. |

`--role` and `--host` together select exactly that pair, and fail if the host is not
configured for the role.

## `init` {#init}

Generates `.meridian/deploy.yml` for the current project by detecting the framework.

```bash
meridian init
meridian init --force
```

`--force` overwrites an existing config. Without it, an existing
`.meridian/deploy.yml` is left alone and the command fails.

Writes `.meridian/deploy.yml` and `.meridian/.gitignore` locally. No host is
contacted, no runtime state is written.

See [`service`](/reference/deploy-yml#service), [`image`](/reference/deploy-yml#image),
[`servers.<role>`](/reference/deploy-yml#servers-role), [`ssh`](/reference/deploy-yml#ssh).

## `server bootstrap` {#server-bootstrap}

Provisions a fresh Debian or Ubuntu server so later commands can run as the deploy
user. Expects root SSH with password login still enabled. It does not change your SSH
configuration — see the note below.

```bash
meridian server bootstrap --host 203.0.113.10
meridian server bootstrap --host prod-01.example.com --root-user ubuntu --deploy-user deploy
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--host HOST` | inferred only when the config has exactly one host | Server IP or hostname to provision. |
| `--port PORT` | `ssh.port` or `22` | SSH port for the initial root connection. |
| `--root-user USER` | `root` | Privileged user used before the deploy user exists. |
| `--deploy-user USER` | `ssh.user` | User to create for future Meridian commands. |
| `--accept-new-host-key` | enabled | Trust new SSH host keys. |
| `--no-accept-new-host-key` | disabled | Require the host key to already be known. |
| `--rootless-low-ports BOOL` | `yes` | Allow rootless containers to bind ports such as 80 and 443. |
| `--rootless-port-start PORT` | `80` | Lowest port rootless containers may bind. |

Installs Podman, rootless prerequisites, and the transfer tools your `transfer.mode`
needs; creates the deploy user; installs your SSH key; writes `/etc/subuid` and
`/etc/subgid` entries; enables lingering; and configures low-port binding. It writes no
service runtime state.

Bootstrap deliberately leaves server policy to you. It installs no firewall, changes no
sshd setting, grants no sudo rights, and enables no unattended upgrades — those are
yours to decide, and Meridian has no business overriding them on a machine it does not
own. If you want a firewall, the proxy needs inbound 80/443 and Meridian needs inbound
SSH; note that any accessory publishing a host port needs its own rule too. Root login
and password authentication stay exactly as you left them.

See [`ssh`](/reference/deploy-yml#ssh), [`transfer`](/reference/deploy-yml#transfer),
and [Caddy bind permission denied](/guide/troubleshooting#caddy-bind-permission-denied-on-port-80)
if low ports stay blocked afterwards.

## `setup` {#setup}

Installs or refreshes the shared host-level proxy and the networks it needs. Run it
once per service, before the first deploy; it is safe to re-run.

```bash
meridian setup
meridian setup --config config/production.yml
```

Uploads and starts `<service>.network` on configured service hosts and on
service-networked accessory hosts, uploads `meridian-proxy.network` and
`meridian-caddy.container`, the root Caddyfile, and `meridian-proxy.network` to web hosts; creates `proxy.data_dir`; gives a service without an existing route an initial persistent HTTP 503 route; reloads user systemd; and restarts Caddy. Setup requires `flock`, verifies Caddy 2.11.2 or newer, its private Unix admin API, and HTTP reachability. Existing service routes are preserved and no per-service release state is written.

See [`proxy`](/reference/deploy-yml#proxy) and
[`servers.<role>.proxy`](/reference/deploy-yml#servers-role-proxy). Failures usually land
in [bind permission denied](/guide/troubleshooting#caddy-bind-permission-denied-on-port-80)
or [Lets Encrypt issuance hangs](/guide/troubleshooting#lets-encrypt-issuance-hangs).

## `proxy remove` {#proxy-remove}

Removes this service's Caddy route fragments, atomically reloads Caddy, and removes its manifest, then removes the shared
proxy if no other Meridian service is registered on the host.

```bash
meridian proxy remove
meridian proxy remove --force
```

`--force` removes the shared proxy even when other service manifests exist. That is a
destructive host-level action and can interrupt other apps on the same server.

Appends an audit entry either way.

See [`proxy`](/reference/deploy-yml#proxy),
[`servers.<role>.proxy`](/reference/deploy-yml#servers-role-proxy),
[`assets`](/reference/deploy-yml#assets), and
[`manifest-collisions: fail`](/guide/troubleshooting#manifest-collisions-fail) for
ownership problems.

## `prune` {#prune}

Removes files left by an earlier configuration. Deploy reports these files but
does not remove them.

```bash
meridian prune
meridian prune --force
```

Quadlet units are stopped before their files are removed. Podman volumes are
listed but never removed. Paths outside `.config/containers/` and
`.local/state/meridian/` are rejected, and the manifest itself is kept.

The command asks before removing anything. `--force` skips the prompt.

## `check` {#check}

Runs read-only preflight probes against the selected hosts. Changes nothing.

```bash
meridian check
meridian check --role web --host prod-01.example.com
```

Accepts the [target selectors](#target-selectors).

Probes SSH, Podman, lingering, Quadlet directories, transfer tools on the host *and*
on the machine you deploy from, Podman secrets,
local image availability for registry-free transfer, readability of every local
`files:` source, Caddy container/version/admin API/configuration, the shared proxy network, accessory readiness, and
same-host manifest collisions.

Transfer tooling is probed on both ends because both ends run it: `stream` pipes
through a local `zstd`, and `incremental` shells out to a local `rsync`
before anything is sent (its export uses `podman save`, and its `skopeo` import runs on the host). A `tool:` row on a host address is the remote side; one on
`local` is your own machine. (`zstd` appears only on the host rows for `incremental` —
`server bootstrap` installs it there, but the local incremental path never runs it.)

Two probes have detail worth knowing. A local `files:` source must be a readable
regular file — the same thing the deploy reads — so a directory is reported as a
failure. Accessory readiness is reported twice: every accessory sharing the service
network gets a `local` row proving its readiness contract resolves, and accessories
pinned to a checked host additionally get a live probe against that host.

Exit code `1` means at least one probe failed. Parse and config errors return other
non-zero codes.

See [`transfer`](/reference/deploy-yml#transfer), [`env`](/reference/deploy-yml#env),
[`proxy`](/reference/deploy-yml#proxy),
[`servers.<role>.proxy.healthcheck`](/reference/deploy-yml#healthcheck),
[`accessories.<name>.ready`](/reference/deploy-yml#accessory-readiness), and the
[pre-flight checklist](/guide/preflight) for what `check` cannot infer.

## `deploy` {#deploy}

Deploys the configured application to the selected hosts. Run
[`setup`](#setup) first for a new service — deploy fails if the service network is
missing.

```bash
meridian deploy
meridian deploy --role web --host prod-01.example.com
```

Accepts `--role` and `--host` from the [target selectors](#target-selectors),
except under `strategy: recreate`, where any subset is rejected before SSH.

Runs local validation and `pre_deploy`, then acquires the remote deploy lock,
verifies the service network, runs remote hooks, transfers images, uploads app
Quadlets/files/asset units, and starts new units. Proxied managed
roles then atomically reload their Caddy route, wait for the removed upstream to drain, and write `active-color` plus `release-state.json`;
other managed roles restart their stable `<service>-<role>` unit without proxy state.
Finally writes `manifest.json`, appends audit entries, and releases the lock in an
`ensure` block.

With `strategy: recreate`, Meridian first transfers every role image and uploads
all new Quadlets on the service's single host. On a redeploy it atomically installs a persistent Caddy 503 route, drains the old upstream, stops active secondary roles, and stops the old web colour
before starting anything new. The new web colour must pass its direct container
healthcheck before secondary roles start. Traffic resumes after every role is
ready and Caddy accepts the new target; runtime state is recorded afterwards.
Accessories remain running.

If Recreate fails while maintenance is active, the persisted 503 route stays
blocked and Meridian does not restart the old image. Repair the service before
redeploying. Failures after the final switch do not restore maintenance; inspect
Caddy when the switch result is uncertain, even if the error mentions maintenance.

Lock contention is reported as a normal failed deploy, not a separate numeric code.

See [`servers.<role>`](/reference/deploy-yml#servers-role),
[`boot`](/reference/deploy-yml#boot), [`transfer`](/reference/deploy-yml#transfer),
[`registry`](/reference/deploy-yml#registry), [`files`](/reference/deploy-yml#files),
[`assets`](/reference/deploy-yml#assets), [`hooks`](/reference/deploy-yml#hooks). The
common first-deploy failures are [stale deploy lock](/guide/troubleshooting#stale-deploy-lock),
[healthcheck timeout](/guide/troubleshooting#healthcheck-timeout),
[`image not known`](/guide/troubleshooting#image-not-known-during-stream-or-incremental-transfer),
and [`Hostname Lookup ... Try Again`](/guide/troubleshooting#hostname-lookup-try-again-in-app-logs).

## `rollback` {#rollback}

Restores the previously deployed release on each proxied web host.

```bash
meridian rollback
meridian rollback --config config/production.yml
```

The old container does not survive a successful deploy, so rollback reconstructs it:
it reads `release-state.json`, regenerates the Quadlet for the recorded image and
color, uploads it, reloads the user systemd daemon, and starts the unit fresh.
Caddy switches back only after the reconstructed release passes the regular
container health check. Then the rolled-back-from release is stopped and its Quadlet
removed, `active-color` and `release-state.json` are rewritten (current and previous
swap), and an audit entry is appended.

If the health check or proxy switch definitively fails before cutover, the
reconstructed candidate is torn down and the current release keeps serving. An
uncertain switch preserves both releases; failures after cutover do not tear down
the restored release. On legacy hosts without release state,
rollback falls back to restarting the surviving inactive-color container.

Two limits decide whether rollback is available at all:

- Only the proxied web role is rolled back. Secondary roles go back by deploying the
  previous image.
- The previous release's image must still be on the host. With a reused tag such as
  `latest`, the reference may resolve to newer contents and the old image may be
  pruned. Meridian checks reference existence, not image identity; use unique
  release tags to avoid restoring the wrong code.

Non-image configuration — env, volumes, ports, command — comes from the current
config file, not from the previous release.

`strategy: recreate` is rejected before SSH. Recreate releases may have migrated
persistent data, so an image-only rollback is unsafe; restore the image, database,
and persistent volumes together from a matching backup.

See [`servers.<role>.proxy`](/reference/deploy-yml#servers-role-proxy) and
[`proxy`](/reference/deploy-yml#proxy).

## `status` {#status}

Shows deployed service state for every selected role. Reads only.

```bash
meridian status
meridian status --primary
```

Accepts the [target selectors](#target-selectors).

Columns are `role`, `host`, `release`, `deployment`, and `state`. It reads user
systemd state and, for proxied roles, service-scoped `release-state.json` when
present. Non-proxied managed roles report their stable role unit; unmanaged roles
summarize their configured units.
Recreate services report `recreate` in the deployment column rather than
`blue/green`, including their secondary role rows.

See [`servers.<role>`](/reference/deploy-yml#servers-role) and
[`boot`](/reference/deploy-yml#boot).

## `logs` {#logs}

Streams `journalctl --user` logs for the selected service units.

```bash
meridian logs
meridian logs --host prod-01.example.com
```

Accepts the [target selectors](#target-selectors).

Proxied roles select both colour units, non-proxied managed roles select
`<service>-<role>.service`, unmanaged roles select their configured units.

Follow-only: there is no `--lines` and no `--no-follow`. For a historical slice, SSH
in directly — [healthcheck timeout](/guide/troubleshooting#healthcheck-timeout) shows
the `journalctl` invocation. Returns the remote `journalctl` exit code.

See [`servers.<role>`](/reference/deploy-yml#servers-role).

## `exec` {#exec}

Runs a command inside the *already running* container for one role.

```bash
meridian exec web -- bin/rails db:migrate:status
meridian exec web --host prod-01.example.com -- printenv MARTEN_ENV
```

`--host HOST` picks which configured role host to exec into; it defaults to the first
host of the role.

Proxied roles resolve their active colour, non-proxied managed roles target
`<service>-<role>` directly. Unmanaged roles are rejected — a list of arbitrary
systemd units does not identify one container name.

Meridian changes no state, but the command you run may mutate application data.
Returns the streamed remote command's exit code. Use [`status`](#status) and
[`logs`](#logs) when the active container cannot be resolved.

See [`servers.<role>`](/reference/deploy-yml#servers-role).

## `run` {#run}

Runs a one-off command in a *fresh* container on the service network — the difference
to [`exec`](#exec), which reuses the running one.

```bash
meridian run web -- bin/rails db:migrate
meridian run workers --host prod-02.example.com -- crystal eval 'puts 1'
```

`--host HOST` picks which configured role host runs the container; it defaults to the
first host of the role.

The container joins the setup-created `<service>` Podman network and is removed on
exit. Meridian writes no runtime state, but the command may mutate application data
or connected services. Returns the remote `podman run` exit code.

Run [`setup`](#setup) first if the service network does not exist yet.

See [`image`](/reference/deploy-yml#image), [`env`](/reference/deploy-yml#env),
[`accessories`](/reference/deploy-yml#accessories), and
[`Hostname Lookup ... Try Again`](/guide/troubleshooting#hostname-lookup-try-again-in-app-logs)
for dependency startup problems.

## `quadlet` {#quadlet}

Renders Quadlet files locally so you can read them before a deploy writes them. No
host is contacted.

```bash
meridian quadlet --color green
meridian quadlet --color blue --output-dir ./tmp/quadlets
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--color COLOR` | required | Deployment color to render, `blue` or `green`. |
| `--output-dir DIR` | `./quadlet-preview` | Directory for generated preview files. |

Compare the output against [what is a Quadlet](/guide/concepts#what-is-a-quadlet).

See [`servers.<role>`](/reference/deploy-yml#servers-role),
[`volumes`](/reference/deploy-yml#volumes), [`ports`](/reference/deploy-yml#ports),
[`files`](/reference/deploy-yml#files), [`assets`](/reference/deploy-yml#assets).

## `accessory start` {#accessory-start}

Uploads and starts one configured accessory. Accessories are never started by
`deploy`; this is the only command that starts them.

```bash
meridian accessory start postgres
meridian accessory start dragonfly
```

The command is idempotent, and any service declaring the accessory may run it.
Before touching the host it checks the service manifests there: if another
service already declares this accessory with a different definition, it fails
without modifying anything.

Then, in order:

1. **Network.** An accessory on the app's own `<service>` network requires
   [`setup`](#setup) to have materialized it. A custom accessory network such as
   `network: postgres` is created here if it does not exist.
2. **Unit.** An existing Quadlet that matches is reused. One that differs while
   another service references the accessory is left alone and the command fails
   — Meridian never overwrites a shared definition.
3. **Start.** Uploads the Quadlet, reloads user systemd, starts
   `<name>.service`, and appends an audit entry. App `active-color` and
   `release-state.json` are untouched.

See [`accessories`](/reference/deploy-yml#accessories),
[sharing an accessory](/reference/deploy-yml#shared-accessories),
[`accessories.<name>.ready`](/reference/deploy-yml#accessory-readiness), and
[`Hostname Lookup ... Try Again`](/guide/troubleshooting#hostname-lookup-try-again-in-app-logs)
for readiness and DNS symptoms.

## `accessory stop` {#accessory-stop}

Stops `<name>.service` on its configured host and appends an audit entry. The Quadlet
file and the app's runtime state are left alone.

```bash
meridian accessory stop postgres
meridian accessory stop postgres --force
```

| Flag | Default | Effect |
| --- | --- | --- |
| `--force` | off | Skip the confirmation when other services share this accessory. |

When other services on that host declare the same accessory, the command lists
them and asks for confirmation, defaulting to No. Declining changes nothing and
exits `1`. A closed or piped stdin counts as No, so automation never blocks —
pass `--force` for unattended runs. An accessory only this service uses stops
without any extra output.

`--force` means only "I understand this is shared". It never overwrites
conflicting definitions, ignores missing requirements, or deletes data.

See [`accessories`](/reference/deploy-yml#accessories) and
[sharing an accessory](/reference/deploy-yml#shared-accessories).

## `accessory remove` {#accessory-remove}

Stops the accessory and deletes its Quadlet unit from the host.

```bash
meridian accessory remove postgres
meridian accessory remove postgres --force
```

| Flag | Default | Effect |
| --- | --- | --- |
| `--force` | off | Skip the confirmation when other services share this accessory. |

Named volumes, images, and the accessory's Podman network are **not** removed.
Other services may still depend on the network, and persistent data is never
deleted on your behalf. Remove those yourself with `podman volume rm` and
`podman network rm` once you are sure nothing else needs them.

The shared-accessory confirmation works exactly as it does for
[`accessory stop`](#accessory-stop).

See [`accessories`](/reference/deploy-yml#accessories) and
[sharing an accessory](/reference/deploy-yml#shared-accessories).

## `accessory logs` {#accessory-logs}

Streams `journalctl --user` logs for one accessory. Follow-only, like
[`logs`](#logs). Returns the remote `journalctl` exit code.

```bash
meridian accessory logs postgres
```

See [`accessories`](/reference/deploy-yml#accessories).

## `secret gen` {#secret-gen}

Generates a random Podman secret and stores it on every host in the target role.

```bash
meridian secret gen SECRET_KEY_BASE
meridian secret gen JWT_SECRET --format base64url --role workers
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--length N` | `32` | Random byte length before encoding. |
| `--format FORMAT` | `hex` | Encoding: `hex`, `base64`, or `base64url`. |
| `--print` | `false` | Print locally instead of storing on remote hosts. |
| `--force` | `false` | Rotate an existing remote secret. Cannot be combined with `--print`. |
| `--role ROLE` | `web` | Target role. |

Without `--force` the command refuses to overwrite an existing name. Run
[`secret ls`](#secret-ls) first when rotating.

See [`env.secret`](/reference/deploy-yml#env).

## `secret set` {#secret-set}

Creates or replaces a Podman secret with a value you supply. Unlike
[`secret gen`](#secret-gen) it always replaces.

```bash
printf '%s\n' "$DATABASE_URL" | meridian secret set DATABASE_URL
meridian secret set API_TOKEN --value 's3cr3t' --role workers
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--value VALUE` | read from stdin | Secret value to store. |
| `--role ROLE` | `web` | Target role. |

Prefer stdin over `--value` — a value passed as a flag ends up in your shell history.

Removes any existing remote secret with the same name, then creates the replacement
on every host in the role. Missing deploy-time secrets surface in [`check`](#check).

See [`env.secret`](/reference/deploy-yml#env).

## `secret ls` {#secret-ls}

Lists Podman secrets on every host in one role. `--role ROLE` defaults to `web`.

```bash
meridian secret ls
meridian secret ls --role workers
```

See [`env.secret`](/reference/deploy-yml#env).

## `secret rm` {#secret-rm}

Removes one Podman secret from every host in one role. `--role ROLE` defaults to
`web`.

```bash
meridian secret rm OLD_TOKEN
meridian secret rm OLD_TOKEN --role workers
```

It does not edit `deploy.yml`. Remove the name from `env.secret` yourself, otherwise
the next [`check`](#check) fails on the now-missing secret.

See [`env.secret`](/reference/deploy-yml#env).

## `lock status` {#lock-status}

Shows whether the remote deploy lock is held, by reading
`~/.local/state/meridian/services/<service>/lock/meta.json` on the lock host.

```bash
meridian lock status
```

See [Stale deploy lock](/guide/troubleshooting#stale-deploy-lock).

## `lock acquire` {#lock-acquire}

Manually acquires the remote deploy lock. While held, deploys and other acquisitions
fail.

```bash
meridian lock acquire --message 'database maintenance'
```

`--message MESSAGE` is recorded in the lock metadata and shown by
[`lock status`](#lock-status). Appends an audit entry.

## `lock release` {#lock-release}

Removes the remote lock directory and appends an audit entry.

```bash
meridian lock release
```

Only run this after confirming no deploy, rollback, or proxy mutation is still
active — see [Stale deploy lock](/guide/troubleshooting#stale-deploy-lock) for how to
check.

## `audit` {#audit}

Prints recent Meridian audit entries per host by reading `audit.log` on each selected
host.

```bash
meridian audit
meridian audit --host prod-01.example.com --lines 50
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--host HOST` | all configured server and accessory hosts | Limit output to one configured host. |
| `--lines N` | `20` | Entries to show per host. |

Entries cover deploy, rollback, proxy, accessory, and lock operations. This is the
first thing to read when diagnosing a [stale deploy lock](/guide/troubleshooting#stale-deploy-lock).

See [`service`](/reference/deploy-yml#service),
[`servers.<role>`](/reference/deploy-yml#servers-role),
[`accessories`](/reference/deploy-yml#accessories).

## `plan` {#plan}

Prints the resolved deploy intent from local config only. No SSH, no registry calls,
and secret values are never printed. Run it after every config edit.

```bash
meridian plan
meridian plan --config config/production.yml
```

It loads the same strict schema as `deploy`, so a config error shows up here first.
The header includes the effective strategy: `blue_green`, `recreate`, or
`restart_in_place`. Every field in [`deploy.yml`](/reference/deploy-yml) affects
the output.
