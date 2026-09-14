# Beamlet — design

**Status:** Working note. Started 2026-09-13, deliberately light. It
records what is settled and grows one step at a time as the port
from `../omni_host` proceeds. Nothing here is carried over
unexamined; a decision appears when the code that needs it lands.

**Last updated:** 2026-09-14 (MCP server and tool names settled)

---

## 1. Framing

**Name:** Beamlet. **Package:** `beamlet`.

*A little Elixir server to make your own.*

Beamlet is a programmable Elixir code server for AI agents. Agents
can define modules, execute code, and build APIs and live dashboards
inside a running application. Available as an embeddable Elixir
package and a standalone MCP server, independently of Omni.

A small, persistent computing environment to tinker with, not a
disposable code runner. Primarily for Elixir developers having fun
building things with agents, rather than an enterprise automation
platform. The tone is friendly, curious and technically fluent:
playful without being childish, concrete rather than full of AI
hype.

### Language

- **Beamlet** is the project.
- **A beamlet** is a running instance.
- **My beamlet** is where your code and applications live.

The name works in prompts: "What routes exist on my beamlet?" "Add a
dashboard to my beamlet." The agent works *on* your beamlet; it is
not the beamlet. Different agents and clients interact with the same
environment.

"A beamlet" is the only new noun. Everything else stays ordinary:
modules, routes, tools, applications, users, tokens.

### Why the name

Short, memorable, connected to the BEAM. The diminutive suggests
something approachable and personal, a little computer you can make
your own. It names the thing itself without "server" or "instance"
appended.

## 2. Settled

What follows was settled at the 2026-09-13 shaping conversation, on
the back of building code mode in `../omni_host` and the MCP spike
that proved it works from external clients. Each is a starting
position, held until the code says otherwise.

### One package, one nested server

```
beamlet/                 the repo and the hex package
  lib/host/              Host.*          agent-facing stdlib
  lib/beamlet/           Beamlet.*       machinery, databases, users, web pieces
  lib/beamlet/mcp/       Beamlet.MCP.*   Anubis server and tool components
  server/                beamlet_server  the standalone Phoenix app, path dep on `..`
  Dockerfile             builds and runs the server
```

The library is a **child spec** a host starts in its own supervision
tree; it declares no OTP application of its own. This keeps boot
ordering in the host's hands, lets tests start and stop a beamlet
per test, and makes the standalone server the smallest possible
consumer rather than a special case.

The server test: `server/` holds nothing a second embedder would
want. Endpoint, application module, config, release, Dockerfile.
Anything else belongs in the library, including a future admin UI,
which ships as LiveViews behind a router macro the host mounts.

### Two surfaces

`Host.*` is what agent code reads and calls. `Beamlet.*` is what the
operator and the embedding host use. The name `Host` is kept from
code mode on purpose: it reads well ("the host of my code") and
agent-facing vocabulary is the most expensive thing to rename once
it lives in docs, teaching errors and model habits.

### Two databases

Both Beamlet's, both under the data dir:

- **Agent database** (`Host.Repo`): tables agents migrate and query,
  the key/value table, and the route table. Everything an agent
  builds, so it wipes and backs up as one unit.
- **System database** (`Beamlet.Repo`): users and tokens. Migrated
  by Beamlet itself at boot from the package's priv dir.

Both live under `db/` in the data dir, `agent.db` and `beamlet.db`,
with SQLite's `-wal` and `-shm` sidecars beside them. The paths are
derived, never configured; adapter options for either repo go under
`config :beamlet, <Repo>`. The `Ecto.Migrator` child migrates the
system database at every boot in every environment, so no consumer
runs a migration step and the test suite needs no `ecto.migrate`
alias. An authorizer on every agent database connection refuses
`ATTACH` and `DETACH`, so raw SQL granted to agents stays inside that
file (`Beamlet.SQLiteAuthorizer`).

### Principal and authentication

The **principal** (user, stance, policy) is what every exec, define,
commit and route keys on. **Authentication** turns a bearer token on
an MCP request into a principal, at the plug. Beamlet owns both and
exposes them separately: the standalone server and an embedding
host both get an authenticated `/mcp` for free, while a host calling
tools in-process hands a principal in directly and Beamlet never
learns about that host's users.

### Config

One surface: `:beamlet` application config, read at runtime through
`Beamlet.Config` accessors, so a release or container sets it from
the environment in `runtime.exs`. No start options carry
configuration, nothing is read at compile time, nothing is stashed.
`data_dir` is the root everything a beamlet persists lives under;
starting checks it exists and fails the boot otherwise, and the
modules owning paths beneath it add their accessors as they arrive.
Tests use one data dir per run, `tmp/test_data` in the repo, wiped
at the start of each run; a test that needs its own directory gives
it to the component directly rather than through config.

### MCP

`Beamlet.MCP.Server` (Anubis, Streamable HTTP) runs as a child of
`Beamlet` and serves two tools, `define` and `eval`. Unprefixed: the
protocol makes names unique per server and clients namespace across
servers themselves (Claude Code shows `mcp__beamlet__eval`), so a
`code_` prefix would only repeat the server name. `eval` rather than
`exec` because the tool evaluates an expression and returns its
result, which is what Elixir calls it. Schemas carry only what the
tool needs; there is no per-call description field, since the
client owns its UI and already shows the arguments. A host serves
the tools by mounting `Anubis.Server.Transport.StreamableHTTP.Plug`
with `server: Beamlet.MCP.Server`; `Beamlet.Router` takes that over
when it arrives.

Server instructions and each tool description are held under 2,048
bytes by tests: Claude Code truncates both at 2KB, and bytes are the
conservative measure against a client counting characters. The
instructions are a pointer block, what matters most first and the
stdlib for the rest.

Authorization is off until step 6. Its shape, pinned now: an
`authorization:` keyword on the server naming a
`Anubis.Server.Authorization.Validator` over Beamlet's token store,
plus the `authorization_servers` and `resource` URLs the config
requires, with `Beamlet.Router` mounting the `WellKnown` plug beside
`/mcp`. `resource` makes the instance's public URL a config key;
what the metadata says for a server issuing its own tokens is
step 5.

### Web

Beamlet takes the endpoint as an option and owns the dynamic router
and layouts; the host forwards to `Beamlet.Router`. The host's
endpoint must carry the LiveView socket and static JS. The
library's test endpoint is that requirement written down, and the
server copies it.

## 3. Open

Decided as each step arrives, not before:

- The data dir layout, one path at a time as its owners land.
- The user and token model, and what the MCP authorization
  metadata says for a server that issues its own tokens (step 5).
- Policy: what carries over from code mode and how named policies
  are declared (step 8).
- The exact stdlib surface, module by module (step 12).
- What the server instructions and tool descriptions say within a
  2KB budget per item (step 13).
- Deployment model, source-run or release (step 14).

### Direction for policy and identity (2026-09-13)

Recorded so steps 5 and 8 start here rather than rediscover it;
either may revise it.

- **A policy is everything a principal may do:** the allow and deny
  lists, the stance options (`allow_defmacro`,
  `allow_dynamic_dispatch`), and capabilities (define, or exec
  only). One name answers "what may this principal do on my
  beamlet".
- **Beamlet ships `:default`:** today's curated table, strict stance,
  both tools. A user with no policy has it. Most beamlets never
  define another.
- **Policies are per user, not per beamlet.** The name policy is a
  check on the code a client submits, not an isolation boundary:
  anything one user is granted reaches the shared pool through a
  module they define, exactly as a macro does under
  `allow_defmacro` today. That leak is accepted once and documented;
  it is not a reason to withhold the lever.
- **Named policies are application config, boot time.** Inert data,
  validated when app grants expand at boot, a bad one fails the boot.
  Set and restart, not reloaded. A prebuilt image will need an
  optional policies file merged at boot (step 14).
- **Policy attaches to the user; tokens are credentials.** A user is
  the durable identity that commits, routes and the audit trail
  name. A token is a named, revocable secret authenticating as a
  user; a user has many. Two policies means two users, because it
  also means two names in the history. A request whose user names a
  policy config no longer defines fails clearly rather than falling
  back to `:default`.

## 4. Deferred

- Admin UI and login.
- Supervised processes for agent code.
- Agent-installed dependencies.
- Static assets.
- The modern-era MCP protocol (2026-07-28); Anubis 2.0 is
  legacy-era and current clients negotiate it.
- Any dependency on Omni packages. If `omni` is ever added, it is as
  a library for agents to use, not as a foundation.
