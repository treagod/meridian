# Multi-App On One Host

Status: draft example awaiting maintainer verification.

Companion recipe for the [Multi-App Hosting guide](/guide/multi-app). This page
shows two static Caddy services side by side, keeping the example focused on
service names, proxy routes, and isolated runtime state. The guide explains the
full workflow and collision checks.

## `my-app/.meridian/deploy.yml`

```yaml
service: my-app
image: ghcr.io/example/my-app:latest

servers:
  web:
    hosts:
      - prod-01.example.com
    proxy:
      host: app.example.com
      ssl: true
      app_port: 8000
      healthcheck:
        path: /health

ssh:
  user: deploy
  keys:
    - ~/.ssh/id_ed25519

transfer:
  mode: stream
```

## `my-blog/.meridian/deploy.yml`

```yaml
service: my-blog
image: ghcr.io/example/my-blog:latest

servers:
  web:
    hosts:
      - prod-01.example.com
    proxy:
      host: blog.example.com
      ssl: true
      app_port: 3000
      healthcheck:
        path: /up

ssh:
  user: deploy
  keys:
    - ~/.ssh/id_ed25519

transfer:
  mode: stream
```

See [`service`](/reference/deploy-yml#service),
[`servers.<role>.proxy`](/reference/deploy-yml#serversroleproxy), and the
[multi-app guide](/guide/multi-app).

## `my-app/Containerfile`

```dockerfile
FROM caddy:2.8-alpine

COPY public /srv
COPY Caddyfile /etc/caddy/Caddyfile

EXPOSE 8000
```

## `my-app/Caddyfile`

```text
:8000 {
	root * /srv
	respond /health 200
	file_server
}
```

## `my-blog/Containerfile`

```dockerfile
FROM caddy:2.8-alpine

COPY public /srv
COPY Caddyfile /etc/caddy/Caddyfile

EXPOSE 3000
```

## `my-blog/Caddyfile`

```text
:3000 {
	root * /srv
	respond /up 200
	file_server
}
```

## Commands

Run from each project directory.

```bash
podman build -t ghcr.io/example/my-app:latest .
meridian setup
meridian plan
meridian check
meridian deploy
```

```bash
podman build -t ghcr.io/example/my-blog:latest .
meridian setup
meridian plan
meridian check
meridian deploy
```
