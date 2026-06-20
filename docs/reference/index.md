# Reference

The technical reference for Meridian.

## Sections

- [`deploy.yml`](/reference/deploy-yml) — the configuration format: every key, default, and
  validation rule, plus health checks, accessory readiness, hooks, files, and assets.
- [`CLI`](/reference/cli) — command usage, flags, side effects, exit codes, examples, and the
  related `deploy.yml` fields per command.

During `init`, Meridian detects frameworks such as Marten, Rails, Elixir, Node, and Go, and
seeds framework-specific defaults (`MARTEN_ENV`, `RAILS_ENV`, `MIX_ENV`, `NODE_ENV`, …). For a
complete example config, see the [`deploy.yml` reference](/reference/deploy-yml).

## Common deep links

- [Health check tuning](/reference/deploy-yml#healthcheck)
- [Accessory readiness](/reference/deploy-yml#accessory-readiness)
- [Image transfer mode](/reference/deploy-yml#transfer)
- [Remote hook phases](/reference/deploy-yml#hooks)
- [Static assets](/reference/deploy-yml#assets)

New to Meridian? Start with the [Guide](/guide/) and the [Quickstart](/guide/quickstart). If a
deploy fails, the [Troubleshooting guide](/guide/troubleshooting) has copy-paste diagnostics.
