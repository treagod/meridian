# Guide

Meridian deploys containers to Linux servers you already have: SSH in, write Podman
Quadlets, let systemd supervise them, and switch traffic with Caddy. This guide
takes you from install to a running production deployment.

`meridian init` reads your project and writes a config that fits it — Marten, Rails,
Elixir, Go, and Node are each recognized by their standard layout and get the
production defaults that framework expects.

## Pages

- [Quickstart](/guide/quickstart) — install, initialize, provision a host, deploy.
- [Concepts](/guide/concepts) — deploy flow, Quadlets, runtime state, same-host
  topology, blue/green. Read this before debugging anything.
- [Multi-App Hosting](/guide/multi-app) — add a second app to a VPS that already runs
  one Meridian service.
- [Taking Over An Existing Host](/guide/taking-over-a-host) — move a server you
  already run by hand onto Meridian without moving its data.
- [Pre-Flight Checklist](/guide/preflight) — DNS, images, app ports, secrets, and
  accessories, verified before the first deploy.
- [Troubleshooting](/guide/troubleshooting) — the failures you actually hit, with
  copy-paste diagnostics.

Beyond the guide: [Recipes](/recipes/) are complete `deploy.yml` and `Containerfile`
starters per stack, and the [Reference](/reference/) documents every config key and
command.
