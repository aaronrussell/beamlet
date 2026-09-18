# Beamlet

**TODO: Add description**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `beamlet` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:beamlet, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/beamlet>.

## Docker

The standalone server in `server/` ships as a Docker image built from
the repo root. Run it with a volume mounted at `/data`, which holds
everything the beamlet keeps:

    docker build -t beamlet .
    docker run -d --name beamlet -p 4000:4000 -v beamlet_data:/data beamlet

Then create a user and a token with the CLI inside the container:

    docker exec beamlet bin/beamlet users.create alice
    docker exec beamlet bin/beamlet tokens.create alice laptop

The container runs as user `beamlet` (uid 1000). A named volume, as
above, is owned correctly from the start; a bind mount of a host
directory must be writable by that uid.

Configuration is by environment variable:

| Variable           | Default                 | Meaning                                              |
| ------------------ | ----------------------- | ---------------------------------------------------- |
| `BEAMLET_DATA_DIR` | `/data`                 | The data dir. Mount a volume there.                  |
| `BEAMLET_URL`      | `http://localhost:4000` | The address the beamlet is reached at. LiveView     |
|                    |                         | rejects sockets from any other origin.               |
| `SECRET_KEY_BASE`  | generated               | Signs cookies. Generated on first boot and kept in  |
|                    |                         | the data dir when unset.                             |
| `PORT`             | `4000`                  | The port the server listens on.                      |

TLS is left to whatever sits in front of the container.

## Fly

`fly.toml` describes one machine in one region with a volume at
`/data`. `fly launch` copies it, asks for an app name and a region,
creates the volume there and deploys:

    fly launch

It does not touch the `[env]` block, so if the app is not called
`beamlet`, set `BEAMLET_URL` in `fly.toml` to the new hostname
first. LiveView rejects sockets from any other origin.

Then create a user and a token over SSH:

    fly ssh console -C "bin/beamlet users.create alice"
    fly ssh console -C "bin/beamlet tokens.create alice laptop"
