# Beamlet — roadmap

**Status:** The steps of the port from code mode in `../omni_host`
to Beamlet, in order. Each step gets a planning pass that pins its
spec before implementation; the entry gives direction, not a
contract. The reasoning behind the order and the context carried
from the MCP spike are in `../omni_host/context/beamlet.md`.

**Last updated:** 2026-09-13

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
   notes, the `Beamlet` child spec skeleton, test support that starts
   a beamlet against a scratch data dir. *In progress.*
2. **Minimal config.** The data dir and its layout.
3. **Ecto and the system database.** Library-run migrations from
   priv; the SQLite authorizer.
4. **Anubis.** Server, two stub tools, the MCP test client. Pin the
   authorization config shape.
5. **DESIGN: users, tokens, authentication, identification.**
6. **Implement users and auth,** wired to the MCP server.
7. **Management interface** for users and tokens.
8. **DESIGN: policy and stance review.** What migrates, what changes,
   per beamlet or per user.
9. **Port scanner, rules, policy** under the new declaration story.
10. **`code_exec`.** The exec runtime and tool result, with cancel
    linkage. No stdlib yet.
11. **`code_define`.** Plain modules, the code server, git audit. No
    migrations yet.
12. **The stdlib, module by module.** Fs, PubSub, Repo and KV and
    Migrator, Code, then Web and Router. The test endpoint arrives
    with Web and Router.
13. **Descriptions and instructions pass** against the 2KB budget,
    with tests that fail past it.
14. **Server app and Docker image.** Deployment model decided here.
15. **Verify** against the M14 walkthrough over MCP.
16. **Beyond the port:** supervised processes, agent-installed
    dependencies, static assets, the admin UI.

## Done

Nothing yet.
