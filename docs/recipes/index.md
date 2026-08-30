# Recipes

Copy-pasteable starter configurations for common Meridian deployments. Recipes
show complete files first, then link to the reference for field details.

## Verified

- [Marten](https://martenframework.com/) + [SQLite](https://sqlite.org/) + Assets CDN - [the smallest production Marten deployment](/recipes/marten-sqlite-assets).
- [Marten](https://martenframework.com/) + [Postgres](https://www.postgresql.org/) + [Dragonfly](https://www.dragonflydb.io/) + Assets CDN - [full production stack](/recipes/marten-postgres-dragonfly-assets) with deploy-managed static assets.
- [Rails](https://rubyonrails.org/) + [Postgres](https://www.postgresql.org/) - [classic Rails deployment](/recipes/rails-postgres) with migrations before app start and app-served assets.
- [Go](https://go.dev/) Static Binary - [scratch image with no shell](/recipes/go-static-binary); health checks run from Meridian's probe sidecar.

## Drafts

Complete starter configs, but nobody has run them through a real deploy yet. Use
`meridian plan` and `meridian check` first, and treat the first deploy as the
verification step.

- [Kemal](https://kemalcr.com/) - [simple app recipe](/recipes/kemal-simple)
- [Static Site Behind Caddy](/recipes/static-site) with an app-local [Caddy](https://caddyserver.com/)
- [Multi-App On One Host](/recipes/multi-app-one-host)
- [Third-Party Distroless Image](/recipes/vikunja-distroless) with [Vikunja](https://vikunja.io/)

For field-level details, see [`deploy.yml`](/reference/deploy-yml). For command
usage and side effects, see the [CLI reference](/reference/cli).
