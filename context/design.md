# Beamlet — design

**Status:** Working note. Started 2026-09-13, deliberately light. It
records what is settled and grows one step at a time as the port
from `../omni_host` proceeds. Nothing here is carried over
unexamined; a decision appears when the code that needs it lands.

**Last updated:** 2026-09-13

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
ordering in the host's hands, lets tests start a beamlet per test
against a scratch data dir, and makes the standalone server the
smallest possible consumer rather than a special case.

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
- **System database**: users and tokens. Migrated by Beamlet itself
  at boot from the package's priv dir.

### Principal and authentication

The **principal** (user, stance, policy) is what every exec, define,
commit and route keys on. **Authentication** turns a bearer token on
an MCP request into a principal, at the plug. Beamlet owns both and
exposes them separately: the standalone server and an embedding
host both get an authenticated `/mcp` for free, while a host calling
tools in-process hands a principal in directly and Beamlet never
learns about that host's users.

### Web

Beamlet takes the endpoint as an option and owns the dynamic router
and layouts; the host forwards to `Beamlet.Router`. The host's
endpoint must carry the LiveView socket and static JS. The
library's test endpoint is that requirement written down, and the
server copies it.

## 3. Open

Decided as each step arrives, not before:

- The data dir layout (step 2).
- The user and token model, and what the MCP authorization
  metadata says for a server that issues its own tokens (step 5).
- Policy: what carries over from code mode, and whether policy is
  per beamlet, per user, or both (step 8).
- The exact stdlib surface, module by module (step 12).
- What the server instructions and tool descriptions say within a
  2KB budget per item (step 13).
- Deployment model, source-run or release (step 14).

## 4. Deferred

- Admin UI and login.
- Supervised processes for agent code.
- Agent-installed dependencies.
- Static assets.
- The modern-era MCP protocol (2026-07-28); Anubis 2.0 is
  legacy-era and current clients negotiate it.
- Any dependency on Omni packages. If `omni` is ever added, it is as
  a library for agents to use, not as a foundation.
