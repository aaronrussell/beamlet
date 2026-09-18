# Beamlet — design

**Status:** Working note. Started 2026-09-13, deliberately light. It
records what is settled and grows one step at a time as the port
from `../omni_host` proceeds. Nothing here is carried over
unexamined; a decision appears when the code that needs it lands.

**Last updated:** 2026-09-17 (`Host.Web` and `Host.Router`, step 15e)

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

**Where the machinery behind a `Host` module lives** (settled
2026-09-16, before step 15). `Host.X` is the agent surface: it
prints, raises with teaching copy, returns plain values, and is
granted wholesale by the policy, so it holds only what an agent may
call. The implementation sits in a root-level `Beamlet.*` module
only when it earns its place: something else in Beamlet calls it,
or it is a real subsystem, a context over a table, a process, a
generator. Otherwise `Host.X` is the whole thing. The two sides
share a leaf name when they are the same thing seen from each side
(`Beamlet.Code` and `Host.Code`, `Beamlet.Repo` and `Host.Repo`),
and a table follows the context convention (`Beamlet.Routes` owning
`Beamlet.Route`, with `Host.Router` as the agent face). A support
module has a moduledoc when an embedder might call it and
`@moduledoc false` otherwise. Not testability: a `Host` module is a
plain module a test calls directly. Two other shapes lost. A
sub-namespace for "the machinery with a `Host` face" is not a real
category, since `Beamlet.Code` serves a tool and `Host.Code` alike
and the route table will serve `Host.Router`, discovery and remove.
Nesting the implementation inside the `Host` module puts it in the
agent's territory, where the listing, the reserved-prefix check and
the moduledoc rule would all need a special case. Nothing under
`Beamlet.*` is granted, so the split is what keeps the machinery
out of reach by construction.

**Where a schema sits** (settled 2026-09-17, step 15d). A schema
that is a resource of a public context sits at the root beside it,
singular: `Beamlet.User` beside `Beamlet.Users`, `Beamlet.Route`
beside `Beamlet.Routes`. A schema that is a private detail behind a
`Host` module with no context nests under that module's internal
namespace with `@moduledoc false`: `Beamlet.KV.Entry` is the
encoding of `Host.KV`'s rows and nothing outside the module touches
it. The two styles looked like a conflict and are the one rule
applied to a public resource and to an implementation detail.

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

**Beamlet's own tables in the agent database** (settled 2026-09-17,
step 15c) are created by `Beamlet.Tables`, a synchronous child right
after `Host.Repo` that runs `CREATE TABLE IF NOT EXISTS` for each
and returns `:ignore`, so a failure fails the boot and a table agent
code dropped is back at the next one. The double-underscore names
(`__kv` and `__routes`) mark them as furniture: Beamlet's
tables holding the agent's data, outside the agent's migration
history and inside the unit that wipes and backs up. A second
`Ecto.Migrator` over `Host.Repo` lost: `migration_source` is repo
config, so the agent's migrations would share it, and Beamlet's
history would sit in the agent's database beside theirs. Pre-release
a shape change is a wipe. The path for one after release is
`PRAGMA user_version`, the integer SQLite keeps in the file header:
the module becomes an ordered list of steps, runs the ones above the
stored version and stores the new one, with no tracking table and
no change to either Ecto migrator. That trades away the free
recreation of a dropped table, accepted when it comes.

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
- The **system principal** (step 15a) is what the beamlet acts as on
  its own behalf: user and token both named `beamlet` with id 0,
  which the database never issues, under `default`. It is named
  `beamlet` rather than `system` because that is the name already on
  every commit's committer line and on the sweep's author line, so a
  reader of `git log` sees one name for the beamlet itself; the user
  name is reserved in the changeset so the record never names two
  things. The boot sweep uses it, so every commit carries trailers
  and the audit has one shape of commit rather than two, and it is
  the seam a future in-process embedder would hand in. Nothing falls
  back to it: a `Host.*` function that needs a principal and finds
  none raises, since the unanticipated case should be loud.
- **A principal is a token acting through a tool; a web identity
  is a user on a request; nothing turns one into the other**
  (settled 2026-09-17, step 15d). The principal carries a policy
  because the tools are where code is authored and discovered, and
  the policy governs exactly those two things; it is ambient in the
  process only because evaluated code takes no arguments. A served
  route is neither: its code was scanned when it was defined, under
  its author's policy, and nothing more is authored when it runs.
  So a route acts as nobody, the `Host.*` functions that record who
  acted or filter by policy raise inside one, and a controller
  action that removes modules or unmounts routes is not a supported
  case. A future logged-in user is a web identity: a user known to
  the request, carried on the conn or the socket the way Phoenix
  carries `current_user` and checked by a plug or an `on_mount`
  hook, with no token and no policy, since a browser authors no
  code. If a page ever changes the beamlet, that is the admin UI
  calling `Beamlet.*` with an explicit record of who acted, not
  agent code reaching for tool-side verbs.

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
- **Signage** is the teaching copy appended to a refusal, for the
  few names where "not permitted by your policy" would leave an
  agent guessing (revised at step 12, below). It is Beamlet-wide,
  not part of any policy, and a lookup takes the policy so the copy
  stays true for it.
- The **curation record** is the data behind `default` and the
  coverage walk that proves every documented platform module has a
  ruling, carried over from code mode.

Signage was reviewed clause by clause at step 12, because code
mode's coverage walk had made it one of three buckets and so the
home for every deliberate denial, sixty-odd modules across ten
categories, much of it copy that a custom policy falsified. Two
kinds earn a place. A **redirect** names the door the agent would
not guess: `File` is refused, `Host.File` is where scoped file access
lives; likewise `Host.KV` for `Agent` and the ETS family, `Host.Repo`
for `Ecto.Repo`, `Host.Router`, `Host.PubSub`, `Host.Migrator`, and
the `define` tool for `Code`. A **closure** says a whole family is
withheld, so the agent stops walking its siblings; it pays for
itself only over a family the model predictably walks, which is
process primitives and the environment (with the reason it may hold
credentials, which changes the agent's plan). The shell and dynamic
categories were cut, the generic copy doing the same work, and
every closure lost its members that a model never reaches for as a
sibling. A policy that grants a signed module never refuses it, so
its hint never fires; a redirect whose door the policy withholds,
whether a `Host.*` module it denies or has not yet got, or the
`define` tool, is dropped, since a pointer at a closed door is the
one hint that misleads. Each `Host.*` redirect therefore lights up
exactly when its row lands at step 15. Everything else denied gets
the generic copy, and the not-granted record carries the reason.

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
the curation record, grants and the not-granted walk, with the
moduledoc rendered from the data, package expansion private to it,
and the golden fixture pinning the composed table.
`Beamlet.Policy.Signage` is the sparse overlay of teaching copy:
categories with their copy and door, the module and function maps,
`hint/2` and `hint/3` taking the policy, and `denials/1` for the
rendering; a test proves every signed name is denied under the
default. `Beamlet.Policies` is a `GenServer`, the first child of `Beamlet`,
that builds `default` and every declared policy in its init and
loads them into an ETS table it owns, so a bad declaration fails
the boot, a lookup is one read in the caller with no message to a
process, and the policies live exactly as long as the beamlet;
`:persistent_term` was the alternative and lost on lifetime, since
it outlives the supervisor. `fetch/1` and `names/0` are its whole
surface, and `Beamlet.Config.policies!/0` reads the declarations.
`Beamlet.Scanner` (step 12) is code mode's scanner taking the
policy struct and nothing else, `scan_eval(code, policy)` and
`scan_define(code, policy)`, with the rules read from it and the
hints looked up through it; the effective grants' other half, every
defined module, is merged into the policy by the caller once the
code server exists (step 14). The exec runner stashes one ambient
value, the principal, where code mode stashed an agent name and a
stance (step 13). A test declares the
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

At step 15a `Host.Code` and `Host.PubSub` joined the default whole,
and `Macro` moved from the not-granted walk to a partial grant of
`underscore/1`, `camelize/1` and `to_string/1`, the string helpers
agent code names tables and files with, everything that builds or
expands code staying denied. What migrated straight across at step
10: the grant maps for
Elixir, Erlang, the exception families and `__MODULE__`; the web
and data rows and Ecto's exception family, since `phoenix`,
`phoenix_html`, `phoenix_live_view`, `req` and `jason` were added as
dependencies at the same time; `Host.Repo`'s row; the table type
and the package expansion; the curation coverage tests and golden
fixture; the rendering. The seven remaining host rows (`Host.Code`,
`Host.File`, `Host.KV`, `Host.Migrator`, `Host.PubSub`, `Host.Router`,
`Host.Web`) joined the default through step 15 as each module
landed, one line each, the last two at 15e; no stub modules were
written to carry them early, and every signage door is now a module
the default grants, so each redirect fires under it. The
signage copy that names those modules came across as written, since
the names are settled, and was then slimmed at step 12. What
changes: one cached table becomes a table per policy, the stance
struct becomes the rules struct, `scan_exec` becomes `scan_eval`,
and the copy loses "code-mode" and "for this agent". Code mode's open question about two re-grant
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
route row. Not KV entries, not files, and there is no eval log. The
trailers landed at step 14 with the audit (§ 2 Define); the JSON
landed at step 15d on `Beamlet.Route`, as
`Beamlet.Principal.to_map/1` and `from_map/1`, a map column the
row stores and `Beamlet.Route.principal/1` reads back.

### Eval

Settled 2026-09-16 (step 13). `Beamlet.Eval` is the runtime behind
the `eval` tool: `run(code, principal, opts)` fetches the policy by
the principal's name, scans, evaluates and returns the result or the
error as text, and `Beamlet.MCP.Eval` maps the tuple to a tool
result. Nothing sits between them: the component is the tool, and
code mode's `Omni.Tool` layer with its per-call `active_description`
went. The output contract is code mode's: what the code printed,
then `=> ` and the inspected last expression, with a refused call,
an exception, a timeout or a memory kill as error text that keeps
the output printed before it. Each run is a fresh evaluation in the
beamlet's VM, empty bindings, no prelude.

**Two processes, tied one way.** Anubis runs every request in a
task of its own and answers `notifications/cancelled` by
terminating that task, so the tool process is Anubis's. The code
runs in a child under `Beamlet.TaskSupervisor` so that the timeout
and the heap cap can kill it while the tool process survives to
report with partial output; the tool process owns the StringIO for
the same reason. The child is not linked, since those two kills
would take the tool process down, and a monitor alone cannot tell
the child its caller was cancelled: code mode's runner left the
code running to its own timeout after a cancel, the gap the MCP
spike found. Erlang has no one-way link, so a watcher provides it:
a third process monitors the tool process and kills the child when
it goes. Trapping exits in the tool process was the alternative and
lost, since it sets a flag on a process Anubis owns and makes the
runner answer the supervisor's shutdown itself. Closing the HTTP
stream cancels nothing in Anubis 2.0; the notification is the only
cancel signal.

**Three limits**, `config :beamlet, eval: [...]`, each named for
what it protects: `timeout` (30 seconds) the session, since a
session runs one request at a time; `max_heap_bytes` (256MB) the
beamlet; `max_output` (16KB) the model's context. The transport's
`request_timeout` is derived from the eval timeout plus a margin: it
is a call timeout that answers "Server unavailable" and leaves the
request running, so it must never fire first. 16KB stays because
inspected Elixir runs three to four bytes a token, which puts a full
result at four to five thousand tokens, under Claude Code's
10,000-token warning (its default cap is 25,000, past which it
writes the result to a file and hands the model the path), and
because the inline tail teaches where a client's file fallback does
not. The inspect limits are constants; nobody tunes how one value
renders per beamlet. Agents get no per-call limits; `opts` on
`run/3` are for tests.

**The ambient principal.** Evaluated code takes no arguments, so the
runner puts the principal in the child's process dictionary before
the code runs (`Beamlet.Principal.put_current/1`) and the stdlib
functions that must record who acted read it back (`current/0`);
outside evaluated code it is nil. The value is the principal alone,
where code mode stashed an agent name and a stance, and the policy
is fetched by name. A tool that holds the principal passes it
explicitly. No separate module: two functions on the struct's own.

### Define

Settled 2026-09-16 (step 14). `Beamlet.Define` is the runtime behind
the `define` tool, the shape eval set: `run(code, principal, opts)`
fetches the policy, scans (`Beamlet.Scanner.scan_define/2`), runs the
docs gate (`Beamlet.Code.Docs`) and hands the buffer to the code
server; `Beamlet.MCP.Define` maps the tuple to a tool result. Code
mode's tool layer with its option merging and test seam went the
way eval's did. The define semantics migrated whole: modules not
files, one canonical file per module under `code/lib`, docs enforced
because they are the discovery surface, the two collision tiers with
`replace: true` as permission rather than assertion, dependents
recompiled on a replace and provable breakage refused with nothing
changed. The reserved prefixes are `Beamlet.*` and `Host.*`.

**The code server is `Beamlet.Code`**, a GenServer child of
`Beamlet` owning `<data_dir>/code` (`lib/`, `ebin/`, `.staging/`,
`.git`), with `Beamlet.Code.Tracer`, `Beamlet.Code.Docs` and
`Beamlet.Code.Audit` beneath it as internals. It is the reference
server; migration placement returned at 15c (Migrations, below),
`manifest` at 15a and `compile_artifact` at 15d (Web, below), the
derived-source compile that runs in the server's lane because the
compiler options and tracers it swaps are VM-global, records nothing
and writes nothing. Remove came across now, ahead of
`Host.Code.remove`, because it is the server's own second operation,
the audit's second commit kind, and the call records it reads exist
for replace's dropped-function check anyway; its errors name
`Host.Code` one step early. The port's steps break the work into an
order, not into what may be referenced.

**One table.** The server records everything it collects in a named
public ETS table it owns: the compile context the tracer reads, the
compiled beams, the edges and call records of the compile in
flight, the defined set with its paths, and the quarantine (the
last two widened at step 15a for discovery, so `manifest/0` and
`quarantined/0` are table reads like `defined/0`). Code mode's `:persistent_term` for the
tracer context went with it, since the value lives for one compile
and every erase scanned the heaps. The defined set is the effective
grants' other half: `Beamlet.Code.defined/0` is a table read, so an
eval's scan never queues behind a thirty-second compile, and both
runtimes merge it into the policy with `Beamlet.Policy.grant/2`, the
same function the scanner uses to grant a buffer's own modules to
each other, before scanning. Rows are added before stale ones go,
so a scan in flight never sees a defined module missing.

**Cancel is an abort.** The tool process is Anubis's and a client
cancel kills it, so the server monitors the caller for the life of
the define: a define still queued behind another never starts, a
compiling one is stopped and rolled back to the previous beams, and
one past the commit point completes. Eval needed a watcher process
because its caller must survive the kill of its child; here the
server is long-lived and holds the monitor itself. The parallel
compiler monitors its workers rather than linking them, so stopping
the compile kills the task and the workers it is watching, on
cancel and on timeout alike; the reference left a module body
running on after its timeout.

**Git is a requirement, not a mode.** The history is the provenance
record, and code mode's enable flag existed so tests and hosts
without git could skip it, which is a mode where defines leave no
trace. The flag went: a beamlet whose PATH has no git fails to boot
with a teaching error, the repo is initialised at boot with the
initial snapshot and hand edits swept into a commit of their own,
exactly as before, and step 17's image installs git. The repo
carries no configuration: every commit names the user as author
(`alice <alice@beamlet>`) and `beamlet` as committer through
environment variables on the command, with the principal as trailers
in the body, and the sweep commits are authored by `beamlet`. The
sweep says what it found (added 2026-09-17, step 15c): one warning
listing git's status lines before the "manual changes" commit, since
a hand edit to the code dir is unusual enough to surface to the
operator, who reads the VM log and nothing the agent sees, and the
commit it names is the point to roll back to. Empty
commits are allowed so a replace with the same source is still on
the record. The provenance trailers are `Beamlet.Principal.to_trailers/1`
and `from_trailers/1`, their first encoding; a test round-trips the
principal through a real commit and another filters `git log` by
trailer. A test's suite boots a beamlet ninety-odd times and each
boot pays git's forty milliseconds; a couple of seconds is not a
reason to shape the design.

One limit, `config :beamlet, define: [timeout: 30_000]`, the time
one compile may take; the transport's request timeout is derived
from the larger of eval's timeout and define's call timeout, since
a define may wait a full compile behind another before its own. The
principal is required on `define` and `remove`; what
`Host.Code.remove` does from a process with no ambient principal is
step 15's question. `Beamlet.Case` wipes the code dir before each
beamlet starts, so every test boots with no defined modules and a
fresh history; the reference's private servers on tmp dirs would
have fought the registered name and the table.

### Discovery

Settled 2026-09-16 (step 15a). `Host.Code` is the agent's discovery
entry point and the module teardown verb: `print_modules`,
`print_docs` at three arities, `print_source`, `print_policy` and
`remove`. The print contract migrated whole: a `print_*` function
prints and returns `:ok`, `remove` acts silently and returns `:ok`,
and a failure raises with a teaching message, so it is
unmistakable and eval keeps everything printed before it. The
rendering is `Beamlet.Code.Discovery`, `@moduledoc false` beside
`Docs`, `Tracer` and `Audit`, returning `{:ok, text}` or
`{:error, text}`: it reads the server's table and beams the way
`Docs` reads a buffer, and the print contract is not something a
test can assert on as text. Code mode's prompt snapshot (`index/2`)
did not come across, having no consumer, and `print_policy` is
`Beamlet.Policy.render/1` of the token's policy.

**Every function requires the ambient principal** and raises a
teaching error without one ("works from eval, where your code acts
as you"). The listing and the docs are filtered by a policy only the
principal names, and a removal is recorded against one; a call from
a web request or a process of the agent's own has neither, and no
policy is an honest fallback, since a custom policy may be wider or
narrower than `default`. Discovery takes the **effective policy**,
the principal's with the defined modules merged in, exactly as the
runtimes build it before a scan, so a defined module is granted like
any other and the reference's special case for it went.

**The listing is `code/lib`** (narrowed at 15e). Four sections, in
order: the modules defined with `define`, each with its moduledoc's
first line, followed by any quarantined module with its error and
the way out (define it again with `replace: true`, or remove it),
since the listing is the one place an agent learns why a module
vanished; the `Host.*` modules;
the framework modules, the curated web and data authoring surface
(`Beamlet.Policy.Default.framework_modules/0`); and the libraries,
one line per package the beamlet ships, led by its primary module,
with any module granted from another package on a line of its own.
A package's line carries a curated description where its own says
nothing (Req's `.app` description is its bare name), else the `.app`
description. The platform is never listed, nor are exception
structs. Docs are served from compiled artifacts: a defined module
by its beam path, everything else by name, so a granted package is
self-documenting. `Host.Repo` joins `Ecto.Repo`'s callback docs onto
its generated functions, the one special case. A refused module or
function gets the scanner's own copy, made public for it, so a
refused `print_docs` carries the same signage hint a refused call
does. `print_source` serves defined and quarantined modules and
nothing else. Migrations are not listed: they live in
`code/migrations`, `Host.Migrator.print_migrations/0` is their home
and speaks in the version numbers the listing would otherwise have
to carry, and a web module carries no route suffix, since the URL
surface is `Host.Router.print_routes/0`'s. A one-line footer after
the libraries points at `print_docs`, `print_routes` and
`print_migrations`, so the one print an agent is steered to names
the other three. Remove's mounted-route check sits in the code
server beside the dependents check (§ 2 Web).

**Tools and grants are independent**, and this step is where it
shows: the default grants `Host.Code` whole, so a policy with
`tools: [:eval]` cannot define modules but can remove them. Kept,
because coupling them would be the first place a tool implied a
grant; a token that should not tear modules down gets
`allow: [{Host.Code, except: [remove: 1]}]`, documented on
`Beamlet.Policy`. Per-module ownership, alice's module that bob
cannot remove, is deferred (§ 4).

### PubSub

Settled 2026-09-16 (step 15a). `Beamlet.PubSub` is the beamlet's
message bus: one `Phoenix.PubSub` registered under that name as a
child of `Beamlet`, and the name is the whole thing. A module for it
was written and dropped in the same step, since nothing called it
and a name needs no module; the one line an embedder needs,
`pubsub_server: Beamlet.PubSub` on their endpoint, which 15d relies
on, is in the `Beamlet` moduledoc beside the child list.
`Host.PubSub` is `subscribe`, `unsubscribe` and `broadcast` over it,
with topics one shared namespace the moduledoc tells agents to
prefix. `broadcast_from` waits for something to ask.

### Files

Settled 2026-09-16 (step 15b). `Host.File` is `File`, scoped to
`<data_dir>/files`, the root `Beamlet.Config.files_dir/0` names and
the boot creates. The name follows `Host.Repo` for `Ecto.Repo` and
`Host.PubSub` for `Phoenix.PubSub`: the leaf name of the module it
stands in for. Code mode's `Host.FS` was named when its API was its
own; the review made it mirror `File`'s names, arguments and
semantics for the subset it provides, so an agent's `File` priors
are right rather than corrected by an index. The functions are
`read`, `write` with modes, `ls`, `mkdir`, `mkdir_p`, `rm`, `rmdir`,
`cp`, `cp_r`, `rename`, `exists?`, `dir?` and `regular?`, each
returning what `File`'s does, `{:error, posix}` included, with a
bang variant raising what `File`'s raises, `File.Error`,
`File.CopyError` or `File.RenameError`, naming the path as the agent
wrote it. All three are in the granted exception family, so a
`rescue File.Error` written from priors works. `ls_r` is the one
function `File` lacks: the reference's recursive listing as sorted
root-relative paths, the thing agents most often want. Two
deviations from `File`, each documented once: writing, copying and
renaming create the parent directories they need, saving an eval
round trip, and `rm` answers `:eisdir` for a directory where
`File.rm` says `:eperm`. Left out: `stat`, since `File.Stat` is
denied and nothing asks for size or mtime yet; `rm_rf`, since on a
shared root file-only removal bounds cross-user accidents; `cp`'s
options, whose `on_conflict` callback would see host paths;
`wildcard`.

The reference's raise-only stance went. It fitted an eval, where a
raise keeps everything printed before it, but the same module runs
in controllers and LiveViews, where a missing file is a 404 to
handle, not a 500. What stayed: one shared root, stateless
resolution that needs no principal and so works the same from an
eval, a web request or a LiveView, a leading `/` meaning the root,
every path containment-checked, error copy that never shows a host
path, no git audit and no size caps. An escape or a non-string path
raises `ArgumentError` from tuple and bang alike: misuse of the API,
not a condition to handle. Containment is lexical through
`Path.expand`; only an operator can plant a symlink under `files/`,
and that is accepted rather than resolved on every call.

One module. The reference split a thin `Host.FS` from
`Omni.Host.Code.FS`, which took the root as an argument for a
`tmp_dir` suite; the Two surfaces rule rejects that reason, nothing
else in Beamlet calls it, and the root comes from config, so
`Host.File` holds the containment and the operations and is tested
directly under `Beamlet.Case`, which wipes `files/` per test. The
scanner expands aliases before its check, so `alias Host.File` lets
agent code read exactly as `File` code: allowed and not advertised,
since the visible `Host.` prefix is what tells a reader of
`print_source` that the scoped door is in use. The `File` redirect
in the signage lit with the row.

### Key/value

Settled 2026-09-17 (step 15c). `Host.KV` is durable storage for
small state under string keys: `fetch/1`, `get/2` with a default,
`put/2`, `delete/1`, `all/1` and `keys/1` under a prefix with an
empty prefix meaning everything, and `delete_all/1` under a prefix
with no default so wiping everything is written deliberately. Values
are any term, stored in external term format in the `__kv` table of
the agent database, so a put inside a `Host.Repo.transaction` lands
with the agent's own rows. Keys are one shared namespace the
moduledoc tells agents to prefix, as with PubSub topics. `fetch/1`
joined the reference's API because a stored `nil` and a missing key
are different answers and `get/2` cannot give both; it is the `Map`
prior. `fetch!/1` did not, having no scenario: in an eval you `get`
and look, in a controller a missing key is a 404 to handle. The
module is the whole agent surface, with `Beamlet.KV.Entry` and
`Beamlet.KV.Term` beneath it as internals, the type parameterized
because only a parameterized type sees `nil`. A granted schema for
agents to query the table through `Host.Repo` was considered and
declined: the value column is opaque to SQL, so the only key-shaped
operations it would open are the three the module already has, at
the cost of pinning the table name and the encoding as public API.

### Migrations

Settled 2026-09-17 (step 15c). A migration is a plain
`use Ecto.Migration` module through the define tool, recognised by
the exported `__migration__/0` after the buffer compiles and filed
under `code/migrations/NNNN_name.ex` with a version the beamlet
assigns: one past both the files on disk and the versions the agent
database records as applied, in buffer order, so a git rewind that
removes an applied migration's file cannot see its number reused
and the migration silently skipped. A replaced migration keeps its
version and file; a replace that changes a module's kind moves its
file between the roots. Define never applies: the summary line
carries the pending cue. The pending rule: a migration is editable
until it has run, and an applied one refuses replace and remove
until rolled back, so the applied stack and the files never
disagree. Boot compiles both roots in one batch and the audit
commits both.

`Host.Migrator` holds the verbs, `migrate/0`, `rollback/0` and
`print_migrations/0`, printing as they go and returning `:ok`, with
`Ecto.Migrator.up/4` and `down/4` against `Host.Repo` one migration
at a time so a mid-batch failure leaves the earlier ones applied and
names the one that failed. `Beamlet.Migrations` is the history they
and the code server share: the applied versions and the join of the
manifest with Ecto's own `schema_migrations` table, which Ecto
creates on first read. The reference's one machinery module took a
server argument for private servers and the face delegated to it;
here the verbs print and raise teaching copy, which is what a `Host`
module does, and the leaf names differ because the two sides are
not the same thing seen twice. An applied version whose module is
gone is an orphan, which only an operator can make since the pending
rule stops an agent: the version floor counts it, the listing marks
it as applied with its source missing, and rollback refuses past it
with a teaching error, because Ecto would otherwise undo the
migration beneath. The reference's boot child that warned about
orphans went: it duplicated the listing for the operator who caused
the state, and the sweep log now surfaces every hand edit instead.

### Config

One surface: `:beamlet` application config, read at runtime through
`Beamlet.Config` accessors, so a release or container sets it from
the environment in `runtime.exs`. No start options carry
configuration, nothing is read at compile time, nothing is stashed.
Checked once, read plainly after (revised 2026-09-16, after step
13): `Beamlet.Config.validate!/0` checks every key first thing in
`Beamlet.init/1`, on both boot paths, and fails the boot naming the
key at fault; the accessors then return what was checked with
defaults merged and never raise. Validating in each accessor was
the earlier shape and lost: it spread the boot's job across every
caller and made runtime paths look fallible when a change is a
restart, as it already was for policies. `data_dir` is the root
everything a beamlet persists lives under; after the document
check, starting checks the dir exists and fails the boot otherwise,
and the modules owning paths beneath it add their accessors as they
arrive: `db/` for the two databases (`db_dir/0`) and `code/` for the
defined modules (`code_dir/0`, step 14). The web surface is the `web`
group, `endpoint` and `prefix` (step 15d, Web below): the full boot
fails without an endpoint, since the routes are served through it,
and the system half needs none.
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
the tools by forwarding to `Beamlet.Router`, which mounts
`Beamlet.MCP.Plug` at `/_mcp`, a path in the beamlet's reserved
namespace (step 15d, Web below).

Server instructions and each tool description are held under 2,048
bytes by tests: Claude Code truncates both at 2KB, and bytes are the
conservative measure against a client counting characters. The
instructions are a pointer block, what matters most first and the
stdlib for the rest.

**Authentication is Beamlet's own plug, not Anubis's authorization.**
`Beamlet.MCP.Plug` wraps the transport plug with the server baked
in, so `Beamlet.Router` mounts it with one forward and nothing
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

Settled 2026-09-17 (step 15d, the machinery; step 15e, the agent
face). The pages and APIs agents build are served by the host's own
endpoint, named in config, and Beamlet owns the router that serves
them, the layout they render in, and a plain error view.

**The host forwards at the root, last.** The one line a host writes
is `forward "/", Beamlet.Router` as the last route of its router.
Last because a root forward matches everything after it, so host
routes win by order. At the root because LiveView's connected mount
re-matches the full browser URL against the router that dispatched
the page, stripping only the endpoint's script name, and
`Phoenix.Router.route_info/4` never recurses through a forward; a
forward at a prefix therefore breaks every LiveView page, which the
reference found and its "strip nothing" rule recorded. The design's
earlier sentence, "the host forwards to `Beamlet.Router`", meant a
prefix and was wrong.

**Root by default, and a reserved namespace.** No prefix: "add a
dashboard to my beamlet" is served at `/dashboard`. The beamlet
owns every path whose first segment starts with an underscore,
`/_mcp` for the MCP server, `/_live` for the LiveView socket,
`/_assets/...` for the JavaScript bundles, later `/_admin`; the
operator copies an odd-looking URL once and an agent never writes
one, since a leading underscore is refused at mount. A leading
`~` is reserved the same way, for the per-user scope § 4 keeps open,
and costs nothing now. The prefix survives as an embedder's option,
`config :beamlet, web: [prefix: "/app"]`, for a host that wants
agent-built pages fenced under its own namespace; the generated
router bakes it into its scopes, since a forward cannot supply it,
and the code is the same whether it is empty or not. The reference's
`/app` default came from a host with an API surface of its own and
lost to the plain URL.

**Two routers.** `Beamlet.Router` is static and public: it mounts
`Beamlet.MCP.Plug` at `/_mcp` and forwards everything else to
`Beamlet.DynamicRouter`, so the beamlet decides what lives under the
underscore and the host's line never changes. Because it sits behind
a root forward, it can carry the future admin LiveViews directly,
with no router macro. `Beamlet.DynamicRouter` is the generated
module: a compiled-in empty placeholder, so the forward compiles,
that `Beamlet.Routes.regenerate/0` replaces in the VM by rendering
the route table into a real `Phoenix.Router` source
(`Beamlet.Routes.Generator`, internal) and compiling it through
`Beamlet.Code.compile_artifact/2`. A derived artifact: never on
disk, never committed, rebuilt from the table at boot and after
every change. Two convention pipelines, LiveView rows through a
browser pipeline with session, CSRF protection and the root layout,
controller rows through an API pipeline with neither so a webhook
can call them; no plug kind, no per-mount override. Rows render in
mount order, so an earlier mount wins an overlapping match as in a
hand-written router. Folding the static routes into the generated
source was considered and lost: it couples the MCP mount to an
artifact that fails and rolls back.

**The table.** `Beamlet.Routes` is the context over `__routes` in
the agent database, created by `Beamlet.Tables` beside `__kv`, with
`Beamlet.Route` at the root beside it (Two surfaces, above): kind,
verb, path, module in inspect form, an optional action, the
principal as JSON (Provenance) and `inserted_at`, unique on verb and
path with a LiveView storing `get`. The format validations are
load-bearing, since the fields interpolate into router source.
`create`, `delete` and `list` change or read the table and nothing
else; regeneration is the caller's to compose, which `Host.Router`
does by inserting, regenerating and deleting the row again when
regeneration fails. A row whose target is missing, quarantined
or of the wrong shape is left out at generation with a warning and
answers 404; the row stays for inspection, and `servable?/1` is the
one rule discovery and remove share. The boot child is synchronous,
right after the code server, returns `:ignore` and never fails the
boot: the worst case is the placeholder serving 404s with an error
in the log. An empty table and an empty loaded router already
agree, so boot compiles nothing in that case, which is what keeps a
suite that boots a beamlet per test from paying a forty-millisecond
router compile each time; the sandbox empties the table between
tests, so no reset fixture exists.

**What the host carries** is written down twice: as the list of
integration points on `Beamlet.Router` and as `Beamlet.TestEndpoint`
in the library's test support, which `Beamlet.Case` starts after
every beamlet and the server app copies. In the router, the root
forward; in the endpoint, the session, the LiveView socket at
`/_live`, `Beamlet.Assets` and JSON parsers; in config, the endpoint
named under `:web`, `pubsub_server: Beamlet.PubSub` and
`render_errors`. `Beamlet.Assets` is a `Plug.Builder` over two
`Plug.Static` plugs serving the LiveView JavaScript from the deps'
precompiled bundles under `/_assets`, so there is no build step; it
is a plug on the host's endpoint rather than a forward inside
`Beamlet.Router`, which would also work, because agent-installed
JavaScript (§ 4) may grow it and how it is consumed is reviewed
then. `Beamlet.Layouts` is the root layout: CSRF token,
the two modules, the socket, Tailwind from its CDN, and nothing
about how a page looks; styling needs the internet, accepted for a
substrate with no bundler. `Beamlet.ErrorView` renders a status
message as text or as JSON, so a miss under the forward is a plain
404 and the test endpoint and the server need no error view of
their own; a host with its own keeps it.

**The agent face** (step 15e) is `Host.Web` and `Host.Router`, the
reference's two modules with its middle machinery module inlined
into the router (Two surfaces, above: the table is a subsystem, the
verbs are not). `use Host.Web, :live_view | :controller |
:live_component | :html` is the one `use` line an agent writes; it
brings the framework for the role, `Phoenix.HTML`, the `JS` alias
and `~p`, and an unknown role is a teaching error at define time.
`Host.Router` holds the verbs, `live/3` and the five named for HTTP
verbs, `unmount/2`, `path/1`, `url/1`, `~p`, `call/4` and
`print_routes/0`. Two words kept apart: a *path* is what the agent
chooses and every function takes, never carrying the operator's
prefix, and a *URL* is what people are given; `path/1` and `~p` map
the one to the browser path and `url/1` to the other, and a path
that already carries the prefix is refused with the relative form
suggested, only when a prefix is set. A mount validates the path
(a string, a leading slash, the row's format), refuses a reserved
first segment with copy naming the convention, requires the target
to be in the code server's manifest and of the right shape
(`__live__/0`, or `action/2` plus the action), then composes
`Beamlet.Routes`: insert, regenerate, delete the row if the router
failed to build. Mount and unmount require the ambient principal
and the row records it; a conflict names the mounted route and the
user who mounted it. `print_routes` prints the base once, then
verb, path, target, mounting user, and a not-served annotation from
`servable?/1`. Remove's mounted-route check lives in
`Beamlet.Code.run_remove/3` beside the dependents check, so it is
atomic with the removal, and its copy names the unmount call.

`call/4` is a real request through the configured endpoint over
`Plug.Test` in the calling process, the response returned as data
with JSON decoded, the adapter's mailbox messages drained so they
never reach a LiveView's `handle_info`, and a crash re-raised with
the route's frames above the endpoint. It sets the ambient
principal aside for the dispatch and restores it after
(`Beamlet.Principal.delete_current/0`), so a route behaves under
`call/4` exactly as it does in a browser: a served route acts as
nobody (Users, tokens and principals), and a controller action that
reaches for `Host.Code` or the mutating verbs here raises either
way. Without that, an agent's test call would pass where a
visitor's request fails.

**Every dynamic route is public.** No web auth until login arrives
(§ 4), a recorded posture carried from the reference.

## 3. Open

Decided as each step arrives, not before:

- The data dir layout, one path at a time as its owners land:
  `db/`, `code/` and `files/` so far.
- The exact stdlib surface, module by module (step 15).
- What the server instructions and tool descriptions say within a
  2KB budget per item (step 16), and whether `eval` declares its
  output cap to Claude Code through the `anthropic/maxResultSizeChars`
  tool annotation. Direction from 15a: code mode's conventions block
  taught that a few pointers have to be in the instructions or the
  model makes the same slips, so a handful go there; the environment
  snapshot does not, replaced by a prominent steer to
  `Host.Code.print_modules()` and `Host.Router.print_routes()`; and a
  convention about one module lives in that module's moduledoc,
  which `print_docs` serves. From 15e: the listing's footer names
  the other prints, so step 16 considers whether the instructions
  need a sentence on calling several prints in one eval, and
  whether a `print_environment` that runs them all earns its place
  or the footer is enough.
- Deployment model, source-run or release (step 17). The server app
  itself landed early (2026-09-18) for testing with an MCP client:
  endpoint, application module and config under one `BeamletServer`
  namespace, no tests of its own, and in prod the data dir named by
  `BEAMLET_DATA_DIR` in `runtime.exs`. Decided in principle at step
  9: the library's only declaration surface is
  application config, and the server's release merges an optional
  operator config file from the data dir into it at boot through a
  config provider, a plain `import Config` file. An operator with a
  mounted data dir writes the file, restarts the container and
  creates the token with `--policy`; the release's `eval` entry
  runs config providers, so the CLI in the container sees the same
  policies.

## 4. Deferred

- Admin UI and login. The admin LiveViews can sit in `Beamlet.Router`
  under `/_admin`, since it is behind a root forward (§ 2 Web).
- Web authentication and private routes, after login. A private
  route keys on the web identity for access and on the row's
  provenance for ownership, never on the principal (§ 2 Users,
  tokens and principals). Two shapes were weighed at step 15d and
  neither chosen: a property of the route, `private: true` on the
  mount, keeping one namespace with the generated router putting
  the row in a scope that requires a login; or a per-user scope in
  the path, `/~alice/notes`, mirroring `~home/` below and nesting
  under any prefix. The reserved leading `~` keeps the second open,
  and the path-to-browser-path indirection `Host.Router` carries
  (`path/1`, `~p`) is the seam either would fill.
- A principal handed in by an embedding host calling tools
  in-process, without a Beamlet token. Struck from § 2 at step 5;
  if it returns, a principal that encodes and decodes is the seam.
- User-scoped modules, routes, files and KV entries beside the
  shared ones, and with them per-module ownership, so that alice's
  module is not bob's to remove. The user id on every principal is
  what it would key on. A private file area would be a `~home/`
  mount on `Host.File` (next item), eval-only, since a served route
  has no principal to be, the rule `Host.Code` already takes.
- Virtual paths on `Host.File`, shaped at the 15b review: a
  `~name/` prefix, which cannot collide with an agent's directories
  and which `Path.expand` leaves alone, resolved through a mount
  table from prefix to directory and mode; a read-only mount refuses
  writes with a teaching error and lists beside ordinary entries.
  The first candidate is `~docs/` over the package's `priv/docs`:
  documentation for agents served as read-only files, a wiki the
  model lists and reads when it needs more than the instructions
  carry, each page under eval's output cap. Reviewed at step 16,
  once the instructions pass shows what overflows; nothing is built
  until there is content to serve.
- Supervised processes for agent code.
- Agent-installed dependencies, and with them who grants an
  installed package to agent code.
- Package-level denial in a policy (`deny_app`) and reloading
  policies without a restart, each when a policy needs it.
- Static assets, and agent-installed JavaScript and CSS, with
  colocated JS and CSS in agent modules as the likely shape.
  `Beamlet.Assets` is where served files would grow. Colocated CSS
  needs `config :phoenix_live_view, root_tag_attribute:` set in the
  VM that compiles the module, which for agent modules is the
  beamlet's, so the setting is the library's to make or require of
  every host, not the server's; and both extract to files under
  `_build` that a bundler is expected to pick up, which the
  no-bundler substrate would have to serve itself.
- The modern-era MCP protocol (2026-07-28); Anubis 2.0 is
  legacy-era and current clients negotiate it.
- Any dependency on Omni packages. If `omni` is ever added, it is as
  a library for agents to use, not as a foundation.
