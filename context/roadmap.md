# Beamlet — roadmap

**Status:** The work agreed, anchored to versions, in order. Each step gets a planning pass that pins its spec before implementation. What is settled lives in `design.md`. Beamlet is beta until 1.0; a 0.x minor may change any surface and says so in the changelog.

**Last updated:** 2026-09-21

---

## 0.1 — first release

1. **DESIGN: login and OAuth.** Done 2026-09-21; `login-and-oauth.md` is the record and steps 2 to 4 are its phases. Beamlet is its own OAuth 2.1 authorization server and Anubis is the resource server, so `Beamlet.MCP.Plug` gives way to Anubis's plug and a `Beamlet.MCP.Validator`. Opaque tokens in one table with a `kind`, `cli` and `oauth`: chat clients connect by OAuth and the operator's own code by a header, and both stay. Client ID metadata documents only, no registration endpoint. The beamlet's own routes move under one `/_/` segment. Pre-release, so the existing migration is edited and the data dir reset.
2. **Login, sessions, the `/_/` scope and the home stub.** Phase 1: the router scope with the three existing paths moved and the reservation check updated, `Beamlet.Web` with the layouts and error view moved in, `password_hash` on users and `users.password` with a prompt, the browser pipeline, `require_login` and the `on_mount` hook, the login and logout routes, and `/` as a stub showing the signed-in name while nothing is mounted there.
3. **OAuth.** Two phases, two sessions. Phase 2, the resource server: the tokens migration with `kind`, `client` in place of `name`, expiry and refresh columns; the two changesets; the CLI addressing tokens by id; the public URL from the endpoint config; Anubis's plug at `/_/mcp` with the `authorization:` option built at runtime; the validator; the 401 carrying `resource_metadata`; both well-known documents. CLI tokens work as before through the new edge. Phase 3, the authorization server: the client document fetch with its guard, the code store, `/_/authorize` with PKCE S256 and a consent page that picks the policy and shows the client host, `/_/token` with the code and refresh grants and rotation in place, loopback redirects on any port for Claude Code. Verified against Claude Code locally, then claude.ai and ChatGPT on Fly.
4. **Home page.** Phase 4: `/` becomes the setup page: the MCP URL, how to add the beamlet in claude.ai, ChatGPT and Claude Code and sign in, the `mcp-remote` line for Claude Desktop, and the CLI commands for code that takes a header. Served only while nothing is mounted at `/`.
5. **Operator config file.** A config provider merging an optional `config.exs` from the data dir into application config at boot, so a container declares policies without a rebuild (design § 3). Also ends the dev trap of `explorer` declared in both `config/dev.exs` and `server/config/dev.exs`.
6. **Furniture upgrades.** `Beamlet.Tables` becomes an ordered list of up-only steps over `PRAGMA user_version`, run at boot (design § 2 Two databases). Step one creates `__kv` and `__routes` as today. A test proves a file at version zero reaches the current one.
7. **`beamlet reset`.** A CLI command wiping the agent database, the code dir with its git history and the files dir. Refuses while a beamlet runs in the VM.
8. **`beamlet eval`.** A CLI command evaluating a string of code on the running beamlet as the system principal and printing the result. Reaches the running node over distribution rather than booting its own beamlet. Lean: the operator's code skips the scanner, so it can print the instructions and descriptions straight off `Beamlet.MCP.*`.
9. **CI.** One workflow running `mix precommit` on every push.
10. **Code review.** Bugs and sloppy code across the library and the server, with a security read of the login and OAuth surface. Known candidates: a boot check for the migrations dir (the first image missed the library's `priv`); the authorizer's read of DBConnection's private holder record, fixed if an upstream option exists or recorded as a known issue.
11. **Test review.** Flaky and pointless tests, and gaps the code review opens.
12. **Docs and package hygiene.** LICENSE; `package/0`, `docs/0` and a description in `mix.exs`; an ex_doc pass over the public `Beamlet.*` moduledocs; a CHANGELOG; a README covering what Beamlet is, running the image, embedding in prose (the child spec, the router line, what an endpoint must carry, `server/` as the example), and the security posture: the policy guards against accident, not adversaries, and tokens are the trust boundary.
13. **Release.** A tag publishes the package to hex and the image to GHCR. Version 0.1.0.
14. **Verify** the walkthrough script against the published image from claude.ai, ChatGPT and Claude Code.

## 0.2 — concurrency

Supervised processes for agent code, and async tasks inside an eval. Shape from the omni_host M15 note: a beamlet-owned supervisor agents register children into, a durable record of what should be running, boot restart, teardown verbs, a `Host.*` face. Not a policy row: a bare `allow Task` yields processes that die with the eval or leak. The process-primitive closure in the signage becomes a redirect.

## 0.3 — static assets

Agent-served files and agent-installed JavaScript and CSS, colocated JS and CSS in agent modules as the likely shape (design § 4). `Beamlet.Assets` is where served files grow. Open: where npm packages live and who runs the install; the `root_tag_attribute` setting colocated CSS needs in the compiling VM.

## 0.4 — user scoping

User-scoped files as a `~home/` mount on `Host.File`, the first mount on the virtual-path mechanism (design § 4), eval-only. Private routes under `/~alice/...`. Per-user ownership of modules and routes, so alice's module is not bob's to remove; touches remove, mount and the listing.

## 0.5 — admin UI

LiveViews in the library under `/_admin`, behind the login: files with drag-and-drop upload, routes, read-only source for modules.

## 0.6 — agent-installed dependencies

Hex packages at runtime: propose, operator approves, the beamlet installs, the policy grants. A durable manifest with git-audit treatment, applied at boot before the code dir compiles; `Mix.install` is once per VM, so a change means a restart. Reopens the trusted-owner security posture, and brings a package-level grant (`allow_app`, declined at step 9 of the port).

## Deferred

Design § 4 holds the list. Two follow-ups with no version: a walkthrough run on a local model, on the same script; the modern-era MCP protocol (2026-07-28), waiting on Anubis.
