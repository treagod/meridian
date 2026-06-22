# CLI

This page documents the commands that exist in the current Meridian CLI. Usage
lines match `meridian <command> --help`; use `--config PATH` on config-backed
commands when your deploy file is not `.meridian/deploy.yml`.

Exit codes are simple: `0` means the command completed successfully, and any
non-zero code means the command failed. Validation errors, SSH failures,
preflight probe failures, missing secrets, healthcheck timeouts, and deploy-lock
contention all return non-zero.

## Target Selectors

Commands that inspect or operate on configured role hosts can narrow their
target set.

| Flag | Default | What it does |
| --- | --- | --- |
| `--role ROLE` | all roles, or command-specific `web` where noted | Select hosts from one configured role. |
| `--host HOST` | all selected hosts | Select one configured host. |
| `--primary` | `false` | Select the first host from each selected role. Cannot be combined with `--role` or `--host`. |

## `init` {#init}

Purpose: generate `.meridian/deploy.yml` for the current project.

```bash
Usage: meridian init [options]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--force` | `false` | Overwrite an existing `.meridian/deploy.yml`. |
| `-h`, `--help` | n/a | Print help. |

Side effects: creates `.meridian/deploy.yml` and `.meridian/.gitignore` locally.
It does not connect to any host and does not write runtime state under
`~/.local/state/meridian/services/<service>/`.

Exit codes: `0` on successful generation; non-zero when config generation,
validation, or overwrite protection fails.

Examples:

```bash
meridian init
meridian init --force
```

Common failures: unsupported config keys after manual edits are covered by the
[`deploy.yml` reference](/reference/deploy-yml). Relevant fields:
[`service`](/reference/deploy-yml#service), [`image`](/reference/deploy-yml#image),
[`servers.<role>`](/reference/deploy-yml#serversrole), and
[`ssh`](/reference/deploy-yml#ssh).

## `server bootstrap` {#server-bootstrap}

Purpose: provision a fresh Debian/Ubuntu server so later Meridian commands can
run as the deploy user.

```bash
Usage: meridian server bootstrap --host HOST [options]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--host HOST` | inferred only when config has one host | Server IP or hostname to provision. |
| `--port PORT` | `ssh.port` or `22` | SSH port for the initial root connection. |
| `--root-user USER` | `root` | Privileged user used before the deploy user exists. |
| `--deploy-user USER` | `ssh.user` | User to create for future Meridian commands. |
| `--accept-new-host-key` | enabled | Trust new SSH host keys. |
| `--no-accept-new-host-key` | disabled | Require the host key to already be known. |
| `--enable-auto-updates BOOL` | `yes` | Enable unattended security updates. |
| `--passwordless-sudo BOOL` | `yes` | Allow passwordless sudo for the deploy user. |
| `--rootless-low-ports BOOL` | `yes` | Allow rootless containers to bind ports such as 80 and 443. |
| `--rootless-port-start PORT` | `80` | Lowest port rootless containers may bind. |
| `--config PATH` | `.meridian/deploy.yml` | Config file used for host, SSH, and transfer defaults. |
| `-h`, `--help` | n/a | Print help. |

Side effects: installs Podman, UFW, transfer tools, and rootless prerequisites;
creates the deploy user; installs your SSH key; enables lingering; configures
low-port binding and SSH hardening. It does not write service runtime state.

Exit codes: `0` when provisioning completes; non-zero on SSH, package install,
unsupported OS, key, or config failures.

Examples:

```bash
meridian server bootstrap --host 203.0.113.10
meridian server bootstrap --host prod-01.example.com --root-user ubuntu --deploy-user deploy
```

Common failures: low-port proxy failures are covered in
[kamal-proxy bind permission denied](/guide/troubleshooting#kamal-proxy-bind-permission-denied-on-port-80).
Relevant fields: [`ssh`](/reference/deploy-yml#ssh) and
[`transfer`](/reference/deploy-yml#transfer).

## `setup` {#setup}

Purpose: install or refresh the shared host-level proxy and networks.

```bash
Usage: meridian setup [options]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `-h`, `--help` | n/a | Print help. |

Side effects: uploads and starts the service network on configured service
hosts and service-networked accessory hosts; uploads `meridian-proxy.network`
and `kamal-proxy.container` to web hosts; creates `proxy.data_dir`; runs
`systemctl --user daemon-reload`; starts kamal-proxy; connects an
already-running legacy proxy to the shared network when needed. It does not
write per-service release state.

Exit codes: `0` when proxy setup completes; non-zero on config, SSH, Podman, or
systemd failure.

Examples:

```bash
meridian setup
meridian setup --config config/production.yml
```

Common failures: see [kamal-proxy bind permission denied](/guide/troubleshooting#kamal-proxy-bind-permission-denied-on-port-80)
and [Lets Encrypt issuance hangs](/guide/troubleshooting#lets-encrypt-issuance-hangs).
Relevant fields: [`proxy`](/reference/deploy-yml#proxy) and
[`servers.<role>.proxy`](/reference/deploy-yml#serversroleproxy).

## `proxy remove` {#proxy-remove}

Purpose: remove this service's kamal-proxy routes and, when safe, the shared
proxy.

```bash
Usage: meridian proxy remove [options]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `--force` | `false` | Remove the shared proxy even when other service manifests exist. |
| `-h`, `--help` | n/a | Print help. |

Side effects: removes the current service's proxy routes and manifest; appends
an audit entry. Without `--force`, leaves kamal-proxy running if other Meridian
services are registered on the host.

Exit codes: `0` when removal completes; non-zero on config, SSH, proxy, or
safety-check failure.

Examples:

```bash
meridian proxy remove
meridian proxy remove --force
```

Common failures: same-host ownership problems are covered in
[`manifest-collisions: fail`](/guide/troubleshooting#manifest-collisions-fail).
Relevant fields: [`proxy`](/reference/deploy-yml#proxy),
[`servers.<role>.proxy`](/reference/deploy-yml#serversroleproxy), and
[`assets`](/reference/deploy-yml#assets).

## `check` {#check}

Purpose: run read-only preflight checks against the selected hosts.

```bash
Usage: meridian check [options]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--role ROLE` | all roles | Check only one configured role. |
| `--host HOST` | all selected hosts | Check only one configured host. |
| `--primary` | `false` | Check the primary host for each selected role. |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `-h`, `--help` | n/a | Print help. |

Side effects: none. It probes SSH, Podman, lingering, Quadlet directories,
transfer tools, Podman secrets, local image availability for registry-free
transfer, kamal-proxy, the shared proxy network, accessory readiness, and
same-host manifest collisions.

Exit codes: `0` when all probes pass; `1` when at least one probe fails; other
non-zero codes can occur for parse or config errors.

Examples:

```bash
meridian check
meridian check --role web --host prod-01.example.com
```

Common failures: see [`image not known`](/guide/troubleshooting#image-not-known-during-stream-or-incremental-transfer),
[`manifest-collisions: fail`](/guide/troubleshooting#manifest-collisions-fail),
and the [pre-flight checklist](/guide/preflight). Relevant fields:
[`transfer`](/reference/deploy-yml#transfer), [`env`](/reference/deploy-yml#env),
[`proxy`](/reference/deploy-yml#proxy), [`servers.<role>.proxy.healthcheck`](/reference/deploy-yml#healthcheck),
and [`accessories.<name>.ready`](/reference/deploy-yml#accessory-readiness).

## `deploy` {#deploy}

Purpose: deploy the configured application to the selected hosts.

```bash
Usage: meridian deploy [options]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--role ROLE` | all roles | Deploy only one configured role. |
| `--host HOST` | all selected hosts | Deploy only one configured host. |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `-h`, `--help` | n/a | Print help. |

Side effects: acquires the remote deploy lock; verifies the setup-created
service network; runs hooks; transfers images; uploads app Quadlets, files, and
asset units; starts new units; switches kamal-proxy for proxied roles; stops old
units; writes `active-color`, `release-state.json`, and `manifest.json`; appends
audit entries; releases the lock in an `ensure` block.

Exit codes: `0` when the selected rollout completes; non-zero on config,
registry validation, missing setup-created service network, image transfer,
hook, healthcheck, accessory-readiness, proxy, SSH, or lock-contention failure.
Lock contention is reported as a normal failed deploy, not a separate numeric
code.

Examples:

```bash
meridian deploy
meridian deploy --role web --host prod-01.example.com
```

Common failures: see [Stale deploy lock](/guide/troubleshooting#stale-deploy-lock),
[Healthcheck timeout](/guide/troubleshooting#healthcheck-timeout),
[`image not known`](/guide/troubleshooting#image-not-known-during-stream-or-incremental-transfer),
[`Hostname Lookup ... Try Again`](/guide/troubleshooting#hostname-lookup--try-again-in-app-logs),
and missing setup-created networks. Run `meridian setup` before the first
deploy for a service.
Relevant fields: [`servers.<role>`](/reference/deploy-yml#serversrole),
[`boot`](/reference/deploy-yml#boot), [`transfer`](/reference/deploy-yml#transfer),
[`registry`](/reference/deploy-yml#registry), [`files`](/reference/deploy-yml#files),
[`assets`](/reference/deploy-yml#assets), and [`hooks`](/reference/deploy-yml#hooks).

## `rollback` {#rollback}

Purpose: switch proxied web traffic back to the previous recorded release.

```bash
Usage: meridian rollback [options]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `-h`, `--help` | n/a | Print help. |

Side effects: reads `release-state.json`; starts the previous color if needed;
switches kamal-proxy back; rewrites `active-color` and `release-state.json`;
appends an audit entry. On legacy hosts without release state, it falls back to
the inactive-color behavior.

Exit codes: `0` when rollback completes; non-zero on missing rollback target,
SSH, proxy, or config failure.

Examples:

```bash
meridian rollback
meridian rollback --config config/production.yml
```

Common failures: inspect [Stale deploy lock](/guide/troubleshooting#stale-deploy-lock)
and [Healthcheck timeout](/guide/troubleshooting#healthcheck-timeout) when the
previous color cannot be started or reached. Relevant fields:
[`servers.<role>.proxy`](/reference/deploy-yml#serversroleproxy) and
[`proxy`](/reference/deploy-yml#proxy).

## `status` {#status}

Purpose: show blue/green service state and active release IDs.

```bash
Usage: meridian status [options]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--role ROLE` | all roles | Show only one configured role. |
| `--host HOST` | all selected hosts | Show only one configured host. |
| `--primary` | `false` | Show the primary host for each selected role. |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `-h`, `--help` | n/a | Print help. |

Side effects: none. It reads user systemd state and service-scoped
`release-state.json` when present.

Exit codes: `0` when status is printed; non-zero on selector, config, or SSH
failure.

Examples:

```bash
meridian status
meridian status --primary
```

Common failures: use the [troubleshooting guide](/guide/troubleshooting) when a
unit is not in the expected state. Relevant fields:
[`servers.<role>`](/reference/deploy-yml#serversrole) and
[`boot`](/reference/deploy-yml#boot).

## `logs` {#logs}

Purpose: stream `journalctl --user` logs for the selected service units.

```bash
Usage: meridian logs [options]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--role ROLE` | all roles | Stream units for one configured role. |
| `--host HOST` | all selected hosts | Stream logs from one configured host. |
| `--primary` | `false` | Stream logs from the primary host for each selected role. |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `-h`, `--help` | n/a | Print help. |

Side effects: none. This command is follow-only; it does not support `--lines`
or `--no-follow`.

Exit codes: returns the remote `journalctl` stream exit code; non-zero on
selector, config, SSH, or journalctl failure.

Examples:

```bash
meridian logs
meridian logs --host prod-01.example.com
```

Common failures: for historical log slices, use direct SSH as shown in
[Healthcheck timeout](/guide/troubleshooting#healthcheck-timeout). Relevant
fields: [`servers.<role>`](/reference/deploy-yml#serversrole).

## `exec` {#exec}

Purpose: run a command inside the active container for one role.

```bash
Usage: meridian exec ROLE [options] -- COMMAND [ARGS...]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--host HOST` | first host for the role | Choose which configured role host to exec into. |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `-h`, `--help` | n/a | Print help. |

Side effects: no Meridian state changes. The command you run inside the
container may mutate application data.

Exit codes: returns the streamed remote command exit code; non-zero on missing
role, invalid host, missing active container, SSH, or command failure.

Examples:

```bash
meridian exec web -- bin/rails db:migrate:status
meridian exec web --host prod-01.example.com -- printenv MARTEN_ENV
```

Common failures: use [`status`](#status) and [`logs`](#logs) when the active
container cannot be resolved. Relevant fields: [`servers.<role>`](/reference/deploy-yml#serversrole).

## `run` {#run}

Purpose: run a one-off command in a fresh container on the service network.

```bash
Usage: meridian run ROLE [options] -- COMMAND [ARGS...]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--host HOST` | first host for the role | Choose which configured role host runs the one-off container. |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `-h`, `--help` | n/a | Print help. |

Side effects: no Meridian runtime-state changes. The one-off container is
removed after exit and joins the setup-created `<service>` Podman network; the
command may mutate application data or connected services.

Exit codes: returns the remote `podman run` exit code; non-zero on missing role,
invalid host, SSH, image, missing setup-created service network, or command
failure.

Examples:

```bash
meridian run web -- bin/rails db:migrate
meridian run workers --host prod-02.example.com -- crystal eval 'puts 1'
```

Common failures: network or dependency startup problems are covered in
[`Hostname Lookup ... Try Again`](/guide/troubleshooting#hostname-lookup--try-again-in-app-logs).
Run `meridian setup` first if the service network is missing.
Relevant fields: [`image`](/reference/deploy-yml#image),
[`env`](/reference/deploy-yml#env), and [`accessories`](/reference/deploy-yml#accessories).

## `quadlet` {#quadlet}

Purpose: generate local Quadlet previews without contacting servers.

```bash
Usage: meridian quadlet [options]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--color COLOR` | required | Deployment color to render, `blue` or `green`. |
| `--output-dir DIR` | `./quadlet-preview` | Directory for generated preview files. |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `-h`, `--help` | n/a | Print help. |

Side effects: writes preview files under `--output-dir` on the local machine. It
does not connect to hosts and does not write Meridian runtime state.

Exit codes: `0` when files are written; non-zero on missing `--color`, invalid
color, config error, or local filesystem failure.

Examples:

```bash
meridian quadlet --color green
meridian quadlet --color blue --output-dir ./tmp/quadlets
```

Common failures: compare generated files with the [concepts guide](/guide/concepts#what-is-a-quadlet).
Relevant fields: [`servers.<role>`](/reference/deploy-yml#serversrole),
[`volumes`](/reference/deploy-yml#volumes), [`ports`](/reference/deploy-yml#ports),
[`files`](/reference/deploy-yml#files), and [`assets`](/reference/deploy-yml#assets).

## `accessory start` {#accessory-start}

Purpose: upload and start one configured accessory service.

```bash
Usage: meridian accessory start NAME [options]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `-h`, `--help` | n/a | Print help. |

Side effects: for accessories that reference `network: <service>.network`,
first verifies that `meridian setup` has materialized the service network. Then
uploads the accessory Quadlet to the accessory host, reloads user systemd,
starts `<name>.service`, and appends an audit entry. It does not update app
`active-color` or `release-state.json`.

Exit codes: `0` when the accessory starts; non-zero on unknown accessory, SSH,
Podman, missing setup-created service network, systemd, or config failure.

Examples:

```bash
meridian accessory start postgres
meridian accessory start dragonfly
```

Common failures: readiness and DNS issues are covered in
[`Hostname Lookup ... Try Again`](/guide/troubleshooting#hostname-lookup--try-again-in-app-logs).
Relevant fields: [`accessories`](/reference/deploy-yml#accessories) and
[`accessories.<name>.ready`](/reference/deploy-yml#accessory-readiness).

## `accessory stop` {#accessory-stop}

Purpose: stop one configured accessory service.

```bash
Usage: meridian accessory stop NAME [options]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `-h`, `--help` | n/a | Print help. |

Side effects: stops `<name>.service` on its configured host and appends an audit
entry. It does not remove the Quadlet file or app runtime state.

Exit codes: `0` when the accessory stops; non-zero on unknown accessory, SSH,
systemd, or config failure.

Examples:

```bash
meridian accessory stop postgres
meridian accessory stop dragonfly
```

Common failures: use [`accessory logs`](#accessory-logs) and the
[troubleshooting guide](/guide/troubleshooting). Relevant fields:
[`accessories`](/reference/deploy-yml#accessories).

## `accessory logs` {#accessory-logs}

Purpose: stream `journalctl --user` logs for one accessory service.

```bash
Usage: meridian accessory logs NAME [options]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `-h`, `--help` | n/a | Print help. |

Side effects: none. This command is follow-only.

Exit codes: returns the remote `journalctl` stream exit code; non-zero on
unknown accessory, SSH, journalctl, or config failure.

Examples:

```bash
meridian accessory logs postgres
meridian accessory logs dragonfly
```

Common failures: for dependency DNS symptoms, see
[`Hostname Lookup ... Try Again`](/guide/troubleshooting#hostname-lookup--try-again-in-app-logs).
Relevant fields: [`accessories`](/reference/deploy-yml#accessories).

## `secret gen` {#secret-gen}

Purpose: generate a random Podman secret for one role.

```bash
Usage: meridian secret gen NAME [options]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--length N` | `32` | Random byte length before encoding. |
| `--format FORMAT` | `hex` | Encoding: `hex`, `base64`, or `base64url`. |
| `--print` | `false` | Print locally instead of storing on remote hosts. |
| `--force` | `false` | Rotate an existing remote secret. Cannot be combined with `--print`. |
| `--role ROLE` | `web` | Target role. |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `-h`, `--help` | n/a | Print help. |

Side effects: without `--print`, creates the Podman secret on every host in the
target role. It does not write Meridian runtime state.

Exit codes: `0` when the secret is printed or stored; non-zero on invalid
format, existing secret without `--force`, unknown role, SSH, Podman, or config
failure.

Examples:

```bash
meridian secret gen SECRET_KEY_BASE
meridian secret gen JWT_SECRET --format base64url --role workers
```

Common failures: run [`secret ls`](#secret-ls) before rotating. Relevant fields:
[`env.secret`](/reference/deploy-yml#env).

## `secret set` {#secret-set}

Purpose: create or replace a Podman secret with an explicit value.

```bash
Usage: meridian secret set NAME [options]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--value VALUE` | read from stdin | Secret value to store. |
| `--role ROLE` | `web` | Target role. |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `-h`, `--help` | n/a | Print help. |

Side effects: removes any existing remote Podman secret with the same name and
creates the replacement on every host in the target role. It does not write
Meridian runtime state.

Exit codes: `0` when all target hosts are updated; non-zero on unknown role,
SSH, Podman, stdin, or config failure.

Examples:

```bash
printf '%s\n' "$DATABASE_URL" | meridian secret set DATABASE_URL
meridian secret set API_TOKEN --value 's3cr3t' --role workers
```

Common failures: missing deploy-time secrets surface in [`check`](#check).
Relevant fields: [`env.secret`](/reference/deploy-yml#env).

## `secret ls` {#secret-ls}

Purpose: list Podman secrets on every host in one role.

```bash
Usage: meridian secret ls [options]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--role ROLE` | `web` | Target role. |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `-h`, `--help` | n/a | Print help. |

Side effects: none.

Exit codes: `0` when secrets are listed; non-zero on unknown role, SSH, Podman,
or config failure.

Examples:

```bash
meridian secret ls
meridian secret ls --role workers
```

Common failures: use [`secret set`](#secret-set) or [`secret gen`](#secret-gen)
to create missing secrets. Relevant fields: [`env.secret`](/reference/deploy-yml#env).

## `secret rm` {#secret-rm}

Purpose: remove one Podman secret from every host in one role.

```bash
Usage: meridian secret rm NAME [options]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--role ROLE` | `web` | Target role. |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `-h`, `--help` | n/a | Print help. |

Side effects: removes the named Podman secret from every host in the target
role. It does not edit `deploy.yml`; remove the name from `env.secret` yourself
if the app no longer needs it.

Exit codes: `0` when removal completes; non-zero on unknown role, SSH, Podman,
or config failure.

Examples:

```bash
meridian secret rm OLD_TOKEN
meridian secret rm OLD_TOKEN --role workers
```

Common failures: a later [`check`](#check) fails if `env.secret` still declares
the removed name. Relevant fields: [`env.secret`](/reference/deploy-yml#env).

## `lock status` {#lock-status}

Purpose: show whether the remote deploy lock is held.

```bash
Usage: meridian lock status [options]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `-h`, `--help` | n/a | Print help. |

Side effects: none. It reads lock metadata from
`~/.local/state/meridian/services/<service>/lock/meta.json` on the lock host.

Exit codes: `0` when status is printed; non-zero on config or SSH failure.

Examples:

```bash
meridian lock status
```

Common failures: see [Stale deploy lock](/guide/troubleshooting#stale-deploy-lock).
Relevant fields: [`service`](/reference/deploy-yml#service) and
[`servers.<role>`](/reference/deploy-yml#serversrole).

## `lock acquire` {#lock-acquire}

Purpose: manually acquire the remote deploy lock.

```bash
Usage: meridian lock acquire [options]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `--message MESSAGE` | none | Reason recorded in lock metadata. |
| `-h`, `--help` | n/a | Print help. |

Side effects: creates the remote lock directory with metadata and appends an
audit entry. While held, deploys and other lock acquisitions fail.

Exit codes: `0` when the lock is acquired; non-zero when the lock is already
held or when config/SSH fails.

Examples:

```bash
meridian lock acquire --message 'database maintenance'
```

Common failures: see [Stale deploy lock](/guide/troubleshooting#stale-deploy-lock).
Relevant fields: [`service`](/reference/deploy-yml#service) and
[`servers.<role>`](/reference/deploy-yml#serversrole).

## `lock release` {#lock-release}

Purpose: release the remote deploy lock and report who held it.

```bash
Usage: meridian lock release [options]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `-h`, `--help` | n/a | Print help. |

Side effects: removes the remote lock directory and appends an audit entry.
Only run this after confirming no mutation is still active.

Exit codes: `0` when release completes; non-zero on config or SSH failure.

Examples:

```bash
meridian lock release
```

Common failures: see [Stale deploy lock](/guide/troubleshooting#stale-deploy-lock).
Relevant fields: [`service`](/reference/deploy-yml#service) and
[`servers.<role>`](/reference/deploy-yml#serversrole).

## `audit` {#audit}

Purpose: print recent Meridian audit log entries by host.

```bash
Usage: meridian audit [options]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `--host HOST` | all configured server and accessory hosts | Limit output to one configured host. |
| `--lines N` | `20` | Number of entries to show per host. |
| `-h`, `--help` | n/a | Print help. |

Side effects: none. It reads `audit.log` on each selected host.

Exit codes: returns `0` when entries are printed; non-zero on unknown host,
config, SSH, or invalid `--lines`.

Examples:

```bash
meridian audit
meridian audit --host prod-01.example.com --lines 50
```

Common failures: use this command while diagnosing [Stale deploy lock](/guide/troubleshooting#stale-deploy-lock).
Relevant fields: [`service`](/reference/deploy-yml#service),
[`servers.<role>`](/reference/deploy-yml#serversrole), and
[`accessories`](/reference/deploy-yml#accessories).

## `plan` {#plan}

Purpose: print the resolved deploy plan without contacting servers.

```bash
Usage: meridian plan [options]
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--config PATH` | `.meridian/deploy.yml` | Config file to load. |
| `-h`, `--help` | n/a | Print help. |

Side effects: none. It reads local config only; secret values are not printed.

Exit codes: `0` when the plan renders; non-zero on config validation failure.

Examples:

```bash
meridian plan
meridian plan --config config/production.yml
```

Common failures: strict config parsing is described in the
[`deploy.yml` reference](/reference/deploy-yml). Relevant fields: all fields in
[`deploy.yml`](/reference/deploy-yml), especially [`servers.<role>`](/reference/deploy-yml#serversrole),
[`env`](/reference/deploy-yml#env), [`transfer`](/reference/deploy-yml#transfer),
[`accessories`](/reference/deploy-yml#accessories), and [`assets`](/reference/deploy-yml#assets).
