# Beamlet — roadmap

**Status:** The steps of the port from code mode in `../omni_host`
to Beamlet, in order. Each step gets a planning pass that pins its
spec before implementation; the entry gives direction, not a
contract. The reasoning behind the order and the context carried
from the MCP spike are in `../omni_host/context/beamlet.md`.

**Last updated:** 2026-09-15

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
   changesets, `Beamlet.Users` and `Beamlet.Tokens`, and the
   authenticate function turning a secret into its token and user.
   Tested against the system repo directly; no MCP involved.
   *Done 2026-09-15.*
7. **The principal and the plug.** The `Beamlet.Principal` struct,
   `Beamlet.MCP.Plug` with the 401 teaching body and the principal
   in assigns, the test client sending a bearer header, and
   `Beamlet.Case` creating a user and token for every test. Touches
   every existing MCP test.
8. **Management interface** for users and tokens: mix tasks over the
   store functions. The tasks touch only the system database, and
   the migrator runs inside the `Beamlet` supervisor, so a task
   starts the repo and migrates on its own rather than booting a
   whole beamlet.
9. **DESIGN: policy and stance review.** What migrates, what changes,
   and how an operator declares a named policy. Policy attaches to
   the token (step 5).
10. **Port scanner, rules, policy** under the new declaration story.
11. **`code_exec`.** The exec runtime and tool result, with cancel
    linkage. No stdlib yet.
12. **`code_define`.** Plain modules, the code server, git audit. No
    migrations yet. The provenance trailers land here with the
    audit, their first caller, along with the round-trip test.
13. **The stdlib, module by module.** Fs, PubSub, Repo and KV and
    Migrator, Code, then Web and Router. The test endpoint arrives
    with Web and Router. The provenance JSON encoding lands with the
    route table.
14. **Descriptions and instructions pass** against the 2KB budget,
    with tests that fail past it.
15. **Server app and Docker image.** Deployment model decided here.
16. **Verify** against the M14 walkthrough over MCP.
17. **Beyond the port:** supervised processes, agent-installed
    dependencies, static assets, the admin UI.

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
