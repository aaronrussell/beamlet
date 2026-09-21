# Beamlet — login and OAuth

**Status:** Design pass for roadmap 0.1 steps 1 to 4, completed 2026-09-21; phase 1 landed the same day and its settled items are in `design.md` § 2 Web. It records what the pass settled, why, and what each implementation phase still has to decide. As each phase lands, its settled items move into `design.md` § 2 and this note stays as the record of the reasoning.

**Last updated:** 2026-09-21

---

## 1. Why

A beamlet today authenticates one way: a token the operator mints on the CLI, sent as a bearer header. That works for Claude Code and for code, and for nothing else that matters.

- **ChatGPT** connects a custom server by OAuth or not at all. Its documentation lists OAuth, no authentication and a mixed mode, and says outright that it cannot present API keys. A single GitHub issue claims an "Access token" option in the dialog; nothing official, and no second report, supports it.
- **claude.ai** offers an individual user OAuth or no authentication. Its static-header option is a beta an organisation admin configures.
- **Claude Code** takes a header or does OAuth.
- **Code** takes a header only. The Anthropic Messages API's MCP connector, OpenAI's Responses MCP tool, and every agent SDK that connects to an HTTP MCP server carry a bearer value, because a server-side loop has no browser to complete a redirect.

So the two hosted chat clients need OAuth, and the audience's own agents need a header token. Both stay.

### Options considered

- **A token in the URL path**, selected as "no authentication" in the client. One vendor, Make, documents this for ChatGPT. ChatGPT runs an undocumented safety scan on new connectors and has rejected URLs carrying keys in query parameters; a path token has no confirmed rejection and no confirmed acceptance beyond Make. The secret lands in every request log along the way. And the person still pastes a secret into a third-party app, which is the thing OAuth removes. Rejected.
- **A stdio proxy** on the user's machine. Reaches only clients that spawn local processes, which excludes ChatGPT and claude.ai, the two clients the work is for. `mcp-remote` already exists for Claude Desktop and is worth a line on the home page. Rejected as a mechanism.
- **A hosted authorization server** such as Clerk, Auth0 or WorkOS. Removes the whole issuing half below: Beamlet becomes a resource server with a JWT validator and a mapping from subject to user. The cost is a third-party identity account as a hard runtime dependency of a self-hosted server, policy attaching to the user rather than the token because the provider's consent screen offers no choice, and an internet connection for local development. Rejected for 0.1, and kept in view: Beamlet's resource-server side is issuer-agnostic, so a beamlet could later point at an external issuer without touching the validator.
- **Elixir libraries.** None fits a SQLite-backed single-tenant server issuing opaque tokens. `boruta` depends on Postgres and is beta on its main line; `attesto_phoenix` is weeks old, JWT-only and Postgres-shaped; `ash_authentication_oauth2_server` needs Ash; `ex_oauth2_provider` has no PKCE. `jose` and `joken` sign JWTs, which Beamlet does not issue. Anubis 2.0 covers the resource-server half and nothing of the issuing half.

**The decision:** roll the authorization server ourselves and let Anubis be the resource server. The issuing half is a login, two OAuth endpoints, a consent page, a code store and a client-document fetch. Mapped out, it is a couple of days.

## 2. Vocabulary

The words the spec uses, since they do the work below.

- The **client** is the app connecting: ChatGPT, claude.ai, Claude Code. It identifies itself by a **client id**.
- The **resource server** is the MCP endpoint. Anubis plays it.
- The **authorization server** issues tokens. Beamlet plays it, at the same origin.
- **Protected resource metadata** (RFC 9728) is the JSON document the resource server publishes naming its authorization server. **Authorization server metadata** (RFC 8414) is the document the authorization server publishes naming its endpoints and what it supports.
- A **client ID metadata document** (CIMD) is how a client registers without registering: its client id is an https URL on its own domain, and the authorization server fetches a JSON document from it to learn the client's name and redirect URIs. **Dynamic client registration** (RFC 7591) is the older alternative, an unauthenticated endpoint that stores clients in a table. The 2026-07-28 revision of the MCP spec deprecates it. All three clients try CIMD first.
- **PKCE** binds an authorization to the client that started it: the client sends a hash of a secret when asking, and the secret itself when redeeming.
- An **authorization code** is the short-lived, single-use string the browser carries back to the client after consent. It stands for "this user consented to this client with this policy" and is worthless without the PKCE secret.
- The **access token** is what rides in the bearer header. The **refresh token** is redeemed for a new pair when the access token expires. **Rotation** means a refresh token dies the moment it is used.
- The **resource** parameter (RFC 8707) names the MCP URL a token is for, and the token is bound to it.

## 3. Settled

### Beamlet is the authorization server, Anubis is the resource server

The step 5 decision to write `Beamlet.MCP.Plug` rested on two reasons: Anubis's `authorization:` option needed `authorization_servers` and `resource` URLs Beamlet had no honest values for, and its claims are absent from `init/2` and task-style tool calls. The first reason is gone once Beamlet is an authorization server. The second still holds in Anubis 2.0.0 and costs nothing today: `init/2` reads no principal and Beamlet uses no tasks. Worth a look before the concurrency work in 0.2.

So the transport plug is Anubis's, mounted directly, with the `authorization:` option passed at start time from runtime config. Anubis then extracts the bearer, calls the validator, checks expiry and audience, answers a missing or bad token with a 401 carrying the `resource_metadata` challenge, and puts the claims in the frame's context on every request. `Beamlet.MCP.Validator` implements Anubis's validator behaviour: hash the presented secret, find the row, check its expiry, return claims with the audience set to the MCP URL and the principal alongside. The three places that read `frame.assigns.principal` read the context instead. `Beamlet.MCP.Plug` goes.

What is lost: the 403 with a teaching line for a token naming a policy the beamlet no longer declares. A validator failure is always a 401. Accepted.

Anubis keeps the parsed authorization config in one persistent term per server module per VM. Tests use a fixed public URL so beamlets started per test do not overwrite each other's.

### Tokens: opaque, one table, two kinds

Argued without reference to the existing table. A JWT access token needs a signing key that survives restarts and a JOSE dependency, and cannot be revoked before expiry without a denylist, so it needs short lifetimes and therefore stored refresh tokens. The table comes back holding refresh tokens instead of access tokens. What a JWT buys is validation by a process that cannot reach the store, which a single-node beamlet never needs. An opaque secret with its hash in a local SQLite file validates in one indexed read, needs no key, and gives CLI and OAuth tokens one row shape. Opaque, on its merits.

One table, `tokens`, with a `kind`: an `Ecto.Enum` of `:cli` and `:oauth` stored as strings. The kind is a column and not a reading of which fields are null, because the two kinds differ in three columns already and an implicit rule breaks the day a fourth arrives.

- **`cli`**: minted by `tokens.create USER LABEL [--policy NAME]`, the secret shown once. `client` holds the label, validated by the existing name rule since it lands in a git trailer. `expires_at` and the refresh fields are null: a CLI token never expires and is revoked by delete. This is how the operator's own code connects.
- **`oauth`**: minted by the token endpoint after consent. `client` holds the client id URL verbatim, the identity the redirect was verified against; the document's `client_name` is display only and anyone can host a document that says "ChatGPT". `expires_at`, `refresh_hash` and `refresh_expires_at` required. Refresh rotates in place: new secret and refresh hashes on the same row, so the token id stays stable for provenance. This is how a chat client connects.

`name` goes; `client` replaces it in the principal and the provenance trailers, rendered as the label or as the client id's host. Nothing is unique on `client`: a person may authorize the same client twice. Two changeset functions, `cli_changeset/2` and `oauth_changeset/2`, each readable on its own; the context picks by kind. `tokens.delete` and `tokens.update` address a token by the id `tokens.list` prints, since there is no name. The token endpoint refuses to refresh a `cli` token.

Policy stays on the token. For an OAuth token it is chosen on the consent page; for a CLI token it is the flag. Beamlet advertises no scopes: OAuth scopes are strings the client asks for and the server may grant in part, and the consent page is entirely the server's to design, so a radio list of the declared policies is legitimate and the choice never needs to be a scope. Clients cope with an empty scope set.

### Login

A user gains a nullable `password_hash`. `users.create NAME` prompts for a password unless `--no-password` is given; `users.update NAME --password` resets it. Prompted, so it never lands in shell history. `authenticate_password/2` refuses a null hash. No native hashing dependency, so the Dockerfile is untouched; phase 1 chose `pbkdf2_elixir`.

The session is the cookie session the host's endpoint already carries. Beamlet's router grows a browser pipeline that fetches it and protects forms from forgery, a `require_login` plug that stores the return path and redirects to the login page, and a LiveView `on_mount` that reads the signed-in user. A web identity remains a user on a request with no token and no policy, exactly as design § 2 has it; the login is how the authorize endpoint knows who is consenting, and nothing more.

### Client identity: metadata documents only

CIMD only. No dynamic registration, no clients table, no unauthenticated write endpoint. The metadata advertises `client_id_metadata_document_supported: true` and `none` as the token endpoint auth method, which is the pair claude.ai requires before it chooses CIMD. The fallback is added the day verification proves a client needs it, not before.

`Beamlet.OAuth.Clients` fetches the document with an outbound https request and a guard: https only, the client id must equal the document's own `client_id`, no private, loopback or link-local addresses, a body cap, a short timeout, and a cache by URL. Redirect URIs must match the document exactly, with one exception: when the document lists a portless loopback URI, `http://localhost/callback` or `http://127.0.0.1/callback`, the beamlet accepts either host on any port, which is what Claude Code sends and what its shipped versions have got wrong in both directions.

### The flow, endpoint by endpoint

1. **Discovery.** A client calls `/beamlet/mcp` with no token and gets a 401 naming the protected resource metadata URL. It fetches that document, which names this origin as the authorization server, then fetches the authorization server metadata at `/.well-known/oauth-authorization-server`, which names the two endpoints below and declares S256, the code and refresh grants, `none` auth, CIMD support and `iss` support.
2. **Authorize.** `GET /beamlet/authorize` with `client_id`, `redirect_uri`, `state`, `code_challenge`, `code_challenge_method=S256` and `resource`. Every parameter is validated; a request the beamlet cannot redirect for, an unknown client or a bad redirect URI, renders an error page rather than redirecting. `resource` must equal the MCP URL. A signed-out user goes to the login page and returns. The consent page names the client's host, warns when the redirect is loopback only, and lists the declared policies with `default` selected.
3. **Consent.** `POST /beamlet/authorize` stores a code and redirects the browser to the client with `code`, `state` and `iss`.
4. **Exchange.** `POST /beamlet/token`, form-encoded, `grant_type=authorization_code`. The beamlet looks the code up, deletes it, checks the client id, redirect URI and `resource` match what the code was issued for, checks the SHA-256 of the `code_verifier` against the stored challenge, and calls `Users.create_token` with the consented policy. The JSON reply carries the access token, `token_type`, `expires_in` and the refresh token. Errors are OAuth error bodies, `invalid_grant` and friends, because the client reads them.
5. **Refresh.** Same endpoint, `grant_type=refresh_token`. Look up the refresh hash, check its expiry, rotate in place, reply with the new pair. A used or expired refresh token is `invalid_grant`, which is what the clients expect.

`Beamlet.OAuth.Codes` is the store for step 3 to step 4: a GenServer holding a map of pending codes, each with the user, policy, client id, redirect URI, challenge and resource, a ten-minute expiry checked at lookup, single use by the lookup deleting the entry, and a periodic sweep so abandoned flows do not accumulate. A restart mid-flow means the client gets `invalid_grant` and the person clicks connect again.

### URLs

The beamlet's own routes live under one named segment, `/beamlet`, and the reservation rule in design § 2 becomes "a first segment that is `beamlet`"; the underscore rule goes and `~` is unchanged. Revised at the phase 1 planning pass from the `/_/` this pass first chose: the underscore was a marker for paths no person types, and once the beamlet had pages for a browser, `/_/login` read as a mistake where `/beamlet/login` reads as what it is. `/beamlet/mcp`, `/beamlet/live` and `/beamlet/assets` move; `/beamlet/login`, `/beamlet/logout`, `/beamlet/authorize` and `/beamlet/token` arrive; the admin pages come later under the same segment. The rule is exact, the router gets one scope, and an operator reading logs sees every beamlet-owned path share a prefix. The beamlet's own paths never take the operator's prefix, which fences agent routes only. The well-known documents stay at the root, where the spec fixes them, and the protected resource one is served both bare and with the MCP path appended, since clients try the suffixed form first.

The public URL comes from the endpoint's `url` config through `Beamlet.Config`, not a new key. `resource` is that origin plus `/beamlet/mcp`, byte for byte what the client uses; `issuer` is the origin.

### Namespaces

Web pieces live under `Beamlet.Web`: the existing `Layouts` and `ErrorView` move there, beside `Auth`, `SessionController` and `HomeLive`. OAuth pieces live under `Beamlet.OAuth`. The validator sits with the MCP pieces under `Beamlet.MCP`.

### Home page

The home page is `/beamlet`, the root of the beamlet's own segment, and it requires the login: the person setting up a client is the person with an account, and nobody else has business there. Phase 1 lands it as a stub that shows the signed-in user's name; phase 4 makes it the setup page; 0.5 grows the admin pages beside it. `/` belongs to agents and is empty by default: nothing in the beamlet's router touches it, so the generated router, its placeholder and the boot shortcut are as they were, and the default 404 says where the beamlet has its own pages. This replaced the pass's first shape, a home page at `/` served only while nothing was mounted there, which needed a fallback route in the generated router, a placeholder that carried it and a boot check that knew it, and left the post-login redirect pointing at a page that might not exist.

### Pre-release

The existing users and tokens migration is edited in place and the dev data dir is reset. No migration path.

## 4. Phases

Each phase is one agent session, starts with its own planning pass, and ends with `mix precommit` green and its settled items moved into `design.md`.

### Phase 1 — Login, sessions, the `/beamlet` namespace and the home page

Roadmap step 2, plus the router restructure that everything after needs. Landed 2026-09-21; the settled items are in `design.md` § 2 Web under "Root by default", "Two routers", "What the host carries" and "Login".

**Scope.** The `/beamlet` segment with the existing three paths moved and the mount-time reservation check updated, the underscore rule dropped. The `Beamlet.Web` namespace with `Layouts` and `ErrorView` moved. `password_hash` on users, `users.create` prompting for a password and `users.update --password` resetting it, `users` showing who can sign in. `authenticate_password/2`. The browser pipeline, `Beamlet.Web.Auth` with `fetch_current_user`, `require_login` and the `on_mount` hook. `GET` and `POST /beamlet/login` as `SessionController` `:new` and `:create`, `POST /beamlet/logout` as `:delete`. `HomeLive` at `/beamlet` behind the login, showing the user's name. Tests through `Plug.Test` and LiveView tests.

**Settled at the planning pass:**

- `pbkdf2_elixir` over `Plug.Crypto`'s key generator: the format, the dummy verify and the rounds setting are its job. Eight to 128 characters.
- The prompt: `:io.get_password/0` answers `enotsup` under `-noshell`, so the CLI switches to OTP 28's raw no-shell mode for the read and back after; a pipe reads a plain line. Hex's line-clearing trick lost because the characters echo before they are erased.
- `require_login` stores a GET's path in the session; the login lands there or on `/beamlet`. Login lasts until sign-out or the browser drops the cookie; a password reset ends no other session.
- The endpoint contract was wrong to say JSON only: it parses JSON and form bodies. The server endpoint gained `Plug.RewriteOn` so the session cookie is marked secure behind Fly's proxy. The signing salts stay: a salt is not a secret, and replacing one constant with another changes nothing.
- No rate limiting in 0.1.
- The dev data dir was wiped for the edited migration.

### Phase 2 — The resource server

The half of roadmap step 3 that makes Anubis the edge. After it, CLI tokens still work, through Anubis's plug rather than Beamlet's, and a missing token gets the spec-shaped 401.

**Scope.** The tokens migration edited: `kind`, `client` in place of `name`, `expires_at`, `refresh_hash`, `refresh_expires_at`. `Beamlet.Token` with the two changesets. `Beamlet.Users` mint and list functions taking the new shape; `tokens.create USER LABEL`, `tokens.list` printing id, kind, client, policy and expiry, `tokens.delete` and `tokens.update` by id. `Beamlet.Principal` carrying `client` in place of the token name, and the provenance encodings rendering it. The public URL in `Beamlet.Config`. The `authorization:` option built at runtime and passed to the server's child spec. `Beamlet.MCP.Validator`. The three call sites reading the context. `Beamlet.MCP.Plug` removed and the router mounting Anubis's plug at `/beamlet/mcp`. `MetadataController` serving the protected resource document bare and suffixed, and the authorization server document. `Beamlet.Case` minting a `cli` token. Tests asserting the 401 challenge, both metadata documents, and that a `cli` token authenticates as before.

**Decided:** everything in § 3 on the authorization server split, tokens, and the metadata contents.

**Open:**

- How the validator hands the principal to the components: under a key in the claims map Anubis stores as raw claims, or rebuilt from the token id it returns. The former is one lookup per request, the latter two.
- Whether `Beamlet.MCP.Server`'s `handle_request` override needs any change beyond the read, given the claims are absent from `init/2`.
- The exact field list of both documents, checked against what claude.ai and ChatGPT read, including whether `scopes_supported` is omitted or empty.
- Whether the suffixed protected resource path is reachable through the root forward as the router is shaped, or needs its own route ahead of it.

### Phase 3 — The authorization server

The other half of roadmap step 3: issuing.

**Scope.** `Beamlet.OAuth.Clients` with the fetch, the guard, the cache and loopback matching. `Beamlet.OAuth.Codes`. `AuthorizeController` `:new` and `:create` with the consent page and the error page. `TokenController` `:create` with both grants and the OAuth error bodies. Refresh rotation in place. The `iss` parameter. Tests driving the whole flow through `Plug.Test` with `Req.Test` standing in for the client document, then verification by hand against Claude Code locally and, on Fly, against claude.ai and ChatGPT.

**Decided:** everything in § 3 on client identity and the flow.

**Open:**

- Lifetimes. An access token of hours and a refresh token of weeks is the usual shape; the numbers are a planning-pass choice. ChatGPT is reported to break at access-token expiry when it cannot refresh, so the refresh path is verified against it specifically.
- Scope handling. Clients send scopes they were never offered, `offline_access` among them. Accept any, grant none, echo none, or echo what was sent: to be decided by what the clients do with the reply.
- The SSRF guard's mechanics: whether the address check happens on the resolved IP before connecting, and how Req is told to do that.
- Whether the flow completes against plain http on localhost from Claude Code. Claude Code runs discovery against http origins and documents no restriction, but no report confirms a completed flow. One check, once the endpoints exist. If it fails, local Claude Code use is by CLI token and the flow is verified on Fly.
- Consent copy, and whether the page shows a client's `client_name` at all given it is untrusted.
- What `tokens.list` shows for an OAuth token's client: the URL, or its host with the path.

### Phase 4 — The home page

Roadmap step 4.

**Scope.** `HomeLive` at `/beamlet` becomes the setup page: the MCP URL, how to add the beamlet in claude.ai, ChatGPT and Claude Code and sign in, the `mcp-remote` line for Claude Desktop, and the CLI commands for code that takes a header. It sits behind the login, so a signed-out visitor sees the login page first.

**Decided:** what it lists, and that it lives at `/beamlet` behind the login.

**Open:**

- The exact copy per client, written after phase 3's verification so it matches what each dialog actually shows.
- Whether the page offers to mint a CLI token for the signed-in user, or points at the CLI only. The design's line is that management is operator-only; the planning pass decides whether a page minting a token for its own user crosses it.
- Whether the page also lists the user's tokens for revocation, or leaves that to `/beamlet/admin` in 0.5.
