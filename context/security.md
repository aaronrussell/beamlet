# Beamlet — security

**Status:** Standing context: the threat model, the rule for deciding what to fix, and the risks accepted. Written from the 0.1 code review and checked against the code by the pre-release review. The mechanism lives in `design.md`; this note says what it defends, what it does not, and why, and points there. Update it in the same piece of work as any change that adds an input Beamlet reads back, touches the token edge or the app, changes a grant or a guardrail, or accepts or closes a risk.

**Last updated:** 2026-10-09 (the image's firewall and users)

---

## 1. The stance

> A beamlet belongs to one person. Tokens are that person's delegations to their clients. Policies steer each client. Treat any token as full access to the beamlet.

Beamlet is self-hosted, secure enough out of the box and hackable by choice, and does not save the owner from themselves.

Agent code runs in the beamlet's own VM. Some ways past a policy cannot be closed without taking the stdlib away: a map claiming to be a `File.Stream` struct, handed to `Enum`, runs Elixir's own file code, and no check Beamlet owns ever sees it. So the policy and the scanner are guardrails, not containment. They stop an honest model's accidents and low-effort prompt injection, which reaches for ordinary APIs ("fetch this URL", "read this file") rather than crafted exploits. Containing code that is trying to get out would take an isolation boundary, agent code in an OS process or node of its own with its own filesystem, and none is planned.

So the token is the boundary. What a token reaches past its policy is what the owner already holds, and with one owner there is no one else to protect it from.

## 2. Trust map

**Trusted:** the owner; shell access to the host, which outranks everything (so `beamlet setup` never asks for the current password); the operator config file; Beamlet's own code and the packages it ships.

**Untrusted:**

- **A request without a valid token.** It reaches the sign-in and OAuth pages and nothing else.
- **Agent code.** Guardrailed by its token's policy, not contained.
- **Anything agent code can write.** Agents have raw SQL on the agent database, so a `__kv` row, a `schema_migrations` version, or anything else Beamlet reads back from that file may hold what no changeset allowed. That is why the agent database holds only what agent code itself reads and writes, and why the routes moved out of it (design § Two databases): a durable record Beamlet acts on lives in the beamlet's database or the code dir, whoever created it. What stays in the agent database feeds nothing but data: KV values are strict JSON, a format that cannot express a fun, and Beamlet's own compiles, which are not scanned, take quoted form rather than text. The review's two worst findings were this one mistake, Beamlet trusting bytes an agent could write; the rule is what keeps it from recurring.
- **What arrives from outside.** The bearer header (hashed and looked up, so a malformed value matches nothing); a client's metadata document and its redirect URIs (fetched behind an SSRF guard, script-capable schemes refused); URLs agent code is told to fetch by text it has read (the outbound guard).
- **Script on agent pages.** Agent pages share the beamlet's origin with the app, and the browser sends the app's cookie with any request under `/beamlet`, whichever page makes it.

## 3. The boundary it holds

- **The token edge.** `Beamlet.MCP.Plug` hashes the bearer, looks it up, checks an OAuth token's expiry and that its policy is still declared, and builds the principal fresh on every request; only Beamlet's own tokens are valid (design § Login and OAuth, § The owner, tokens and principals).
- **Secrets.** Tokens, refresh tokens, session secrets and OAuth codes are random, shown once and stored as SHA-256 hashes. The server's `filter_parameters` keeps the password, `code`, `code_verifier` and `refresh_token` out of the logs.
- **OAuth.** S256-only PKCE; single-use codes bound to client, redirect, policy and resource; exact redirect matching, except that a listed loopback URI matches either loopback host on any port (RFC 8252); no script-capable redirect schemes; refresh rotation as a compare-and-swap, so a refresh secret redeems once.
- **Sign-in.** A dummy verify keeps timing flat for an unknown email, a missing owner and a wrong password, and a password over 128 bytes is refused before hashing.
- **The app and the agent side kept apart** (design § Login and OAuth, § Web). The app's session is its own cookie, scoped to `/beamlet` and HTTP-only, carrying the secret of a session row rather than an identity, so an agent route that writes the endpoint's session or signs a cookie with `secret_key_base` gains nothing. The app's LiveViews use their own socket, so agent pages do not receive the app session by accident; § 6 says what a page that chooses its socket gets. `Beamlet.Router` answers 404 for every `/beamlet` path it does not own, so no agent route ever receives the app's cookie. A new piece of the app takes the app's plumbing, never the agent side's. The split holds while nothing in the host fetches the session before the forward: a session already fetched stays the host's, and a sign-in would land in the cookie agent pages read and write. The standalone server fetches none; `Beamlet.Router` warns an embedder, and a plug enforcing it is in the roadmap.
- **The image's bound** (design § Deployment). Not part of the token boundary, which code past the policy has already crossed, but what that code reaches beyond the beamlet. A firewall set at start holds outbound traffic to DNS and public TCP, except port 25, plus the hosts the operator opens with `BEAMLET_HTTP_ALLOW`, closing the private network, the cloud metadata address and on Fly the Machines API and the owner's other apps. The release runs as `beamlet` with no capabilities, so it cannot change the rules, and owns only `/data`, so it cannot change what root runs. Root inside the container can undo the rules, so what root runs must not read what `beamlet` can write: the rules take nothing from the data dir, every release command drops to `beamlet` before evaluating the operator file, and git refuses the code dir to root. A suspected escape still means the data dir, and the secrets in it, are the attacker's.

## 4. The guardrails

What steers a token, each a guardrail under § 1:

- **The policy and the scanner** (design § Policy): which tools, which shape rules, which names agent code may call. The grant table keeps anything that builds or loads code denied, `:crypto`'s engine family included. The scanner judges names at call sites and the targets the compiler expands, never the values passed as arguments. A function that does harm through its arguments is denied by name, or left granted and listed below.
- **The outbound guard** on `Host.HTTP` (design § HTTP): loopback, private, link-local and cloud metadata addresses are refused on every hop, opened per beamlet with `config :beamlet, http: [allow: [...]]`. This is the main defence against "fetch this URL" injection, and why `Host.HTTP` refuses the options that would send a request somewhere the guard never checked.
- **Scoped storage.** `Host.File` under the files dir; an authorizer on the agent database refusing `ATTACH`, `DETACH` and `VACUUM INTO`.

**Known open, by design.** Each of these is a way past the policy that stays open because an easier route of the same kind does. Do not propose closing them one at a time; only an isolation boundary closes the class.

- **Module names as data.** A library function or macro handed a module calls it, and the scanner checks names in call position only: `plug Plug.Static` in an agent controller, a `{mod, fun, args}` value for `with:` on `cast_assoc/3` or for `autogenerate:`, `defaults:` and `preload_order:` in a schema, the repo given to `unsafe_validate_unique/3`, the type given to `Ecto.ParameterizedType.init/2`, and a controller view or a LiveView layout, each of which renders through any module's one-argument function. Where agent code can do without such a function it is denied by name instead: `Ecto.Multi.run/5` and `merge/4`, the `Exception` functions that take a stacktrace, and the plumbing of `Ecto.Schema` and `Ecto.Type`.
- **Forged structs.** A map with a `__struct__` key runs that struct's protocol implementations, and a struct built by hand carries what its constructors would refuse: an `Ecto.Multi` holding a `{:run, {mod, fun, args}}` operation runs it in `Host.Repo.transaction`. Struct literals are not checked against the grants for this reason.
- **Macros expand after the scan.** The scanner reads the source as written, so a macro of a granted module expands unscanned: `~w(...)a` makes atoms, and an expression inside `~H` calls what it names, with neither the refusal nor the `Host.File` redirect.
- **Atoms at runtime.** `String.to_atom/1` and `List.to_atom/1` are denied, completing that rule, but `Jason.decode` with `keys: :atoms` and `~w(...)a` (macros, above) still make them.
- **Req's options as data.** `Host.HTTP` refuses what bypasses the guard or reaches the disk and leaves the rest to Req.
- **The shared pool.** Code defined under a permissive token is callable from a restrictive one, as is a macro defined under `allow_defmacro`.
- **The `Beamlet.Code` table** is public and named, safe only while no policy grants `:ets`.
- **Taking the beamlet down.** Dropping `__kv`, atom exhaustion and the like stop a beamlet or part of it; the owner restarts or resets it.

## 5. Deciding what to fix

Every finding, and every new feature's failure mode, falls into one of three groups, and the group decides whether it is worth fixing:

1. **Crosses the token boundary.** Someone with no token gains something. Always fix.
2. **Lets a token holder exceed its policy.** Fix only when it is cheap, steers normal use, or completes a rule that already exists. Never add complexity to close an escape while an easier one of the same class stays open.
3. **Correctness, robustness, readability.** Untouched by the stance; judge on merit.

For a new feature the questions are: does it add a durable record Beamlet acts on (it goes in the beamlet's database or the code dir, never the agent database, whoever creates it; what agent code can write is untrusted and feeds compiles as data only); does it add a page or a cookie to the app (it takes the app's plumbing); does it widen a grant (anything that builds or loads code stays denied); does it make an outbound request (behind the guard).

The cost of skipping this: `Host.HTTP` was first built as a fail-closed allowlist with value checks on every option that takes code, and the review removed it all once the stance made clear it stopped only a deliberate escaper.

## 6. Accepted risks

Each with why it is accepted and what reopens it.

- **Script on an agent page can act as the signed-in owner.** It can drive the consent page, and it can join its own LiveView on the app's socket, so the page's server code receives the app session and the owner's session secret, which has no expiry and outlives the token that wrote the page. A token holder acting as the owner, which § 1 concedes. Fix chosen (roadmap): the password on every Allow, signed in or not, so neither the page nor the secret mints a token, and client ids on the beamlet's own host refused. A separate origin for agent pages is the complete fix for both, needed if pages are shared publicly.
- **No rate limit on the sign-in.** One owner, one password; the README asks for a strong one. Revisit when the admin UI adds sensitive actions.
- **A session has no expiry of its own.** It ends at sign-out, a new password, or when the browser drops the cookie.
- **A new password from `beamlet setup` does not disconnect open app pages.** Every session is deleted, so the next reload goes to the login; the CLI has no way to the server's PubSub (roadmap).
- **DNS rebinding** in the outbound guard and the client-document fetch: the name is resolved again when the connection is made. Pinning the address costs a Finch pool per host. In the image the firewall checks the address connected to, so a rebind to a private address is refused there; an embedder has no such bound.
- **Shell access edits anything**, the code dir and the databases included, and the operator config file can set any application's keys. Shell access is the owner.
- **Small items** with a fix each, unscheduled: the security minors under the roadmap's Hardening.

## 7. What reopens the stance

The stance holds while each of these stays true. When one changes, revisit § 1 and re-sort group 2.

- **One person.** More than one user would need isolation between principals, which policies cannot give.
- **The owner wrote or approved the code.** Agent-installed dependencies (roadmap) run package code under grants.
- **Agent pages are seen by the owner only.** Sharing them publicly puts visitors' browsers on the app's origin; that is the trigger for a separate origin.
- **Agent paths never see an identity.** Private routes (roadmap) need the owner recognised there, through a second, weaker cookie that is never the app's.
- **Every principal comes from a token.** A principal handed in by an embedder calling tools in-process (roadmap, an idea) has no edge to authenticate it.
- **Agent code shares the VM.** An isolation boundary would make the policy containment, and group 2 findings worth fixing again.
