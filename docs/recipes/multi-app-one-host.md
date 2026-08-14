# Multi-App On One Host

Two configs side by side, showing which keys must differ when two services share a
host. Both apps are static Caddy sites, so nothing distracts from the naming.

For one static site on its own, use the [static site recipe](/recipes/static-site).
For the full workflow — DNS, secrets, setup order, collision checks — see the
[Multi-App Hosting guide](/guide/multi-app).

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
[`servers.<role>.proxy`](/reference/deploy-yml#servers-role-proxy), and the
[multi-app guide](/guide/multi-app).

## `Containerfile`

Both projects use the same image, differing only in the exposed port — `8000` for
`my-app`, `3000` for `my-blog`. Those must match `app_port` above.

```dockerfile
FROM caddy:2.8-alpine

COPY public /srv
COPY Caddyfile /etc/caddy/Caddyfile

EXPOSE 8000
```

## `Caddyfile`

Same story: port and health route follow the service's `deploy.yml`. `my-blog` listens
on `:3000` and responds to `/up`.

```text
:8000 {
	root * /srv
	respond /health 200
	file_server
}
```

## Commands

Run these from each project directory in turn. The second `meridian setup` does not
create a second proxy — it registers `my-blog`'s network against the shared one.

```bash
podman build -t ghcr.io/example/my-app:latest .
meridian setup
meridian plan
meridian check
meridian deploy
```
