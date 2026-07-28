# Go Static Binary

Single [Go](https://go.dev/) HTTP service built into a static binary and
shipped as a `scratch` image. The app image has no shell; Meridian healthchecks
run from a temporary probe container, so that is fine.

## `.meridian/deploy.yml`

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
      app_port: 8080
      healthcheck:
        path: /healthz
        interval: 2
        timeout: 5
        retries: 15

env:
  clear:
    APP_ENV: production

ssh:
  user: deploy
  keys:
    - ~/.ssh/id_ed25519

transfer:
  mode: stream
```

See [`servers.<role>.proxy.healthcheck`](/reference/deploy-yml#healthcheck) and
[`transfer`](/reference/deploy-yml#transfer).

## `Containerfile`

```dockerfile
FROM golang:1.23-alpine AS build

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/my-app ./cmd/my-app

FROM scratch

COPY --from=build /out/my-app /my-app

EXPOSE 8080
ENTRYPOINT ["/my-app"]
```

## Go Snippet

```go
http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
})
```

## Commands

```bash
podman build -t ghcr.io/example/my-app:latest .
meridian setup
meridian plan
meridian check
meridian deploy
```
