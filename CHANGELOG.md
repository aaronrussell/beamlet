# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Beamlet is beta until 1.0: a minor release may break things, and its entry says so.

## [Unreleased]

## [0.1.1] - 2026-10-09

### Added

- The Docker image has a firewall that keeps agent code off your network, opened to the hosts you choose with `BEAMLET_HTTP_ALLOW`. It needs `--cap-add NET_ADMIN`.

### Changed

- The default policy closes a few more ways for agent code to call a module indirectly, out of the policy's sight.

## [0.1.0] - 2026-10-07

First public release of Beamlet, an Elixir server that AI agents build from the inside, over MCP.

### Added

- **Run it as a server or inside your own app**
  - A standalone server, published as a Docker image, with guides for Docker and Fly.io.
  - An Elixir package you start in your own application's supervision tree.
  - The `beamlet` command line, to set up the owner, manage tokens, view policies and reset the beamlet.
- **Connect any MCP client**
  - An MCP server that clients connect to through OAuth, or with a token made on the command line.
  - A sign-in page, a home page with setup steps for each client, and a consent page.
- **Agents build in Elixir, on a running server**
  - Tools to run Elixir (`eval`), define modules (`define`) and edit them in place (`patch`), with docs agents discover as they go.
  - A database with migrations, a key/value store, PubSub, a files directory and outbound HTTP for agent code.
  - Phoenix controllers and LiveViews written by agents, mounted as routes and served live.
  - A git history of every change, recording which token made it.
- **Guardrails on every token**
  - A policy on each token setting what agent code may call: a default policy, and your own declared in a config file.
  - Limits on run time, memory and output, and outbound requests to private addresses refused.

---

[Unreleased]: https://github.com/aaronrussell/beamlet/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/aaronrussell/beamlet/releases/tag/v0.1.1
[0.1.0]: https://github.com/aaronrussell/beamlet/releases/tag/v0.1.0
