# Guide

Welcome to the Meridian guide. This documentation is still being built out.

Marten is a first-class target: `meridian init` already recognizes the standard project layout and generates sensible production defaults for it. Meridian also detects Rails, Elixir, Node, and Go projects.

## What This Guide Covers

This guide is meant to take you from the first install to a production deployment:

- Installation and initial configuration
- Initializing your first project
- Deploying to your own server
- Rollbacks, accessories, and troubleshooting

For the technical details, see the [Reference](/reference/).

## Pages

- [Quickstart](/guide/quickstart) - install Meridian, initialize a project, run the preflight check, and deploy.
- [Concepts](/guide/concepts) - understand deploy flow, Quadlets, runtime state, same-host topology, and blue/green.
- [Multi-App Hosting](/guide/multi-app) - add a second app to a VPS that already runs one Meridian service.
- [Pre-Flight Checklist](/guide/preflight) - verify DNS, images, app ports, secrets, and accessories before deploy.
- [Troubleshooting](/guide/troubleshooting) - diagnose common first-deploy failures with copy-paste commands.

More is coming soon.
