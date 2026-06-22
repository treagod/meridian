# Recipes

Copy-pasteable starter configurations for common Meridian deployments. Recipes
show complete files first, then link to the reference for field details.

## Verified Examples

- [Marten](https://martenframework.com/) + [SQLite](https://sqlite.org/) + Assets CDN - [the smallest production Marten deployment](/recipes/marten-sqlite-assets).
- [Marten](https://martenframework.com/) + [Postgres](https://www.postgresql.org/) + [Dragonfly](https://www.dragonflydb.io/) + Assets CDN - [full production stack](/recipes/marten-postgres-dragonfly-assets) with deploy-managed static assets.

## Draft Examples Awaiting Maintainer Verification

- [Rails](https://rubyonrails.org/) + [Postgres](https://www.postgresql.org/) - [recipe](/recipes/rails-postgres)
- [Go](https://go.dev/) Static Binary - [recipe](/recipes/go-static-binary)
- [Kemal](https://kemalcr.com/) - [simple app recipe](/recipes/kemal-simple)
- [Static Site Behind kamal-proxy](/recipes/static-site) with [Caddy](https://caddyserver.com/)
- [Multi-App On One Host](/recipes/multi-app-one-host)
- [Third-Party Distroless Image](/recipes/vikunja-distroless) with [Vikunja](https://vikunja.io/)

Draft recipes are complete starter configs, but they are not presented as
maintainer-verified deploys yet. Run `meridian plan`, `meridian check`, and one
real deploy before treating a draft recipe as production-proven.

For field-level details, see [`deploy.yml`](/reference/deploy-yml). For command
usage and side effects, see the [CLI reference](/reference/cli).
