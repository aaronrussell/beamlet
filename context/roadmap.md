# Beamlet — roadmap

**Status:** The work agreed, anchored to versions, in order. Each step gets a planning pass that pins its spec before implementation. What is settled lives in `design.md`. Beamlet is beta until 1.0; a 0.x minor may change any surface and says so in the changelog.

**Last updated:** 2026-09-22

---

## 0.1 — first release

1. **DESIGN: login and OAuth.** Done 2026-09-21; `login-and-oauth.md` is the record and steps 2, 3 and 5 are its phases. Beamlet is its own OAuth 2.1 authorization server and Anubis is the resource server, so `Beamlet.MCP.Plug` gives way to Anubis's plug and a `Beamlet.MCP.Validator`. Opaque tokens in one table with a `kind`, `cli` and `oauth`: chat clients connect by OAuth and the operator's own code by a header, and both stay. Client ID metadata documents only, no registration endpoint. The beamlet's own routes move under one `/beamlet` segment. Pre-release, so the existing migration is edited and the data dir reset.
2. **Login, sessions, the `/beamlet` namespace and the home page.** Done 2026-09-21. The router scope with the three existing paths moved under `/beamlet` and the reservation check updated, the underscore rule dropped; `Beamlet.Web` with the layouts and error view moved in; `password_hash` on users with a no-echo password prompt on `users.create` and `users.update --password`; the browser pipeline, `Beamlet.Web.Auth` with `require_login` and the `on_mount` hook; the login and logout routes; and `/beamlet` as a stub behind the login showing the signed-in name. `/` stays an agent's, 404 with a pointer until one mounts it.
3. **OAuth.** Two phases, two sessions. Phase 2, the resource server, done 2026-09-21: the tokens migration with `kind`, `name` for CLI tokens and `client` for OAuth ones, expiry and refresh columns; the two changesets and the label; the CLI addressing tokens by id; `Beamlet.MCP.Plug` kept, its 401 carrying `resource_metadata`; `Beamlet.OAuth` and both well-known documents from the endpoint's url. The design pass's validator lost at the planning pass (`login-and-oauth.md` § 3). CLI tokens work as before. Phase 3, the authorization server, done 2026-09-21: the client document fetch guarded by `req_ssrf`, the code store, `/beamlet/authorize` with PKCE S256 behind the login and a consent page that picks the policy and shows the client host, `/beamlet/token` with the code and refresh grants and rotation in place, loopback redirects on any port for Claude Code, a day and thirty days as the lifetimes. Verified 2026-09-22 over a Tailscale funnel against ChatGPT, the Claude app and Raycast, defaults throughout, no registration endpoint needed; the Inspector detects OAuth but cannot run the flow. One finding for phase 4: a custom-scheme redirect (Raycast) leaves the browser on the consent page, so consent wants a "sending you back" page.
4. **User-bounded policies.** Done 2026-09-22. A user carries `policies`, the list of declared policies the operator grants (`users.create alice --policy foo --policy bar`, repeatable, `users.update` replacing the list); empty means every declared policy. `Beamlet.Users.create_token/2` and `update_token/2` refuse a policy outside the user's list, so the CLI, the consent page and the token endpoint share one gate; the consent page lists only the user's policies and preselects the first; `tokens.create` with no `--policy` fails with a teaching error for a bounded user rather than minting `default`. `Beamlet.MCP.Plug` refuses a token whose policy is outside its user's current list with the 403, so narrowing takes effect at once. `{:array, :string}` as JSON text on SQLite; pre-release, the migration edited in place and the dev system database wiped. `users` gains a column. Planning-pass calls: `--all-policies` clears the list; `users.update --policy` does not refuse to drop a policy tokens carry, it counts the tokens now outside the list and leaves the 403 to the plug; `default` is preselected on the consent page when on offer, the user's first policy otherwise.
5. **Home page.** Done 2026-09-22 (phase 4). `/beamlet` is the setup page behind the login: the MCP URL, then apps (Claude, ChatGPT, any OAuth client) signing in on the consent page, coding agents with OAuth (Claude Code, Codex) signing in from the terminal, and the header token for everything else (Cursor, `.mcp.json`, the Claude and OpenAI APIs) with the operator's `tokens.create` command filled in. With it, the asset pipeline for the beamlet's own pages: Tailwind built by the hex package into a committed `priv/static/beamlet.css`, refreshed by `precommit`, a watcher in the server's dev config, and a second root layout plus an app layout in `Beamlet.Web.Layouts`; agent pages keep the CDN. No JavaScript pipeline until a hook needs one. The consent page reviewed, and a custom-scheme redirect (Raycast) now renders a sending-back page. Planning-pass calls: no self-service tokens and no token list, both for 0.5; `mcp-remote` off the page; no plan or pricing claims.
6. **Operator config file.** A config provider merging an optional `config.exs` from the data dir into application config at boot, so a container declares policies without a rebuild (design § 3). Also ends the dev trap of `explorer` declared in both `config/dev.exs` and `server/config/dev.exs`.
7. **Furniture upgrades.** `Beamlet.Tables` becomes an ordered list of up-only steps over `PRAGMA user_version`, run at boot (design § 2 Two databases). Step one creates `__kv` and `__routes` as today. A test proves a file at version zero reaches the current one.
8. **`beamlet reset`.** A CLI command wiping the agent database, the code dir with its git history and the files dir. Refuses while a beamlet runs in the VM.
9. **`beamlet eval`.** A CLI command evaluating a string of code on the running beamlet as the system principal and printing the result. Reaches the running node over distribution rather than booting its own beamlet. Lean: the operator's code skips the scanner, so it can print the instructions and descriptions straight off `Beamlet.MCP.*`.
10. **CI.** One workflow running `mix precommit` on every push.
11. **Code review.** Bugs and sloppy code across the library and the server, with a security read of the login and OAuth surface. Known candidates: a boot check for the migrations dir (the first image missed the library's `priv`); the authorizer's read of DBConnection's private holder record, fixed if an upstream option exists or recorded as a known issue.
12. **Test review.** Flaky and pointless tests, and gaps the code review opens.
13. **Docs and package hygiene.** LICENSE; `package/0`, `docs/0` and a description in `mix.exs`; an ex_doc pass over the public `Beamlet.*` moduledocs; a CHANGELOG; a README covering what Beamlet is, running the image, embedding in prose (the child spec, the router line, what an endpoint must carry, `server/` as the example), and the security posture: the policy guards against accident, not adversaries, and tokens are the trust boundary.
14. **Release.** A tag publishes the package to hex and the image to GHCR. Version 0.1.0.
15. **Verify** the walkthrough script against the published image from claude.ai, ChatGPT and Claude Code.

## 0.2 — concurrency

Supervised processes for agent code, and async tasks inside an eval. Shape from the omni_host M15 note: a beamlet-owned supervisor agents register children into, a durable record of what should be running, boot restart, teardown verbs, a `Host.*` face. Not a policy row: a bare `allow Task` yields processes that die with the eval or leak. The process-primitive closure in the signage becomes a redirect.

## 0.3 — static assets

Agent-served files and agent-installed JavaScript and CSS, colocated JS and CSS in agent modules as the likely shape (design § 4). `Beamlet.Assets` is where served files grow. Open: where npm packages live and who runs the install; the `root_tag_attribute` setting colocated CSS needs in the compiling VM.

## 0.4 — user scoping

User-scoped files as a `~home/` mount on `Host.File`, the first mount on the virtual-path mechanism (design § 4), eval-only. Private routes under `/~alice/...`. Per-user ownership of modules and routes, so alice's module is not bob's to remove; touches remove, mount and the listing.

## 0.5 — admin UI

LiveViews in the library under `/beamlet`, beside the home page and behind the login: files with drag-and-drop upload, routes, read-only source for modules.

## 0.6 — agent-installed dependencies

Hex packages at runtime: propose, operator approves, the beamlet installs, the policy grants. A durable manifest with git-audit treatment, applied at boot before the code dir compiles; `Mix.install` is once per VM, so a change means a restart. Reopens the trusted-owner security posture, and brings a package-level grant (`allow_app`, declined at step 9 of the port).

## Deferred

Design § 4 holds the list. Two follow-ups with no version: a walkthrough run on a local model, on the same script; the modern-era MCP protocol (2026-07-28), waiting on Anubis.
