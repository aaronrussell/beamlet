# Beamlet — design

**Status:** Working note. Started 2026-09-13, deliberately light. It
records what is settled and grows one step at a time as the port
from `../omni_host` proceeds. Nothing here is carried over
unexamined; a decision appears when the code that needs it lands.

**Last updated:** 2026-09-15 (users and tokens store landed)

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
`config :beamlet, <Repo>`. Boot creates each file in WAL mode with
a single connection before its pool starts, because a pool opening
several connections on a file not yet in WAL mode races to switch it
and logs failed connects; `mix ecto.create` would not prevent this,
since `storage_up` ignores the adapter's WAL default, so the journal
mode is explicit in each repo's `init/2`. The `Ecto.Migrator` child migrates the
system database at every boot in every environment, so no consumer
runs a migration step and the test suite needs no `ecto.migrate`
alias. An authorizer on every agent database connection refuses
`ATTACH` and `DETACH`, so raw SQL granted to agents stays inside that
file (`Beamlet.SQLiteAuthorizer`).

### Users, tokens and principals

Settled 2026-09-14 (step 5). The vocabulary first, because the
words do the work:

- A **user** is a row in the system database: the durable name the
  operator creates and the history refers to. Id, name, timestamps,
  nothing else. No roles, no email, no login.
- A **token** is a credential belonging to one user: a random secret
  shown once at creation and stored as a hash, with a name and a
  **policy**. A user has many, one per client or device, and the
  same person holds a permissive token and a restricted one and uses
  them in different places. Delete is delete; nothing references a
  token row, so there is no revoked state, and no expiry.
- **Authentication** turns the bearer token on a request into its
  token row and user. It happens once per request, at the edge, and
  only Beamlet's own tokens are valid.
- The **principal** is what a request acts as: user id and name,
  token id and name, policy name, and the client's name and version
  when the client sent them. Built per request from the token, never
  stored. Every exec, define, commit and route keys on it.
- **Authorization** is checking what the principal may do, forward
  looking: the scanner enforcing the policy. **Provenance** is the
  record a persisted thing keeps of the principal that made it,
  backward looking. "Identity" is not a term of art here; the
  principal covers it.

**Policy attaches to the token, not the user.** A policy is a
named document (step 9 says what it contains); Beamlet ships
`default`, a token names one and has `default` when it names none.
Two policies for one person means two tokens, and the history names
both the user and the token, so nothing is lost. A request whose
token names a policy the config no longer defines fails clearly
rather than falling back.

**Identity is per request, with no session binding.** The protocol
is heading that way (the 2026-07-28 revision removes sessions) and
nothing here needs the alternative: server instructions never depend
on the token, so `print_policy` under the request's own token is how
a client learns what it may call.

**Management is operator-only.** The public functions of
`Beamlet.Users` are the product; step 8 puts a thin CLI over them. Nothing under `Host.*` creates, lists or deletes
users or tokens. Tests create a user and token through the same
functions, so every test authenticates the way production does.

**One context, structs at the root** (step 6): `Beamlet.Users` owns
users and their tokens, with `Beamlet.User` and `Beamlet.Token`
beside it and `Beamlet.Principal` to follow. A token is a
sub-resource of a user in every way that matters: it belongs to
one, dies with one, and is created and listed through one. The tell
was the arguments. Plain `create`, `update`, `delete`, `list`,
`find` and `find_by` take conventional arguments, attrs and structs,
so they stay predictable as fields arrive; a token function takes
the user it belongs to, which is what makes it a user operation
(`create_token(user, attrs)`, `list_tokens(user)`), and `authenticate`
turns a secret into its token with the user loaded. A separate
`Tokens` store was tried first and read wrong for exactly that
reason. The structs stay at the root rather than under the context
because `Beamlet.Users.User` stutters, and the root stays clear
because the code-mode machinery arrives under grouping namespaces of
its own. Ecto's own shapes throughout: a failed validation returns
the changeset, a miss returns `{:error, :not_found}`. User and token
names follow one rule, lowercase letters, digits, underscores and
hyphens, at most 64 characters, because a user name becomes a git
author email and both appear as trailer values. A token name is
unique per user, not per beamlet. The policy default lives on the
schema, not the column, so the database records no design decision.

The secret is 32 random bytes as unpadded URL-safe base64, the string
a client keeps. Only its SHA-256 is stored, a raw binary under a
unique index; a fast hash is right for a secret with that much
entropy. `Beamlet.Users.authenticate/1` hashes the presented string
as it is, with no decoding step, so a malformed value simply matches
nothing. The secret rides on a virtual field of the struct that
`create_token` returns and is nil on every token loaded afterwards.

### Provenance

One struct, two encodings. A route row stores the principal as
JSON in a map column; a commit carries it as git trailers, with the
user as the author (`alice <alice@beamlet>`) so `git log` and
`git blame` show a proper name. Both come from the same struct, so
they cannot disagree, and both decode back to it:

```
define: Shopping.Item

User: alice (1)
Token: laptop (3)
Policy: default
Client: claude-code 1.2.3
```

```json
{"user": {"id": 1, "name": "alice"}, "token": {"id": 3, "name": "laptop"},
 "policy": "default", "client": {"name": "claude-code", "version": "1.2.3"}}
```

Names first and ids beside them: the name is what a reader wants,
the id is what a program wants after a rename. Time is not in the
stamp; git and the row's timestamp already have it. Trailers because
git parses them natively, so a future history call filters by token
or policy with no code of ours. The route table lives in the agent
database, a different file from users and tokens, so there is no
foreign key to keep and no discrete columns: the set is small enough
to load and filter in memory. What carries provenance is exactly
what did in code mode, every commit the code server makes and every
route row. Not KV entries, not files, and there is no eval log.

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
the tools by mounting `Beamlet.MCP.Plug` at `/mcp`; `Beamlet.Router`
takes that over when it arrives.

Server instructions and each tool description are held under 2,048
bytes by tests: Claude Code truncates both at 2KB, and bytes are the
conservative measure against a client counting characters. The
instructions are a pointer block, what matters most first and the
stdlib for the rest.

**Authentication is Beamlet's own plug, not Anubis's authorization.**
`Beamlet.MCP.Plug` runs on every request, hashes the bearer secret,
loads the token and user, builds the principal and puts it in the
conn's assigns, which Anubis merges into the frame for every
callback; then it forwards to the transport plug. A missing or bad
token is a 401 with a plain `Bearer` challenge and a body saying how
to create a token. The step 4 pin on Anubis's `authorization:`
config was revised at step 5: that path is OAuth-shaped, requiring
`authorization_servers` and `resource` URLs and advertising
protected-resource metadata that sends a client without a token off
to an authorization server Beamlet does not have; its claims are
also absent from `init/2` and task-style tool calls. The instance's
public URL is therefore not a config key for authentication. Should
a login ever arrive, the metadata can then honestly point at Beamlet
itself.

### Web

Beamlet takes the endpoint as an option and owns the dynamic router
and layouts; the host forwards to `Beamlet.Router`. The host's
endpoint must carry the LiveView socket and static JS. The
library's test endpoint is that requirement written down, and the
server copies it.

## 3. Open

Decided as each step arrives, not before:

- The data dir layout, one path at a time as its owners land.
- Policy: what carries over from code mode and how named policies
  are declared (step 9).
- The exact stdlib surface, module by module (step 13).
- What the server instructions and tool descriptions say within a
  2KB budget per item (step 14).
- Deployment model, source-run or release (step 15).

### Direction for policy (2026-09-13, revised 2026-09-14)

Recorded so step 9 starts here rather than rediscover it; it may
revise it. Where policy attaches was settled at step 5 (§ 2, Users,
tokens and principals): on the token.

- **A policy is everything a principal may do:** the allow and deny
  lists, the stance options (`allow_defmacro`,
  `allow_dynamic_dispatch`), and capabilities (define, or exec
  only). One name answers "what may this principal do on my
  beamlet".
- **Beamlet ships `default`,** which cannot be changed: today's
  curated table, strict stance, both tools. A token naming no policy
  has it. Most beamlets never define another.
- **Policies are per token, not per beamlet.** The name policy is a
  check on the code a client submits, not an isolation boundary:
  anything one token is granted reaches the shared pool through a
  module it defines, exactly as a macro does under `allow_defmacro`
  today. That leak is accepted once and documented; it is not a
  reason to withhold the lever.
- **Named policies are application config, boot time.** Inert data,
  validated when app grants expand at boot, a bad one fails the boot.
  Set and restart, not reloaded. A prebuilt image will need an
  optional policies file merged at boot (step 15). How an operator
  declares one is step 9.

## 4. Deferred

- Admin UI and login.
- A principal handed in by an embedding host calling tools
  in-process, without a Beamlet token. Struck from § 2 at step 5;
  if it returns, a principal that encodes and decodes is the seam.
- User-scoped modules, routes, files and KV entries beside the
  shared ones. The user id on every principal is what it would key
  on.
- Supervised processes for agent code.
- Agent-installed dependencies.
- Static assets.
- The modern-era MCP protocol (2026-07-28); Anubis 2.0 is
  legacy-era and current clients negotiate it.
- Any dependency on Omni packages. If `omni` is ever added, it is as
  a library for agents to use, not as a foundation.
