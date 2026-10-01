# Beamlet

**TODO: Add description**

## Security

A beamlet belongs to one person. Tokens are that person's delegations to their clients. Policies steer each client. Treat any token as full access to the beamlet.

Agent code runs inside the beamlet's own VM. Policies, and the scanner that enforces them, are guardrails: they stop an honest model from doing something by accident, and they stop low-effort prompt injection that reaches for ordinary APIs ("fetch this URL", "read this file"). They are not a containment boundary against code that is trying to get out. If you hand a token to an agent that reads the web, assume it can reach anything the beamlet process can.

The token is the boundary: a request without one reaches nothing beyond the sign-in and OAuth pages. Known gaps in 0.1:

- The sign-in page has no rate limit, so choose a strong password.
- A session lasts until you sign out, set a new password with `beamlet setup`, or the browser drops the cookie.
- Agent pages share the beamlet's origin with the sign-in, so script on an agent page you visit while signed in can approve a connection as you on the consent page. A token already amounts to that much.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed by adding `beamlet` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:beamlet, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc) and published on [HexDocs](https://hexdocs.pm). Once published, the docs can be found at <https://hexdocs.pm/beamlet>.

## Docker

The standalone server in `server/` ships as a Docker image built from the repo root. Run it with a volume mounted at `/data`, which holds everything the beamlet keeps:

    docker build -t beamlet .
    docker run -d --name beamlet -p 4000:4000 -v beamlet_data:/data beamlet

Then set up the owner, which asks for your email and a password to sign in with, and create a token with the CLI inside the container:

    docker exec -it beamlet bin/beamlet setup
    docker exec beamlet bin/beamlet tokens.create laptop

The container runs as user `beamlet` (uid 1000). A named volume, as above, is owned correctly from the start; a bind mount of a host directory must be writable by that uid.

Configuration is by environment variable:

| Variable | Default | Meaning |
| --- | --- | --- |
| `BEAMLET_DATA_DIR` | `/data` | The data dir. Mount a volume there. |
| `BEAMLET_URL` | `http://localhost:4000` | The address the beamlet is reached at. LiveView rejects sockets from any other origin. |
| `SECRET_KEY_BASE` | generated | Signs cookies. Generated on first boot and kept in the data dir when unset. |
| `PORT` | `4000` | The port the server listens on. |
| `BEAMLET_EVAL_TIMEOUT` | `30000` | Milliseconds one eval may run before it is stopped and its output so far returned. |
| `BEAMLET_DEFINE_TIMEOUT` | `30000` | Milliseconds one define or patch may spend compiling. |
| `BEAMLET_MCP_REQUEST_TIMEOUT` | `65000` | Milliseconds the server waits for any MCP request before answering "Server unavailable". Must be greater than both timeouts above. |

TLS is left to whatever sits in front of the container.

## Fly

`fly.toml` describes one machine in one region with a volume at `/data`. `fly launch` copies it, asks for an app name and a region, creates the volume there and deploys:

    fly launch

It does not touch the `[env]` block, so if the app is not called `beamlet`, set `BEAMLET_URL` in `fly.toml` to the new hostname first. LiveView rejects sockets from any other origin.

Then set up the owner and create a token over SSH:

    fly ssh console --pty -C "bin/beamlet setup"
    fly ssh console -C "bin/beamlet tokens.create laptop"
