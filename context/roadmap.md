# Beamlet — roadmap

**Status:** The work agreed, anchored to versions, in order. Each step gets a planning pass that pins its spec before implementation. What is settled lives in `design.md`. Beamlet is beta until 1.0; a 0.x minor may change any surface and says so in the changelog.

**Last updated:** 2026-09-23

---

## 0.1 — first release

Steps 1 to 5 are done; design § 2 Login and OAuth, Users, tokens and principals, and Web hold what they settled.

1. **Login and OAuth, designed.** Done 2026-09-21. The shaping pass behind steps 2, 3 and 5: Beamlet as its own OAuth 2.1 authorization server with its own plug at the edge, opaque tokens of two kinds, client ID metadata documents only, the beamlet's own routes under one `/beamlet` segment.
2. **Login and the `/beamlet` namespace.** Done 2026-09-21. Passwords on users with a no-echo prompt, the cookie session, `Beamlet.Web.Auth`, the sign-in and sign-out, `/beamlet` behind the login, the web pieces under `Beamlet.Web`.
3. **OAuth.** Done 2026-09-21, verified by hand 2026-09-22 against ChatGPT, the Claude app and Raycast. The token table's two kinds and the CLI addressing tokens by id; the 401 challenge and the two discovery documents; the guarded client fetch, the code store, the consent page and the token endpoint with both grants.
4. **User-bounded policies.** Done 2026-09-22. A user carries the policies its tokens may name; one gate in `Beamlet.Users` for the CLI, the consent page and the token endpoint; the plug refuses a token outside its user's list.
5. **Home page and design pass.** Done 2026-09-23. The setup page with a tab per client; the built stylesheet carrying the design system's tokens and the shared components; live reload of the library in development; every view a LiveView, the sign-in and consent pages included.
6. **Operator config file.** A config provider merging an optional `config.exs` from the data dir into application config at boot, so a container declares policies without a rebuild (design § 2 Deployment). Also ends the dev trap of `explorer` declared in both `config/dev.exs` and `server/config/dev.exs`.
7. **Furniture upgrades.** `Beamlet.Tables` becomes an ordered list of up-only steps over `PRAGMA user_version`, run at boot (design § 2 Two databases). Step one creates `__kv` and `__routes` as today. A test proves a file at version zero reaches the current one.
8. **`beamlet reset`.** A CLI command wiping the agent database, the code dir with its git history and the files dir. Refuses while a beamlet runs in the VM.
9. **`beamlet eval`.** A CLI command evaluating a string of code on the running beamlet as the system principal and printing the result. Reaches the running node over distribution rather than booting its own beamlet. Lean: the operator's code skips the scanner, so it can print the instructions and descriptions straight off `Beamlet.MCP.*`.
10. **CI.** One workflow running `mix precommit` on every push.
11. **Code review.** Bugs and sloppy code across the library and the server, with a security read of the login and OAuth surface (the accepted items in design § 2 Login: session lifetime, password reset, no rate limit). Known candidates: a boot check for the migrations dir (the first image missed the library's `priv`); the authorizer's read of DBConnection's private holder record, fixed if an upstream option exists or recorded as a known issue; the Anubis transport plug's own 30-second default bounding every request, so the longer `request_timeout` the child spec computes has never applied, and the server-level `request_timeout` its HTTP plug ignores, a one-line upstream patch.
12. **Test review.** Flaky and pointless tests, and gaps the code review opens.
13. **Docs and package hygiene.** LICENSE; `package/0`, `docs/0` and a description in `mix.exs`; an ex_doc pass over the public `Beamlet.*` moduledocs; a CHANGELOG; a README covering what Beamlet is, running the image, embedding in prose (the child spec, the router line, what an endpoint must carry, `server/` as the example), and the security posture: the policy guards against accident, not adversaries, and tokens are the trust boundary.
14. **Release.** A tag publishes the package to hex and the image to GHCR. Version 0.1.0.
15. **Verify** the walkthrough script against the published image from claude.ai, ChatGPT and Claude Code, and the OAuth flow once more from each, since the pages became LiveViews after the last pass.

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
