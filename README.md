# Beamlet

Beamlet is an Elixir server that your AI agent builds from the inside. Ask for a page, an API or a small app, and the agent writes it as Elixir modules that become part of your beamlet. Keep asking and it grows into whatever you want.

You talk to your beamlet from an AI client such as Claude, ChatGPT or Claude Code, connected over MCP. The agent's code, data and pages all live in one directory on the server.

## A quick look

Start a chat and ask:

> Build me a reading list on my beamlet at /books where I can add books and tick them off when I've read them.

The agent writes a table, a migration and a LiveView, and the page is at `/books` on your beamlet. Now ask for more:

> Add an endpoint I can POST a book to, so I can send one from my phone.

The agent reads what it built last time and adds `/api/books` beside it, writing to the same table.

![The reading list on a beamlet, with a form to add a book and the books on the shelf](guides/assets/reading-list.webp)

## Running Beamlet

The easiest way to run Beamlet is with Docker. Run the published image with a volume for its data:

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

A beamlet belongs to one person: you. Each client you connect gets its own token, and each token carries a policy that sets what the client's agent may do. A policy is a guardrail, not a sandbox, so treat any token as full access to your beamlet, and give one only to a client you trust.

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
