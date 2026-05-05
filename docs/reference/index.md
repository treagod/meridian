# Reference

The technical reference for Meridian. It is still being built out.

## Planned Sections

- Framework detection - which defaults `init` sets for Marten, Rails, Elixir, Node, and Go
- `deploy.yml` - the configuration format and all available options
- CLI commands - `init`, `server bootstrap`, `setup`, `proxy remove`, `check`, `deploy`, `rollback`, `status`, `logs`, `exec`, `run`, `quadlet`, `accessory`, `secret`
- Quadlet templates - what Meridian generates for you
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
      app_port: 3000

env:
  clear:
    MARTEN_ENV: production
  secret:
    - DATABASE_URL
```

For a fast introduction, see the [Guide](/guide/).
