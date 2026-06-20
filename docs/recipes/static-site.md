# Static Site Behind kamal-proxy

Status: draft example awaiting maintainer verification.

Static HTML served by [Caddy](https://caddyserver.com/) behind kamal-proxy.
There is no framework, database, or accessory service.

## `.meridian/deploy.yml`

```yaml
service: my-app
image: ghcr.io/example/my-app-static:latest

servers:
  web:
    hosts:
      - prod-01.example.com
    proxy:
      host: app.example.com
      ssl: true
      app_port: 8080
      healthcheck:
        path: /health

ssh:
  user: deploy
  keys:
    - ~/.ssh/id_ed25519

transfer:
  mode: stream
```

See [`servers.<role>.proxy`](/reference/deploy-yml#serversroleproxy) and
[`transfer`](/reference/deploy-yml#transfer).

## `Containerfile`

```dockerfile
FROM caddy:2.8-alpine

COPY public /srv
COPY Caddyfile /etc/caddy/Caddyfile

EXPOSE 8080
```

## `Caddyfile`

```text
:8080 {
	root * /srv
	respond /health 200
	file_server
}
```

## Commands

```bash
podman build -t ghcr.io/example/my-app-static:latest .
meridian setup
meridian plan
meridian check
meridian deploy
```
