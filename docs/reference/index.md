# Reference

The technical reference for Meridian.

## Available Sections

- [`deploy.yml`](/reference/deploy-yml) - the configuration format, defaults,
  validation rules, health checks, accessory readiness, hooks, files, and assets.

## Planned Sections

- Framework detection - which defaults `init` sets for Marten, Rails, Elixir, Node, and Go
- CLI commands - `init`, `server bootstrap`, `setup`, `proxy remove`, `check`, `deploy`, `rollback`, `status`, `logs`, `exec`, `run`, `quadlet`, `accessory`, `secret`
- Quadlet templates - what Meridian generates for you
- Same-host hosting - service-scoped runtime state, shared proxy network, and manifest collision checks
- Hooks and extension points

## Configuration At A Glance

During `init`, Meridian detects frameworks such as Marten and sets framework-specific defaults like `MARTEN_ENV=production`, `RAILS_ENV=production`, `MIX_ENV=prod`, or `NODE_ENV=production`.

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

env:
  clear:
    MARTEN_ENV: production
  secret:
    - DATABASE_URL

accessories:
  postgres:
    image: docker.io/library/postgres:18-alpine
    host: prod-01.example.com
    network: my-app.network
    ready:
      cmd: ["pg_isready", "-U", "app"]
```

For the complete schema, see [`deploy.yml`](/reference/deploy-yml). For a fast
introduction, see the [Guide](/guide/).

If a deploy fails, use the [Troubleshooting guide](/guide/troubleshooting) for
copy-paste diagnostics before digging into the full reference.

## Common Deep Links

- [Health check tuning](/reference/deploy-yml#healthcheck)
- [Accessory readiness](/reference/deploy-yml#accessory-readiness)
- [Image transfer mode](/reference/deploy-yml#transfer)
- [Remote hook phases](/reference/deploy-yml#hooks)
- [Static assets](/reference/deploy-yml#assets)
