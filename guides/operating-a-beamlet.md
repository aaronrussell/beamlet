# Operating a beamlet

A beamlet is one process and one directory. The environment sets how it runs, the config file sets what it does, and everything it keeps lives in the data dir.

## The data dir

Everything your beamlet keeps is in one directory, `/data` in the container:

```text
/data
├── db/
│   ├── agent.db        the agent database
│   └── beamlet.db      the system database: you and your tokens
├── code/               the agents' modules as source, with their git history
├── files/              files agent code writes
├── config.exs          the config file, once you've written one
└── secret_key_base     signs your sign-in cookie, generated on first start
```

The agent database, `code/` and `files/` are what agents build, and they move together: backed up, upgraded and wiped as one. The system database, the config file and the secret are yours.

## Configuring it

The environment sets how your beamlet runs, and the config file sets what it does. Where both set the same thing, the config file wins.

### Environment variables

| Variable | Default | |
| --- | --- | --- |
| `BEAMLET_DATA_DIR` | `/data` | The data dir. The image sets it. |
| `BEAMLET_DEFINE_TIMEOUT` | `30000` | How long one define or patch may take to compile, in milliseconds. |
| `BEAMLET_EVAL_TIMEOUT` | `30000` | How long one eval may run, in milliseconds. |
| `BEAMLET_MCP_REQUEST_TIMEOUT` | `65000` | How long a tool has to answer before the client sees "Server unavailable", in milliseconds. |
| `BEAMLET_URL` | `http://localhost:4000` | The address your beamlet is reached at. Sign-in and OAuth are built on it. |
| `PORT` | `4000` | The port it listens on inside the container. |
| `SECRET_KEY_BASE` | generated | Signs the sign-in cookie. Left unset, one is generated into the data dir. |

The MCP request timeout must be longer than the other two, so that a slow eval reports its own error rather than "Server unavailable". Your beamlet refuses to start otherwise.

Your beamlet serves plain HTTP. HTTPS belongs to whatever sits in front of it, and `BEAMLET_URL` is the `https` address it's reached at.

### The config file

The config file, `config.exs` in the data dir, sets everything else. [Tokens and policies](tokens-and-policies.md) covers writing policies there, and copying the file in.

The other setting people reach for is the allow list. Agent code reaches only the public internet, so a host on your own network has to be allowed:

```elixir
import Config

config :beamlet,
  http: [allow: ["homeassistant.local", "192.168.1.0/24"]]
```

Allow a host by name if that's how agent code will ask for it; allowing its address is not enough. The same file sets the eval's memory and output caps and a path prefix for the agents' routes, and `Beamlet.Config` lists every key.

## Reading what it built

The easy way is to ask the agent, as in [Working with your beamlet](working-with-your-beamlet.md). From the shell, the code dir is a git repository with a commit for every change, its author the token that made it:

```shell
docker exec my-beamlet git -C /data/code log
```

The databases are SQLite files, which any SQLite tool can open.

## Upgrading

The `0.1` tag follows the newest 0.1 release. To move to it, or to a new version, pull the image and start a new container on the same volume:

```shell
docker pull ghcr.io/aaronrussell/beamlet:0.1
docker stop my-beamlet
docker rm my-beamlet
```

Then start it with the `docker run` from [Getting started](getting-started.md), with the new tag if it changed.

An upgrade never needs a fresh data dir. The new version updates what it needs when it starts. A new minor version may change how things work, so read the [changelog](../CHANGELOG.md) first.

Going back is less sure. If a newer version changed the database layout, an older one refuses to start on that data dir and says so.

## Starting over

```shell
docker exec my-beamlet beamlet reset
docker restart my-beamlet
```

`reset` deletes everything agents built: the agent database, the code dir with its history, and the files dir. You, your tokens and the config file stay. It doesn't ask first, so back up if you might want any of it again. Restart afterwards, because until then the running beamlet keeps what it had loaded.

## The log

```shell
docker logs my-beamlet
```

The lines worth knowing:

- **A start that fails.** A bad variable, a config file that doesn't evaluate, or a policy naming a module that doesn't exist stops your beamlet starting. The last lines say what to fix.
- **`code audit: manual changes in the code dir`.** Someone edited the code dir by hand. Your beamlet commits the edit as `manual changes` when it starts, and the warning lists the files.
- **`code boot: quarantined`.** A module's file no longer compiles, so your beamlet set it aside. Ask the agent to list the modules. It shows the error and can fix it.
- **`routes: ... is not served`.** A route points at a module that's missing or quarantined, and it answers 404 until that's fixed.

## Where next

[Security](security.md) covers what your beamlet exposes, and what to do about it.
