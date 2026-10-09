# Operating a beamlet

A beamlet is one process and one directory. The environment sets how it runs, the config file sets what it does, and everything it keeps lives in the data dir.

## The data dir

Everything your beamlet keeps is in one directory, `/data` in the container:

```text
/data
├── db/
│   ├── agent.db        the agent database: what agents build
│   └── beamlet.db      the beamlet's own database: you, your tokens, the routes
├── code/               the agents' modules as source, with their git history
├── files/              files agent code writes
├── config.exs          the config file, once you've written one
└── secret_key_base     signs your sign-in cookie, generated on first start
```

The agent database, `code/` and `files/` are what agents build, with the routes they mounted, which live in the beamlet's own database beside your tokens. `beamlet reset` wipes all four together. A backup is the whole data dir: nothing in it stands alone.

## Configuring it

The environment sets how your beamlet runs, and the config file sets what it does. Where both set the same thing, the config file wins.

### Environment variables

| Variable | Default | |
| --- | --- | --- |
| `BEAMLET_DATA_DIR` | `/data` | The data dir. The image sets it. |
| `BEAMLET_DEFINE_TIMEOUT` | `30000` | How long one define or patch may take to compile, in milliseconds. |
| `BEAMLET_EVAL_TIMEOUT` | `30000` | How long one eval may run, in milliseconds. |
| `BEAMLET_FIREWALL` | `on` | `off` starts your beamlet without its [firewall](#firewall) rules. |
| `BEAMLET_HTTP_ALLOW` | none | Hosts on your own network that agent code may reach, comma-separated. See [the firewall](#firewall). |
| `BEAMLET_MCP_REQUEST_TIMEOUT` | `65000` | How long a tool has to answer before the client sees "Server unavailable", in milliseconds. |
| `BEAMLET_URL` | `http://localhost:4000` | The address your beamlet is reached at. Sign-in and OAuth are built on it. |
| `PORT` | `4000` | The port it listens on inside the container. |
| `SECRET_KEY_BASE` | generated | Signs the sign-in cookie. Left unset, one is generated into the data dir. |

The MCP request timeout must be longer than the other two, so that a slow eval reports its own error rather than "Server unavailable". Your beamlet refuses to start otherwise.

Your beamlet serves plain HTTP. HTTPS belongs to whatever sits in front of it, and `BEAMLET_URL` is the `https` address it's reached at.

### Firewall

Inside Docker, your beamlet sets firewall rules as it starts, which is what `--cap-add NET_ADMIN` is for. They bound what agent code reaches, even code that gets past its policy: TCP to public addresses, apart from port 25 for mail, and DNS. Your own network, other containers, a cloud provider's metadata address and every other protocol are refused.

A host on your own network that agent code should reach goes in `BEAMLET_HTTP_ALLOW`, as names, addresses or CIDR blocks:

```shell
-e BEAMLET_HTTP_ALLOW=homeassistant.local,192.168.1.0/24
```

Where your beamlet can't have `NET_ADMIN`, `BEAMLET_FIREWALL=off` starts it without the rules. Agent code then reaches whatever the container can, held back only by `Host.HTTP`.

### Policies

Policies are defined in `config.exs` in the data dir. [Tokens and policies](tokens-and-policies.md) covers writing policies there, and copying the file in.

## Reading what it built

The easy way is to ask the agent, as in [Working with your beamlet](working-with-your-beamlet.md). From the shell, the code dir is a git repository with a commit for every change, its author the token that made it:

```shell
docker exec -u beamlet my-beamlet git -C /data/code log
```

Run git as `beamlet`, the user that owns the code dir. Git refuses a repository another user owns.

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

`reset` deletes everything agents built: the routes, the agent database, the code dir with its history, and the files dir. You, your tokens and the config file stay. It doesn't ask first, so back up if you might want any of it again. Restart afterwards, because until then the running beamlet keeps what it had loaded.

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
