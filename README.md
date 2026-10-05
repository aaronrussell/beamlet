# Beamlet

Beamlet is a little Elixir server that your AI client builds inside. Ask for a page, an API or a small app, and the agent writes it as Elixir modules on your beamlet, where it runs straight away and is still there tomorrow.

Your client talks to your beamlet over MCP. The agent's code, data and pages all live in one directory on the server.

## What it looks like

Ask your client for something:

> I want somewhere on my beamlet to send events from my scripts. Make an endpoint I can POST JSON to, and a page that shows them live as they come in.

The agent builds an endpoint at `/api/events` and a page at `/events`. Post an event with `curl` and it appears on the page as it arrives.

![The event inbox on a beamlet, with a curl command to send an event and one event received](guides/assets/events.webp)

## Quick start

Run the published Docker image with a volume for its data:

```shell
docker run -d \
  --name my-beamlet \
  -p 4000:4000 \
  -v beamlet_data:/data \
  -e BEAMLET_URL=http://localhost:4000 \
  ghcr.io/aaronrussell/beamlet:0.1
```

Set your email and password:

```shell
docker exec -it my-beamlet beamlet setup
```

Then sign in at <http://localhost:4000/beamlet>. The home page shows your MCP URL and the steps to connect your client. Once it's connected, start a chat and ask "What can I do with my beamlet?"

[Getting started](https://beamlet.hexdocs.pm/getting-started.html) goes through each step in more detail.

## Security

A beamlet belongs to one person: you. Each client you connect gets its own token, and each token carries a policy that sets what the client's agent may do. A policy is a guardrail, not a sandbox, so give tokens to clients you trust.

Beamlet is self-hosted, secure enough out of the box and hackable by choice. It won't save you from yourself.

Read [Security](https://beamlet.hexdocs.pm/security.html) before you put a beamlet online.

## Documentation

The guides are on [HexDocs](https://beamlet.hexdocs.pm):

- [Getting started](https://beamlet.hexdocs.pm/getting-started.html) to run a beamlet and connect your first client.
- [Working with your beamlet](https://beamlet.hexdocs.pm/working-with-your-beamlet.html) for what to ask for and what happens when you do.
- [Tokens and policies](https://beamlet.hexdocs.pm/tokens-and-policies.html) to connect more clients and limit what each can do.
- [Operating a beamlet](https://beamlet.hexdocs.pm/operating-a-beamlet.html) for configuration, upgrades and the log.
- [Deploy Beamlet on Fly.io](https://beamlet.hexdocs.pm/deploy-beamlet-on-fly.html) to put your beamlet online for ChatGPT and Claude.
- [Security](https://beamlet.hexdocs.pm/security.html) for what you're exposing and what to do about it.

## Licence

This package is open source and released under the [Apache License 2.0](LICENSE).

© Copyright 2026 [Push Code Ltd](https://www.pushcode.com).
