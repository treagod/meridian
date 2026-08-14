# Reference

- [`deploy.yml`](/reference/deploy-yml) — every configuration key, its default, and
  its validation rules, including health checks, accessory readiness, hooks, files,
  and assets.
- [`CLI`](/reference/cli) — every command: usage, flags, side effects, and the
  `deploy.yml` fields each one reads.

`meridian init` seeds framework defaults when it detects Marten, Rails, Elixir, Node,
or Go — `MARTEN_ENV`, `RAILS_ENV`, `MIX_ENV`, `NODE_ENV`, and a health route where it
can find one.

New here? Start with the [Quickstart](/guide/quickstart). If a deploy already failed,
go to [Troubleshooting](/guide/troubleshooting).
