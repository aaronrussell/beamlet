# Beamlet — roadmap

**Status:** The steps of the port from code mode in `../omni_host`
to Beamlet, in order. Each step gets a planning pass that pins its
spec before implementation; the entry gives direction, not a
contract. The reasoning behind the order and the context carried
from the MCP spike are in `../omni_host/context/beamlet.md`.

**Last updated:** 2026-09-16 (step 15b done)

---

## Posture

Test-driven throughout. The signal that a step works is the suite:
well-formed requests at the MCP plug, modules appearing in the code
dir, teaching errors coming back as error tool results. The
omni_host code-mode suite is the regression baseline, moved and
renamed rather than rewritten. A connected client is used once, at
the end.

## Steps

1. **Initialise `beamlet`.** Project, CLAUDE.md, design and roadmap
   notes, the `Beamlet` supervisor. *Done 2026-09-13.*
2. **Minimal config.** Application config as the one surface,
   `data_dir` required and checked at boot, per-run test data dir and
   `Beamlet.Case`. *Done 2026-09-13.*
3. **Ecto and the system database.** Library-run migrations from
   priv; the SQLite authorizer. *Done 2026-09-14.*
4. **Anubis.** Server, two stub tools, the MCP test client. Pin the
   authorization config shape. *Done 2026-09-14.*
5. **DESIGN: users, tokens, authentication, identification.**
   *Done 2026-09-14.*
6. **Users and tokens store.** The migration, the two schemas with
   changesets, `Beamlet.Users`, and the authenticate function turning a secret into its token and user.
   Tested against the system repo directly; no MCP involved.
   *Done 2026-09-15.*
7. **The principal and the plug.** The `Beamlet.Principal` struct,
   `Beamlet.MCP.Plug` with the 401 and the principal in assigns, the
   test client sending a bearer header, and `Beamlet.Case` creating
   a user and token for every test. *Done 2026-09-15.*
8. **Management interface** for users and tokens: `Beamlet.CLI`
   over the store functions, with `mix beamlet` as the dev entry. It
   touches only the system database and starts the repo and migrates
   on its own rather than booting a whole beamlet. *Done 2026-09-15.*
9. **DESIGN: policy and stance review.** What migrates, what changes,
   and how an operator declares a named policy. Policy attaches to
   the token (step 5). *Done 2026-09-15.*
10. **Policy and the default.** `Beamlet.Policy` with the document
    validation and the rendering, `Beamlet.Policy.Rules`,
    `Beamlet.Policy.Default` with the platform rulings, the golden
    fixture and the coverage test, and `Beamlet.Policies` built at
    boot as a child of `Beamlet`, failing the boot on a bad
    declaration. Tested directly, no MCP. *Done 2026-09-15.*
11. **Policy at the edges.** The token changeset validating the
    policy name, the plug's 403 for a token naming an undeclared
    policy, the server's `handle_request` override filtering the
    listing and refusing an ungranted call, and the CLI's `--policy`
    with `policies` and `policies.show`. End to end at the MCP plug
    against the stub tools. *Done 2026-09-15.*
12. **The scanner.** The port with its tests, scanning against a
    policy struct, `scan_eval` and `scan_define`, right before its
    first caller; the signage reviewed clause by clause and moved
    into `Beamlet.Policy.Signage`, with the tests that need step 15
    modules carried across skipped. *Done 2026-09-15.*
13. **`eval`.** The exec runtime and tool result, with cancel
    linkage, and the ambient principal in place of code mode's
    ambient agent name and stance. No stdlib yet. *Done 2026-09-16.*
14. **`define`.** Plain modules, the code server, git audit. No
    migrations yet. The provenance trailers land here with the
    audit, their first caller, along with the round-trip test. The
    defined set is merged into the policy's grants before every
    scan, the other half of the effective grants, in whatever shape
    the code server makes natural. *Done 2026-09-16.*
15. **The stdlib, module by module**, in four sub-steps, each with
    its own planning pass and an API review as the module comes
    across: names, arguments, docs and teaching copy are open to
    change. Common to every module: its row joins
    `Beamlet.Policy.Default`, one line and a regenerated golden, and
    lights the signage redirect that points at it; what step 14 left
    out of the code server returns with its consumer; the design's
    Two surfaces section says where a module's machinery lives.
    - **15a. `Host.Code` and `Host.PubSub`.** Discovery
      (`print_modules`, `print_docs`, `print_source`, `print_policy`
      through `Beamlet.Policy.render/1`) and `remove` over the
      server's, deciding what a process with no ambient principal
      may do; `manifest` returns to `Beamlet.Code`; the scanner's
      denied-module copy goes public for the listing; the discovery
      accessors code mode kept on its curation record return if the
      listing needs them; `Macro` gets a partial grant for its string
      helpers (`underscore`, `camelize`, `to_string`). PubSub is
      `Beamlet.PubSub` as a child and `Host.PubSub` over it. Open for
      the pass: where code mode's conventions text goes, here as a
      `print_*` or at step 16. The routes section of the listing and
      remove's mounted-route check wait for 15d. *Done 2026-09-16.*
    - **15b. `Host.File`**, with a design and API review of the
      scoped filesystem before it comes across. The review also takes
      the idea of agent documentation served as read-only files under
      a virtual path (design § 4). *Done 2026-09-16.*
    - **15c. `Host.Repo`, `Host.KV` and `Host.Migrator`.** The repo
      is there; KV is the table created at boot outside the agent's
      migrations; migration placement, the `code/migrations` layout
      and the applied-version check return to `Beamlet.Code`.
    - **15d. `Host.Web` and `Host.Router`.** The route table in the
      agent database with the JSON provenance encoding, `Beamlet.Router`
      that the host forwards to and the dynamic router it generates
      with `compile_artifact` back in the server, layouts, the `use
      Host.Web` roles, the test endpoint, `Host.Router.call`; the
      skipped `Host.Web` shape test in the scanner suite comes back;
      `Host.Code` gains its routes section and remove's mounted-route
      check. The largest of the four; its pass may split it further.
16. **Descriptions and instructions pass** against the 2KB budget,
    with tests that fail past it. The instructions are phrased to
    survive an eval-only token, since they stay static while the
    listing does not. Reviews whether `~docs/`, documentation served
    as read-only files through `Host.File` (design § 4), is needed
    yet.
17. **Server app and Docker image.** Deployment model decided here.
    The release ships `bin/beamlet` calling `Beamlet.CLI.main/1` and
    a config provider merging an optional operator config file from
    the data dir.
18. **Verify** against the M14 walkthrough over MCP.
19. **Beyond the port:** supervised processes, agent-installed
    dependencies and who grants them, static assets, the admin UI.

## Done

- **Step 1** (2026-09-13): project, notes, `Beamlet` as a supervisor
  with no `mod:`.
- **Step 2** (2026-09-13): `Beamlet.Config.data_dir!/0`, the boot
  check, `config/` for dev and test, `Beamlet.Case`. Design § 2
  Config records the decision; § 3 records the policy and identity
  direction for steps 5 and 9.
- **Step 3** (2026-09-14): `Beamlet.Repo` and `Host.Repo` under
  `<data_dir>/db`, the migrator running at every boot, the SQLite
  authorizer on the agent database, `mix ecto.setup` / `ecto.reset`
  for both repos. Design § 2 Two databases records the layout.
- **Step 4** (2026-09-14): `Beamlet.MCP.Server` with stub `define`
  and `eval` components, the `Beamlet.MCPClient` test support over
  `Plug.Test`, byte-size tests at 2,048 for the instructions and
  each description. Design § 2 MCP records the names, the budget
  and the pinned authorization shape.
- **Step 5** (2026-09-14): the user and token model, policy on the
  token, per-request identity with no session binding, a
  Beamlet-owned authentication plug in place of Anubis's OAuth-shaped
  authorization, and the provenance stamp with its two encodings.
  Design § 2 Users, tokens and principals, and Provenance, record it;
  § 3 Direction for policy was revised to match. The in-process
  principal for an embedding host moved to § 4 Deferred. The
  implementation was then split into steps 6, 7 and 8, with the
  provenance encodings deferred to their first callers at 12 and 13,
  and everything after renumbered up by one.
- **Step 6** (2026-09-15): the users and tokens migration,
  `Beamlet.User` and `Beamlet.Token` at the root beside the one
  context `Beamlet.Users` that owns both, its conventional user
  functions and the token functions taking the user, and
  `Beamlet.Users.authenticate/1`. `Beamlet.Case` now owns a shared
  sandbox connection on both repos per test. Design § 2 Users,
  tokens and principals records the context shape, the name rule and
  the secret pipeline.
- **Step 7** (2026-09-15): `Beamlet.Principal`, flat with user and
  token ids and names and the policy, built from an authenticated
  token; `Beamlet.MCP.Plug` wrapping the transport plug with the
  server baked in, a 401 with a `Bearer` challenge otherwise;
  `Beamlet.MCPClient` as a handle carrying session id and secret,
  since the bearer goes on every request; `Beamlet.Case` creating
  `alice` and a token per test. The client's name and version were
  dropped from the principal and both provenance encodings. Design
  § 2 Users, tokens and principals, Provenance and MCP record it.
- **Step 8** (2026-09-15): `Beamlet.CLI.main/1` over argv, printing
  plain text and returning `:ok` or `:error`, with dotted commands
  (`users.create USER`, `tokens.create USER TOKEN`) that address
  everything by name and take the user first on every token command.
  The entry was revised from mix tasks: a release has no Mix, so the
  module is the implementation and each environment gets a thin
  entry, `mix beamlet` now and a release script at step 15. The CLI
  borrows a running beamlet's repo or starts, migrates and stops its
  own. `Beamlet.prepare!/0` and `Beamlet.Users.find_token_by/2` came
  with it. No policy option until step 9. Design § 2 Users, tokens
  and principals records it.
- **Step 9** (2026-09-15): the policy as one document of tools,
  rules and grants, declared as data in application config,
  validated and resolved at boot and never stored; `default` fixed
  and the base of every other policy, with `extends` and
  `allow_app` considered and left out; the listing filtered per
  token and an ungranted call a JSON-RPC error; a missing policy a
  403 at the plug; the policy name validated in the token
  changeset; `--policy`, `policies` and `policies.show` for the
  CLI; "stance" retired. Design § 2 Policy records it, § 3 carries
  the container's config-provider decision to step 17, and § 4
  defers `deny_app` and reload. The implementation was split into
  steps 10, 11 and 12 (the document and default, the edges, the
  scanner), and everything after was renumbered up by two.
- **Step 10** (2026-09-15): `Beamlet.Policy` with the struct,
  `build/2` validating the document with teaching errors that name
  the policy and the key, the grant lookups and `render/1`;
  `Beamlet.Policy.Rules`; `Beamlet.Policy.Default` as the curation
  record with its rendered moduledoc, package expansion and the
  golden fixture; `Beamlet.Policies` as a `GenServer` owning an ETS
  table, first child of `Beamlet`, with `fetch/1` and `names/0`;
  `Beamlet.Config.policies!/0`. `req`, `jason`, `phoenix`,
  `phoenix_html` and `phoenix_live_view` became dependencies so the
  web, data and package rows came across now; only the seven absent
  host rows wait for step 15. Validation extended to functions under
  `only:` and `except:`; allow-then-deny is deny. Design § 2 Policy
  records the as-built shape.
- **Step 11** (2026-09-15): `Beamlet.Token`'s changeset validating
  the policy against `Beamlet.Policies.names/0`; the plug's 403 with
  a line naming the token and the policy; `Beamlet.MCP.Server`
  overriding `handle_request/2` to filter `tools/list` and to answer
  a `tools/call` for a withheld tool with Anubis's own unknown-tool
  error, the distinct "not in your policy" message dropped since the
  listing never showed the tool; `--policy` on `tokens.create` and
  `tokens.update`, `policies` and `policies.show`. The CLI's cold
  path was reshaped: `Beamlet.start_link(only: :system)` starts the
  policies and the system database alone, so the CLI starts that
  half of a beamlet and stops it rather than assembling processes
  itself, ensuring the dependency applications first and trapping
  the link so a bad declaration prints the boot's error;
  `Beamlet.prepare!/0` went private again. Tests declare policies
  with `@tag policies`, and the missing-policy case writes the row
  directly. Design § 2 records all of it.
- **Step 12** (2026-09-15): `Beamlet.Scanner` with `scan_eval/2` and
  `scan_define/2` taking the policy struct alone, the rules read
  from it, the mode atom `eval`, one violation helper, and the copy
  in Beamlet's voice ("not permitted by your policy", "nothing named
  X exists on your beamlet"). The signage review that the planning
  pass surfaced: ten categories became eight and 62 signed modules
  became 33, keeping redirects and the two closures that end a walk,
  cutting shell and dynamic, and adding `state` for `Host.KV`;
  `Beamlet.Policy.Signage` holds it with policy-aware `hint/2` and
  `hint/3` that drop a redirect whose door the policy withholds,
  `Beamlet.Policy.Default` is grants and the not-granted walk only,
  and the coverage test has two buckets.
  `Beamlet.TestPolicies.doors_open/0` grants the absent `Host.*`
  doors for tests about the join. The reference suite came across
  whole; the `Host.Web` shape test is skipped until step 15. Design
  § 2 Policy records the review.
- **Step 13** (2026-09-16): `Beamlet.Eval.run/3` scanning,
  evaluating and formatting; `Beamlet.Eval.Runner` with the child
  under `Beamlet.TaskSupervisor` and the watcher that kills it when
  the tool process is cancelled; `Beamlet.MCP.Eval` as the thin
  component, code mode's tool layer and `active_description` gone.
  Three limits under `config :beamlet, :eval` read by
  `Beamlet.Config.eval!/0`, the transport's request timeout derived
  from the eval timeout, the inspect limits fixed. The ambient
  principal as `Beamlet.Principal.put_current/1` and `current/0`,
  written by the runner and read by nobody yet. The reference exec
  suite came across minus the description, `Host.FS` and time zone
  cases; the cancel test drives the plug from a second process and
  sends `notifications/cancelled`. Design § 2 Eval records it.
- **Step 14** (2026-09-16): `Beamlet.Define.run/3` scanning, running
  the docs gate and handing the buffer to `Beamlet.Code`, the code
  server owning `<data_dir>/code` with `Beamlet.Code.Tracer`, `Docs`
  and `Audit` beneath it; `Beamlet.MCP.Define` as the thin component.
  The reference server came across minus migrations,
  `compile_artifact` and `manifest`, with remove included ahead of
  `Host.Code`. One named ETS table holds the tracer's context, the
  compile's records and the defined set, which `Beamlet.Code.defined/0`
  reads and both runtimes merge into the policy with
  `Beamlet.Policy.grant/2`. A cancel aborts the compile through a
  monitor on the caller, and stopping a compile kills the parallel
  compiler's workers, which its timeout path had leaked in code mode.
  Git became a requirement: no flag, boot fails without it, the repo
  carries no config, every commit names the user as author and
  `beamlet` as committer, and the provenance trailers landed on
  `Beamlet.Principal` with the round trip tested through a real
  commit. `config :beamlet, define: [timeout:]`, `Beamlet.Config.code_dir/0`,
  the transport timeout derived from both tools. `Beamlet.Case` wipes
  the code dir per test and gained the code helpers. Design § 2
  Define records it.
- **Step 15a** (2026-09-16): `Host.Code` with the print contract and
  `remove`, every function requiring the ambient principal and
  raising a teaching error without one; `Beamlet.Code.Discovery` as
  the rendering beneath the code server, over the effective policy,
  the listing in four sections with quarantined modules and a curated
  package description, docs by beam or by name with the `Host.Repo`
  join, source for defined and quarantined modules; the scanner's
  refusal copy made public so a refused `print_docs` hints. The
  system principal `Beamlet.Principal.system/0`, `beamlet` with id 0,
  under which the boot sweep now commits with trailers, and the user
  name reserved. The code server publishes paths and the quarantine
  to its table, so `manifest/0` and `quarantined/0` are table reads.
  `Beamlet.PubSub` as a named `Phoenix.PubSub` child, no module,
  and `Host.PubSub` over it, `phoenix_pubsub` a direct dependency. `Host.Code`, `Host.PubSub`
  and a partial `Macro` joined the default, the golden regenerated,
  the pubsub redirect lit. `Beamlet.Case.act_as/1`. Tools and grants
  stay independent, so an eval-only token can remove; noted with the
  `except: [remove: 1]` recipe. Conventions direction recorded for
  step 16 and the docs-in-FS idea for 15b. Design § 2 Discovery and
  PubSub record it.
- **Step 15b** (2026-09-16): `Host.File`, the scoped filesystem
  renamed for the module it stands in for and reshaped to mirror
  `File`: tuple returns with posix reasons, bang variants raising
  `File.Error`, `File.CopyError` and `File.RenameError` with the
  agent's path, `ls_r` for the recursive listing, `ArgumentError`
  for escapes and non-strings, parents created on write, copy and
  rename. One module with no `Beamlet.File`; the root at
  `Beamlet.Config.files_dir/0`, created at boot and wiped per test
  by `Beamlet.Case`. The row joined the default and lit the `File`
  redirect, so the tests that relied on the door being absent moved
  to `Host.KV` or to a policy denying `Host.File`. The reference FS
  suite came across against `Host.File` directly, and the eval suite
  gained the three `Host.FS` cases step 13 left out. Virtual paths
  recorded in design § 4, `~docs/` to be reviewed at step 16. Design
  § 2 Files records it.
