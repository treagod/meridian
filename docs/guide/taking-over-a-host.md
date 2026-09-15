# Taking Over An Existing Host

This guide replaces handwritten Podman Quadlets with Meridian-generated units
without moving the application's data.

The example uses a rootless Podman stack owned by `deploy`:

- Units: `caddy`, `my-app`, `my-app-worker`, `postgres`, and `redis`.
- Network: `my-app.network`.
- Data: `~/postgres/data`, `~/redis-data`, and `~/uploads`.
- Host: `prod-01.example.com`; public domain: `my-app.example.com`.

Replace the example names before running anything. The scripts expect Bash and
GNU tools on Linux. They also assume this stack owns its proxy, database, cache,
and network. For a host that already runs Meridian, start with
[Multi-App Hosting](/guide/multi-app).

Do not combine this move with an application or database upgrade. Keep the same
images, mounts, users, and ownership. Use
[the recreate strategy](/reference/deploy-yml#strategy) if the app cannot run two
instances at once.

## Prepare The Configuration

Read every old unit, drop-in, and environment file. Record images, commands,
environment, secrets, mounts, networks, ports, and dependencies. Review files
containing credentials locally.

List the existing secrets and check the actual mounts:

```bash
ssh deploy@prod-01.example.com 'podman secret ls'
ssh deploy@prod-01.example.com \
  'podman inspect --format "{{json .Mounts}}" postgres redis my-app'
```

Create `.meridian/deploy.yml` from the
[configuration reference](/reference/deploy-yml). Set `ssh.user: deploy` to use
the existing rootless Podman storage and secrets. The example service is
`my-app`; its worker unit becomes `my-app-worker.container`.

Reuse accessory names such as `postgres` and `redis`, including their existing
images and settings:

```yaml
accessories:
  postgres:
    host: prod-01.example.com
    image: docker.io/library/postgres:17-alpine # Only if this is your current image.
    network: my-app
    volumes:
      - "%h/postgres/data:/var/lib/postgresql/data"
```

Carry over the Redis and upload mounts. Meridian generates `my-app.network`, so
resolve custom network settings before the cutover.

With blue/green, the resulting connections are:

```text
meridian-caddy ── meridian-proxy network ── my-app-blue OR my-app-green
                                                    │
                                              my-app network
                                               │    │    │
                                        postgres  redis  my-app-worker
```

Check what the old proxy does besides forwarding traffic. Meridian's Caddy does
not accept arbitrary mounts, so move disk-served uploads elsewhere and carry over
redirects or access controls explicitly.

Prepare the image as described in the [Quickstart](/guide/quickstart), then review
deploy hooks for unwanted migrations or other data changes.

## Match Secret Names {#secrets-the-name-is-the-variable}

For app roles, each name in `env.secret` is both the Podman secret name and the
environment variable exposed to the container. Accessories can instead use
`secrets:` entries such as `postgres_password,type=env,target=POSTGRES_PASSWORD`.

If the app expects `DATABASE_PASSWORD` but Podman stores `postgres_password`,
copy it before stopping the stack. This requires `jq` and verifies the copy
without printing either value:

```bash
ssh deploy@prod-01.example.com 'bash -se' <<'REMOTE'
set -euo pipefail
umask 077
secret_dir=$(mktemp -d)
trap 'rm -f -- "$secret_dir/source" "$secret_dir/copy"; rmdir -- "$secret_dir"' EXIT

podman secret inspect --showsecret postgres_password \
  | jq -je '.[0].SecretData | strings' > "$secret_dir/source"
# No --replace: an existing destination makes creation fail.
podman secret create DATABASE_PASSWORD "$secret_dir/source"
podman secret inspect --showsecret DATABASE_PASSWORD \
  | jq -je '.[0].SecretData | strings' > "$secret_dir/copy"
cmp -- "$secret_dir/source" "$secret_dir/copy"
REMOTE
```

If the destination exists or comparison fails, stop. Keep the original secret
for the old units.

Now check the prepared configuration:

```bash
meridian plan
meridian check
```

Resolve failures individually. Proxy and network probes may fail until setup,
but SSH, secrets, images, and route ownership must be correct first.

## Back Up And Stop The Old Stack

Rehearse a restore before the maintenance window and keep a backup off the host.
A valid gzip file does not prove the database can be restored. See PostgreSQL's
[dump and restore documentation](https://www.postgresql.org/docs/current/backup-dump.html).

The next script starts downtime. Stop other writers first, check disk space,
adapt the file list, and replace `my-app` in `pg_dumpall -U` with a database
superuser.

```bash
ssh deploy@prod-01.example.com 'bash -se' <<'REMOTE'
set -euo pipefail
umask 077
cd ~/.config/containers/systemd
old_files=(caddy.container my-app.container my-app-worker.container
           postgres.container redis.container my-app.network)
for file in "${old_files[@]}"; do
  test -f "$file"
done
mkdir ~/quadlet-pre-meridian
mkdir ~/quadlet-pre-meridian/units
cp -a -- "${old_files[@]}" ~/quadlet-pre-meridian/units/

systemctl --user stop caddy.service my-app-worker.service my-app.service
podman exec postgres pg_dumpall -U my-app \
  | gzip > ~/quadlet-pre-meridian/database.sql.gz
gzip -t ~/quadlet-pre-meridian/database.sql.gz

systemctl --user stop postgres.service redis.service
tar -C ~ -czf ~/quadlet-pre-meridian/files.tar.gz redis-data uploads
gzip -t ~/quadlet-pre-meridian/files.tar.gz
REMOTE
```

On failure, stop and check which services were stopped. Do not use a failed dump.

Copy the final backups off the host, then archive only the listed units:

```bash
ssh deploy@prod-01.example.com 'bash -se' <<'REMOTE'
set -euo pipefail
cd ~/.config/containers/systemd
old_files=(caddy.container my-app.container my-app-worker.container
           postgres.container redis.container my-app.network)
# Fail if a previous attempt already created this directory.
mkdir ~/quadlet-pre-meridian/removed
for file in "${old_files[@]}"; do
  test -f "$file"
  cmp -- "$file" ~/quadlet-pre-meridian/units/"$file"
done
mv -- "${old_files[@]}" ~/quadlet-pre-meridian/removed/
systemctl --user daemon-reload
REMOTE
```

Keep the old proxy config, images, secrets, and mounts until the move is verified.

## Start Meridian

Make sure the old proxy has released its listening ports. If an existing port
forwarder maps public 80/443 to higher ports, configure
[`proxy.http_port` and `proxy.https_port`](/reference/deploy-yml#proxy) to match.

```bash
meridian setup
meridian accessory start postgres
meridian accessory start redis
```

Setup creates the networks and starts Caddy. Accessories start separately.

Before deploying the app, verify that the accessories use the original mounts:

```bash
ssh deploy@prod-01.example.com \
  'podman inspect --format "{{json .Mounts}}" postgres redis'
ssh deploy@prod-01.example.com 'podman logs --tail 30 postgres'
```

Check the expected database, a known record, and any required Redis data. Do not
deploy against an unexpected empty database.

```bash
meridian check
meridian deploy
```

If only the health-probe image is missing, follow the
[Quickstart](/guide/quickstart#plan-check-deploy).

## Verify The Application

Exercise authentication, a database-backed page, an existing upload, a worker
job, and anything the old proxy handled.

If DNS is changing as part of the move, test the target IP directly while keeping
the correct hostname for TLS:

```bash
curl --fail --show-error --silent --output /dev/null \
  --write-out '%{http_code} cert=%{ssl_verify_result}\n' \
  --resolve my-app.example.com:443:203.0.113.10 https://my-app.example.com/
```

Without a DNS change, use the regular URL. If `assets:` is configured, request a
fingerprinted URL from the rendered page too.

```bash
meridian status
meridian check
```

Expect one active web colour. Confirm the worker and accessories are running.

## Roll Back

This restores the handwritten stack, unlike `meridian rollback`, which switches
between Meridian releases. Use it only while the new proxy, accessories, and
network still belong exclusively to this stack.

```bash
ssh deploy@prod-01.example.com 'bash -se' <<'REMOTE'
set -euo pipefail
umask 077
cd ~/.config/containers/systemd
old_files=(caddy.container my-app.container my-app-worker.container
           postgres.container redis.container my-app.network)
for file in "${old_files[@]}"; do
  test -f ~/quadlet-pre-meridian/units/"$file"
done
mkdir ~/quadlet-pre-meridian/meridian-units

for unit in meridian-caddy my-app-blue my-app-green my-app-worker \
            my-app-assets-builder postgres redis; do
  if test -f "$unit.container"; then
    systemctl --user stop "$unit.service"
  fi
done

new_files=(meridian-caddy.container my-app-blue.container my-app-green.container
           my-app-worker.container my-app-assets-builder.container
           postgres.container redis.container my-app.network meridian-proxy.network)
for file in "${new_files[@]}"; do
  if test -e "$file"; then
    mv -- "$file" ~/quadlet-pre-meridian/meridian-units/
  fi
done
# Refuse to overwrite unexpected files left in the destination.
for file in "${old_files[@]}"; do
  test ! -e "$file"
  test ! -L "$file"
done
for file in "${old_files[@]}"; do
  cp -a -- ~/quadlet-pre-meridian/units/"$file" .
done
systemctl --user daemon-reload
systemctl --user start postgres.service redis.service
REMOTE
```

Confirm the original database and cache are ready, then restart the application,
worker, and finally the old proxy:

```bash
ssh deploy@prod-01.example.com 'bash -se' <<'REMOTE'
set -euo pipefail
systemctl --user start my-app.service my-app-worker.service
systemctl --user start caddy.service
REMOTE
```

Repeat the application checks. Do not deploy with Meridian again until its state
matches the restored units. Restoring units does not undo schema changes or data
writes; handle those with a separate database restore.

## Clean Up Later

Keep backups, old units, images, and secrets through several successful deploys.
Then inspect and remove obsolete resources one by one.

[`meridian prune`](/reference/cli#prune) only handles files recorded in Meridian's
manifest. Review the handwritten leftovers yourself.
