# Deploy Beamlet on Fly.io

Beamlet runs on Fly.io from its published image, as one machine with a volume for the data dir. This guide assumes you have a Fly account and `flyctl` installed.

## Speedrun

In an empty directory, save the [`fly.toml`](#the-fly-toml) below, then:

```shell
fly launch --no-deploy
fly secrets set BEAMLET_URL=https://YOUR_APP.fly.dev
fly deploy
fly ssh console --pty -C "beamlet setup"
fly apps open /beamlet
```

Sign in and connect your client from the home page. The rest of this guide takes each step in turn.

## The fly.toml

```toml
[build]
  image = "ghcr.io/aaronrussell/beamlet:0.1"

[[mounts]]
  source = "beamlet_data"
  destination = "/data"

[http_service]
  internal_port = 4000
  force_https = true
  auto_stop_machines = "off"
  auto_start_machines = true
  min_machines_running = 1

[[vm]]
  size = "shared-cpu-1x"
  memory = "512mb"
```

The image's tag is the version you run. The volume holds the whole beamlet. Everything is on that one volume, so a beamlet runs as one machine, kept running rather than stopped when idle.

## Launch the app

```shell
fly launch --no-deploy
```

Fly finds the `fly.toml` and asks whether to copy its configuration; say yes. Then choose a name and a region. The name gives your beamlet its address, `https://YOUR_APP.fly.dev`. `--no-deploy` stops there, because your beamlet needs that address before it first starts.

## Set the address

```shell
fly secrets set BEAMLET_URL=https://YOUR_APP.fly.dev
```

Your beamlet builds its sign-in and OAuth links from `BEAMLET_URL`. The address isn't a secret, but a secret is the simplest way to give the Fly app a variable once it has a name.

## Deploy

```shell
fly deploy
```

Fly creates the volume and the machine, and starts your beamlet.

## Set up the owner

```shell
fly ssh console --pty -C "beamlet setup"
fly apps open /beamlet
```

`setup` creates the owner, your beamlet's one account. It is not your Fly account. It asks for an email and a password, which you then use to sign in, and after that you follow your client's steps on the home page.

## Looking after it

The other guides give their commands for Docker. On Fly, every `beamlet` command runs over `fly ssh console`, and `Beamlet.CLI` lists them all:

```shell
fly ssh console -C "beamlet tokens"
fly ssh console -C "beamlet tokens.create cursor"
```

### The config file

Write `config.exs` on your machine, as in [Tokens and policies](tokens-and-policies.md). `fly sftp put` copies it onto the volume:

```shell
fly sftp put config.exs /data/config.exs
```

`put` will not replace a file that is already there. To change the file, remove the old one first, then `put` again:

```shell
fly ssh console -C "rm /data/config.exs"
fly sftp put config.exs /data/config.exs
```

Then check it, and restart to put it live:

```shell
fly ssh console -C "beamlet policies.show explorer"
fly apps restart
```

### Upgrading

Change the tag in `fly.toml` and deploy:

```shell
fly deploy
```

The `0.1` tag follows the newest 0.1 release, so deploying with the tag unchanged picks up its fixes. [Operating a beamlet](operating-a-beamlet.md#upgrading) says what an upgrade keeps.

### Starting over

```shell
fly ssh console -C "beamlet reset"
fly apps restart
```

### The log

```shell
fly logs
```

### Snapshots

Fly snapshots the volume every day and keeps each snapshot for five days. To see them, find the volume's id, then list its snapshots:

```shell
fly volumes list
fly volumes snapshots list VOLUME_ID
```

## Where next

- [Working with your beamlet](working-with-your-beamlet.md) once a client is connected.
- [Security](security.md) before you hand out tokens on a public address.
