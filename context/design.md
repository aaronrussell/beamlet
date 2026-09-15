# Beamlet — design

**Status:** Working note. Started 2026-09-13, deliberately light. It
records what is settled and grows one step at a time as the port
from `../omni_host` proceeds. Nothing here is carried over
unexamined; a decision appears when the code that needs it lands.

**Last updated:** 2026-09-15 (policy at the edges, step 11)

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
consumer rather than a special case. `start_link/1` takes
`only: :system` to start the policies and the system database alone,
migrated, which is what the operator CLI needs in a VM with no
beamlet running (step 11); the knowledge of a beamlet's processes
stays in `Beamlet.init/1`.

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
  token id and name, policy name. Built per request from the token,
  never stored. Every exec, define, commit and route keys on it. The
  client's name and version are not on it (revised at step 7): they
  are connection metadata, the token is the provenance, and a user
  knows where each of their tokens is used. `Beamlet.Principal` is
  flat, five fields; the encodings below do the nesting.
- **Authorization** is checking what the principal may do, forward
  looking: the scanner enforcing the policy. **Provenance** is the
  record a persisted thing keeps of the principal that made it,
  backward looking. "Identity" is not a term of art here; the
  principal covers it.

**Policy attaches to the token, not the user.** A policy is a
named document (§ 2 Policy says what it contains); Beamlet ships
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
`Beamlet.Users` are the product; `Beamlet.CLI` is a thin shell over
them (step 8). Nothing under `Host.*` creates, lists or deletes users
or tokens. `Beamlet.Case` creates a user, `alice`, and one token for
every test through the same functions, so every test authenticates
the way production does.

The CLI is one function, `Beamlet.CLI.main/1` over argv, printing
plain text and returning `:ok` or `:error`, and each environment
gets a thin entry that calls it: `mix beamlet` in development, a
`bin/beamlet` script in the release (step 17). Mix tasks were the
first idea and lost to the release, which has no Mix; the module is
the one implementation and the entries stay a few lines. Commands
are dotted, `users.create USER`, `tokens.create USER TOKEN`, and
address everything by name; a token name is unique per user, so
every token command names the user first. Delete asks nothing and
says what it removed. The CLI needs the policies and the system
database and nothing an agent reaches: when no beamlet runs in the
VM it starts that half of one with `Beamlet.start_link(only: :system)`,
runs the command and stops it, so it works beside a beamlet in
another VM or with none at all, and a bad policy declaration fails
the command with the boot's own error; a beamlet in the same VM is
used as it is. Starting the repo by hand was the first shape and
lost at step 11 to the option, so that which processes a beamlet has
is written in one place. `--policy` on `tokens.create` and
`tokens.update`, `policies` listing the declared names and
`policies.show NAME` rendering one arrived at step 11 (§ 2 Policy).

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

### Policy

Settled 2026-09-15 (step 9). Code mode had three mechanisms at three
scopes: grants were host-wide config from a DSL file with reload,
the two shape rules sat per agent on its definition, and tool access
was per agent as `code_mode: true`. Its own record left the mismatch
open. In Beamlet all of it is one document, and a token names one.

The vocabulary:

- A **policy** is a named document saying what a token's requests
  may do on a beamlet. Three parts: tools, rules, grants. One name
  answers the question.
- **Tools** are which of the beamlet's MCP tools the token may use,
  `eval` and `define` today.
- **Rules** are the shape rules on submitted code, `allow_defmacro`
  and `allow_dynamic_dispatch`, strict by default. They are
  submission rules, not execution rules: they govern what a token
  may author into the shared pool, never what it may call.
- **Grants** are the name table: a module maps to `:all`, `only` or
  `except` at function/arity granularity, and absence is denial.
  The verbs are `allow` and `deny`.
- **`default`** is the policy Beamlet ships: the curated grants,
  strict rules, both tools. It cannot be declared or changed, every
  other policy builds on it, and a token has it when it names none.
- The **effective grants** are a policy's grants plus every defined
  module, granted by existence. The shared pool is the one thing
  that is not per policy: anything one token is granted reaches the
  pool through a module it defines, as a macro does under
  `allow_defmacro`. Accepted once, here, and documented for the
  operator; not a reason to withhold the lever.
- **Signage** is the teaching copy for the default's deliberate
  denials, by category. It is Beamlet-wide, not part of any policy:
  a policy that re-grants `File` silences its signage, a policy that
  denies `Enum` gets the generic copy.
- The **curation record** is the data behind `default` and the
  coverage walk that proves every documented platform module has a
  ruling, carried over from code mode.

Retired words: *stance* (the rules on the policy), *amendment*
(there is no host-wide table to amend, only declarations in a
policy), *whitelist* and *name policy* (grants), and *code mode* in
anything an agent reads, where a refusal now says "not permitted by
your policy".

**A policy is data, declared in application config, validated and
resolved at boot, never stored.** Not a file the library reads, not
a module, not a row:

```elixir
config :beamlet,
  policies: [
    explorer: [
      tools: [:eval],                          # replaces the default's list
      rules: [allow_dynamic_dispatch: true],   # merges into the default's rules
      allow: [Task, {File, only: [read: 1]}],  # replaces the module's entry
      deny: [Host.Repo, Req, Req.Request]      # removes the entry
    ]
  ]
```

Config is already the one surface, read at runtime, so an embedder
writes this in their own config and a release sets it from
`runtime.exs` with nothing new to learn. Validation is a function
over data: a teaching error names the policy and the key and fails
the boot. Code mode's DSL, reader, reloader and diff do not
migrate; the verbs survive as keys. The alternatives each lost on
one point. A DSL file in the data dir reads a little nicer but is a
second declaration surface that evaluates code at boot for what is
a document. Rows in the system database suit things the product
creates at runtime, and a policy is authored; a dozen entries
through CLI flags ends in an import command, at which point the file
is the truth and the row a stale copy. A module suits an embedder
and is unreachable from a container.

The document, applied as `default`, then `allow`, then `deny`:

- `tools` replaces the default's list when given.
- `rules` merges: a key given overrides, a key absent stays strict,
  an unknown key fails the boot. New shape rules get a home here
  without widening the top level.
- `allow` replaces the module's entry wholesale, the default's
  included, so `allow: [Kernel]` re-enables `apply`, the operator's
  deliberate call. `only:` and `except:` are relative to the
  module's full surface.
- `deny` removes the module's entry. It applies after `allow`, so a
  module in both keys is denied, documented rather than an error;
  denying a module nothing grants is a no-op.
- Order inside a key does not matter, a module named twice in one
  key is an error, every module named must be loadable on the
  beamlet, and every function under `only:` or `except:` must be
  exported at that arity, as a function or macro, so a typo fails
  the boot rather than granting nothing (step 10 extended the check
  from modules to functions; it is a few lines and the same
  argument).
- Policy names follow the user and token name rule; `default` is
  reserved.
- Declare and restart. No reload.

Two keys were considered and left out. `extends` between custom
policies: every policy extends `default`, and chains are a
speculative need. `allow_app`: which packages exist is a property
of the runtime, not of a policy. The default grants the packages
the beamlet ships, `jason` and `req`, each expanded at boot into
per-module entries with `@moduledoc false` modules excluded,
exactly as code mode expanded its bundled dependencies, so it
always expands. Jason stays beside Elixir's `JSON` because models
reach for it by training, and turning them away teaches nothing. A custom
policy speaks only in modules; an embedder granting their own
package lists its modules under `allow`, and agent-installed
dependencies (§ 4) will decide who grants those. `deny` is per
module, so closing HTTP for a policy names the package's entry
points, `Req` and `Req.Request`, which is short for any package; a
`deny_app` can arrive when a policy needs it.

**Enforcement** sits at three edges and one gate:

- **Tools.** The listing is per request: `Beamlet.MCP.Server`
  overrides `handle_request/2` to filter the `tools/list` reply by
  the principal's policy and to refuse a `tools/call` for an
  ungranted tool before dispatch, delegating everything else to
  Anubis. A listed tool is a promise, and a model that never sees
  `define` never reaches for it. The refusal is the JSON-RPC error
  Anubis returns for a tool that does not exist, since to that token
  it does not: the listing never showed it, and a distinct "not in
  your policy" message was considered and dropped at step 11. An
  HTTP error on a `tools/call` POST would read as a transport failure
  to a client. Anubis's own per-component `scopes` does exactly this
  but reads only its OAuth claims, which step 5 rejected, so under
  Beamlet's plug they are always empty. No list-changed
  notifications: a policy change is a restart.
- **A missing policy.** A token naming a policy the config no
  longer declares is a 403 from `Beamlet.MCP.Plug` on every
  request, with a one-line body naming the token and the policy,
  the shape of the 401 beside it. The token authenticated and the
  server considers the credential insufficient, which is what 403
  means; 400 would send a client developer to their JSON. Failing
  at `initialize` is what makes it visible to the person connecting
  the client.
- **The token.** `Beamlet.Token`'s changeset validates the policy
  name against the declared names (`Beamlet.Policies.names/0`), so
  the store refuses a token for a policy that does not exist and the
  CLI's error comes from the changeset. A token whose policy has
  since left the config is therefore made in tests by writing the
  row directly, standing in for the restart that removed it. The principal is unchanged, five flat fields with the
  policy name; the components fetch the resolved policy by name.
- **The scanner** is the gate for rules and grants, as in code
  mode, taking the policy struct in place of a table and a stance.
  Boot compiles carry no gate, and tightening a policy never evicts
  a module: adjudication is submission-time only.

`Host.Code.print_policy/0` renders the calling token's policy, by
name: tools, rules in force, the deliberate denials it has not
re-granted, partial grants. Tool descriptions and server
instructions stay static, as step 5 settled, so code mode's
per-stance line in the exec description goes and an eval-only
token reads a sentence about `define` in the instructions while its
listing omits the tool; the step 16 copy pass phrases the
instructions to survive that. The same rendering serves the
operator as `beamlet policies.show NAME`, beside `beamlet policies`
listing the declared names and `--policy` on `tokens.create` and
`tokens.update`.

The shape in code, built at step 10 and completed at 11 and 12:
`Beamlet.Policy` holds the struct (name, tools, rules, grants),
`build/2` with the document validation, the grant lookups, and
`render/1`; public, its moduledoc the operator's reference
including what each relaxed rule reaches. `Beamlet.Policy.Rules` is
the rules struct with strict defaults. `Beamlet.Policy.Default` is
the curation record, grants and signage and the not-granted walk,
with the moduledoc rendered from the data, package expansion
private to it, and the golden fixture pinning the composed table.
`Beamlet.Policies` is a `GenServer`, the first child of `Beamlet`,
that builds `default` and every declared policy in its init and
loads them into an ETS table it owns, so a bad declaration fails
the boot, a lookup is one read in the caller with no message to a
process, and the policies live exactly as long as the beamlet;
`:persistent_term` was the alternative and lost on lifetime, since
it outlives the supervisor. `fetch/1` and `names/0` are its whole
surface, and `Beamlet.Config.policies!/0` reads the declarations.
`Beamlet.Scanner` scans against a policy (step 12), and the exec
runner stashes one ambient value, the principal, where code mode
stashed an agent name and a stance (step 13). A test declares the
policies its beamlet has with `@tag policies: [...]`, in the shape
config takes, which `Beamlet.Case` puts into config before the
beamlet starts and removes after (step 11); a fixed set in the test
config was the alternative and lost on each test saying what it
expects.

Small calls made at step 10: policy names are strings everywhere
outside config, where keyword keys are atoms because that syntax
reads best; `tools: []` is accepted, since nothing needs a special
case for it; the valid tool names are a list on `Beamlet.Policy`,
not read from the MCP server, and step 11 tests that the server's
components match; the rendering opens with the policy's name and
tools and then reads as code mode's did, rules in force, deliberate
denials not re-granted with their reasons, partial grants. The
one-line-per-module renderer for the golden fixture is test support.

What migrated straight across at step 10: the grant maps for
Elixir, Erlang, the exception families and `__MODULE__`; the web
and data rows and Ecto's exception family, since `phoenix`,
`phoenix_html`, `phoenix_live_view`, `req` and `jason` were added as
dependencies at the same time; `Host.Repo`'s row; the table type
and the package expansion; the curation coverage tests and golden
fixture; the rendering. The seven remaining host rows (`Host.Code`,
`Host.FS`, `Host.KV`, `Host.Migrator`, `Host.PubSub`, `Host.Router`,
`Host.Web`) join the default at step 15 as each module lands, one
line each; no stub modules were written to carry them early. The
signage copy that names those modules came across as written, since
the names are settled. What changes: one cached table becomes a
table per policy, the stance struct becomes the rules struct,
`scan_exec` becomes `scan_eval`, and the copy loses "code-mode" and
"for this agent". Code mode's open question about two re-grant
mechanisms of different scope is resolved by construction:
everything is per policy, and only the pool is shared.

Deliberately out: exec limits per policy, since they are how much
rather than what and stay ordinary config; reload; operator-added
signage; a policy built on an empty table rather than on `default`.

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
```

```json
{"user": {"id": 1, "name": "alice"}, "token": {"id": 3, "name": "laptop"},
 "policy": "default"}
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
`Beamlet.MCP.Plug` wraps the transport plug with the server baked
in, so a host mounts `forward "/mcp", Beamlet.MCP.Plug` and nothing
else. It runs on every request and method: reads the `Bearer`
secret, authenticates it through `Beamlet.Users`, and puts the
principal in the conn's assigns as `:principal` before forwarding.
Anubis re-merges the conn's assigns into the frame on every request,
so `frame.assigns.principal` in a callback is always the current
request's, which is what makes identity per request rather than per
session. A missing token, another scheme or an unknown secret is a
401 with a plain `Bearer` challenge and a one-line body; the status
and the challenge carry the message, nobody reads a 401 body. The
step 4 pin on Anubis's `authorization:`
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
- The exact stdlib surface, module by module (step 15).
- What the server instructions and tool descriptions say within a
  2KB budget per item (step 16).
- Deployment model, source-run or release (step 17). Decided in
  principle at step 9: the library's only declaration surface is
  application config, and the server's release merges an optional
  operator config file from the data dir into it at boot through a
  config provider, a plain `import Config` file. An operator with a
  mounted data dir writes the file, restarts the container and
  creates the token with `--policy`; the release's `eval` entry
  runs config providers, so the CLI in the container sees the same
  policies.

## 4. Deferred

- Admin UI and login.
- A principal handed in by an embedding host calling tools
  in-process, without a Beamlet token. Struck from § 2 at step 5;
  if it returns, a principal that encodes and decodes is the seam.
- User-scoped modules, routes, files and KV entries beside the
  shared ones. The user id on every principal is what it would key
  on.
- Supervised processes for agent code.
- Agent-installed dependencies, and with them who grants an
  installed package to agent code.
- Package-level denial in a policy (`deny_app`) and reloading
  policies without a restart, each when a policy needs it.
- Static assets.
- The modern-era MCP protocol (2026-07-28); Anubis 2.0 is
  legacy-era and current clients negotiate it.
- Any dependency on Omni packages. If `omni` is ever added, it is as
  a library for agents to use, not as a foundation.
