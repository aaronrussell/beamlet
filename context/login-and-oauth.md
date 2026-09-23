# Beamlet — login and OAuth

**Status:** Design pass for roadmap 0.1 steps 1 to 3 and 5, completed 2026-09-21; phases 1 to 3 landed the same day and phase 4 on 2026-09-22, and their settled items are in `design.md` § 2. It records what the pass settled, why, and what each implementation phase still has to decide. As each phase lands, its settled items move into `design.md` § 2 and this note stays as the record of the reasoning. Where a phase's planning pass reversed the design pass, the section says so and keeps the original reasoning beside the reversal.

**Last updated:** 2026-09-22

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

**The decision:** roll the authorization server ourselves and let Anubis be the resource server. The issuing half is a login, two OAuth endpoints, a consent page, a code store and a client-document fetch. Mapped out, it is a couple of days. (The resource-server half moved into Beamlet's own plug at the phase 2 planning pass; § 3 records why.)

## 2. Vocabulary

The words the spec uses, since they do the work below.

- The **client** is the app connecting: ChatGPT, claude.ai, Claude Code. It identifies itself by a **client id**.
- The **resource server** is the MCP endpoint. Beamlet plays it, in its own plug in front of Anubis's transport (revised at phase 2, § 3).
- The **authorization server** issues tokens. Beamlet plays it too, at the same origin.
- **Protected resource metadata** (RFC 9728) is the JSON document the resource server publishes naming its authorization server. **Authorization server metadata** (RFC 8414) is the document the authorization server publishes naming its endpoints and what it supports.
- A **client ID metadata document** (CIMD) is how a client registers without registering: its client id is an https URL on its own domain, and the authorization server fetches a JSON document from it to learn the client's name and redirect URIs. **Dynamic client registration** (RFC 7591) is the older alternative, an unauthenticated endpoint that stores clients in a table. The 2026-07-28 revision of the MCP spec deprecates it. All three clients try CIMD first.
- **PKCE** binds an authorization to the client that started it: the client sends a hash of a secret when asking, and the secret itself when redeeming.
- An **authorization code** is the short-lived, single-use string the browser carries back to the client after consent. It stands for "this user consented to this client with this policy" and is worthless without the PKCE secret.
- The **access token** is what rides in the bearer header. The **refresh token** is redeemed for a new pair when the access token expires. **Rotation** means a refresh token dies the moment it is used.
- The **resource** parameter (RFC 8707) names the MCP URL a token is for, and the token is bound to it.

## 3. Settled

### Beamlet plays both OAuth roles; Anubis is the transport

Revised at the phase 2 planning pass. The design pass chose to make Anubis the resource server: mount its transport plug directly with the `authorization:` option, write a `Beamlet.MCP.Validator` for its validator behaviour, read the claims from the frame's context, and drop `Beamlet.MCP.Plug`. Its reasoning was that the step 5 objections to Anubis's authorization, that it needed `authorization_servers` and `resource` URLs Beamlet had no honest values for and that its claims are absent from `init/2` and task-style tool calls, lost their force once Beamlet was an authorization server, and that riding what Anubis offers would remove code.

Read against Anubis 2.0.0 and the router, the trade did not hold. What Anubis's authorization does is extract the bearer, call the validator, check expiry and audience, send the 401 with the `resource_metadata` challenge, and put the claims on the frame. Matching that in Beamlet's own plug is one header parameter and one expiry clause; audience is a no-op, since a Beamlet token is only ever for this beamlet. What the validator route would have cost, each found in the code: a wrapper plug anyway, because the transport's `request_timeout` is a plug init option fixed when the router compiles while Beamlet's limits are runtime config; the public URL at server start, because Anubis parses its option when the server supervisor starts, before the endpoint exists, which would have forced a new config key; a guard in `handle_request` for a `tools/call` carrying task metadata, which Anubis dispatches with a frame that has no claims; an idle Finch pool Anubis starts for its HTTP-calling validators; a persistent term per server module for tests to respect; and the 403 with its teaching line, since a validator failure is always a 401.

So `Beamlet.MCP.Plug` stays and is where both roles meet the transport: it authenticates the bearer through `Beamlet.Users`, refuses an `oauth` token past its expiry, and answers a missing or bad token with a 401 whose challenge names the protected resource metadata document. `Beamlet.OAuth` holds the shared facts, the issuer, the resource and the two documents, built at request time from the endpoint's `url` config. Anubis stays the transport and nothing else.

Two things the pass found in passing, for the code review step or upstream: the transport plug's own 30-second default bounds every request today, so the longer `request_timeout` the child spec computes has never applied; and Anubis has a server-level `request_timeout` its HTTP plug ignores in favour of its own, which a one-line upstream patch would fix.

### Tokens: opaque, one table, two kinds, two columns

Argued without reference to the existing table. A JWT access token needs a signing key that survives restarts and a JOSE dependency, and cannot be revoked before expiry without a denylist, so it needs short lifetimes and therefore stored refresh tokens. The table comes back holding refresh tokens instead of access tokens. What a JWT buys is validation by a process that cannot reach the store, which a single-node beamlet never needs. An opaque secret with its hash in a local SQLite file validates in one indexed read, needs no key, and gives CLI and OAuth tokens one row shape. Opaque, on its merits.

One table, `tokens`, with a `kind`: an `Ecto.Enum` of `:cli` and `:oauth` stored as strings. The kind is a column and not a reading of which fields are null, because the two kinds differ in several columns already and an implicit rule breaks the day another arrives.

- **`cli`**: minted by `tokens.create NAME --user USER [--policy NAME]`, the secret shown once. `name` holds the label, required, unique per user and validated by the existing name rule since it lands in a git trailer. `expires_at` and the refresh fields are null: a CLI token never expires and is revoked by delete. This is how the operator's own code connects.
- **`oauth`**: minted by the token endpoint after consent. `client` holds the client id URL verbatim, the identity the redirect was verified against; the document's `client_name` is display only and anyone can host a document that says "ChatGPT". `expires_at`, `refresh_hash` and `refresh_expires_at` required; `name` null. Refresh rotates in place: new secret and refresh hashes on the same row, so the token id stays stable for provenance. This is how a chat client connects.

Two columns, `name` and `client`, each required by one kind (revised at the phase 2 planning pass from one `client` column holding either; two honest columns read better than one overloaded, and the kind still says which applies). `Beamlet.Token.label/1` is the display form of either, the name or the client URL's host, and is what the principal carries as `token_label` and what the provenance trailers and the listing print: `Token: laptop (3)` or `Token: claude.ai (7)`. Nothing is unique on `client`: a person may authorize the same client twice. Two changeset functions, `cli_changeset/2` and `oauth_changeset/2`, each readable on its own; the context picks by kind. Tokens are addressed by the id the listing prints, since an OAuth token has no name: `tokens [--user USER]`, `tokens.update ID` for CLI tokens only, `tokens.delete ID` for either. The token endpoint refuses to refresh a `cli` token.

Policy stays on the token. For an OAuth token it is chosen on the consent page; for a CLI token it is the flag. Beamlet advertises no scopes: OAuth scopes are strings the client asks for and the server may grant in part, and the consent page is entirely the server's to design, so a radio list of the declared policies is legitimate and the choice never needs to be a scope. Clients cope with an empty scope set.

### Login

A user gains a nullable `password_hash`. `users.create NAME` prompts for a password unless `--no-password` is given; `users.update NAME --password` resets it. Prompted, so it never lands in shell history. `authenticate_password/2` refuses a null hash. No native hashing dependency, so the Dockerfile is untouched; phase 1 chose `pbkdf2_elixir`.

The session is the cookie session the host's endpoint already carries. Beamlet's router grows a browser pipeline that fetches it and protects forms from forgery, a `require_auth` plug that stores the return path and redirects to the login page, and a LiveView `on_mount` that reads the signed-in user. A web identity remains a user on a request with no token and no policy, exactly as design § 2 has it; the login is how the authorize endpoint knows who is consenting, and nothing more.

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

The public URL comes from the endpoint's `url` config, not a new key: `Beamlet.OAuth` reads `Endpoint.url/0` at request time, the way `Host.Router.url/1` does, which is why it can never be needed at boot (see the first section above). `resource` is that origin plus `/beamlet/mcp`, byte for byte what the client uses; `issuer` is the origin.

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

**Scope.** The `/beamlet` segment with the existing three paths moved and the mount-time reservation check updated, the underscore rule dropped. The `Beamlet.Web` namespace with `Layouts` and `ErrorView` moved. `password_hash` on users, `users.create` prompting for a password and `users.update --password` resetting it, `users` showing who can sign in. `authenticate_password/2`. The browser pipeline, `Beamlet.Web.Auth` with `fetch_current_user`, `require_auth` and the `on_mount` hook. `GET` and `POST /beamlet/login` as `SessionController` `:new` and `:create`, `POST /beamlet/logout` as `:delete`. `HomeLive` at `/beamlet` behind the login, showing the user's name. Tests through `Plug.Test` and LiveView tests.

**Settled at the planning pass:**

- `pbkdf2_elixir` over `Plug.Crypto`'s key generator: the format, the dummy verify and the rounds setting are its job. Eight to 128 characters.
- The prompt: `:io.get_password/0` answers `enotsup` under `-noshell`, so the CLI switches to OTP 28's raw no-shell mode for the read and back after; a pipe reads a plain line. Hex's line-clearing trick lost because the characters echo before they are erased.
- `require_auth` stores a GET's path in the session; the login lands there or on `/beamlet`. Login lasts until sign-out or the browser drops the cookie; a password reset ends no other session.
- The endpoint contract was wrong to say JSON only: it parses JSON and form bodies. The server endpoint gained `Plug.RewriteOn` so the session cookie is marked secure behind Fly's proxy. The signing salts stay: a salt is not a secret, and replacing one constant with another changes nothing.
- No rate limiting in 0.1.
- The dev data dir was wiped for the edited migration.

### Phase 2 — The resource server

The half of roadmap step 3 that gives the edge its OAuth shape. Landed 2026-09-21; the settled items are in `design.md` § 2 under "Users, tokens and principals", "MCP" and "Web". After it, CLI tokens work as before and a missing token gets the spec-shaped 401.

**Scope as landed.** The tokens migration edited: `kind`, `name` nullable, `client`, `expires_at`, `refresh_hash`, `refresh_expires_at`. `Beamlet.Token` with the two changesets and `label/1`. `Beamlet.Users` minting by kind, `list_tokens/0`, `find_token/1`, `update_token/2` refusing an `oauth` token, `authenticate/1` refusing an expired one. The CLI reshaped: `tokens [--user USER]` with the columns id, kind, user, label, policy and created, `tokens.create NAME --user USER`, `tokens.update ID` and `tokens.delete ID`. `Beamlet.Principal` carrying `token_label`. `Beamlet.MCP.Plug` kept, its 401 challenge naming the protected resource metadata document under the realm `beamlet`. `Beamlet.OAuth` with the issuer, the resource and both documents; `Beamlet.OAuth.MetadataController` serving the protected resource document bare and with the MCP path appended, and the authorization server document, as three exact routes at the root of `Beamlet.Router`. Tests through `Plug.Test` and `Phoenix.ConnTest`.

**Settled at the planning pass:**

- The reversal recorded in § 3: Beamlet's own plug, no validator, no `authorization:` option, no URL config key.
- Two columns, `name` and `client`, and the label; see § 3 Tokens.
- The documents omit `scopes_supported`. Claude Code requests the scopes a protected resource document lists and works without any; ChatGPT requests every scope the authorization server document lists and expects an exact echo; so listing none is what makes the consent page's policy choice the whole story. The authorization server document is published now and names endpoints that answer 404 until phase 3.
- The three well-known routes are exact paths ahead of the root forward, and `.well-known` is not a reserved segment: an agent may have its own use for the directory, and the three paths win by order.
- Anubis's task-style dispatch is moot with the principal in the conn's assigns, which Anubis merges into the frame on every message.

### Phase 3 — The authorization server

The other half of roadmap step 3: issuing. Landed 2026-09-21; the settled items are in `design.md` § 2 under "MCP" as "The authorization server" and in the path list under "Web". Verification by hand follows: locally over a Tailscale funnel, connecting the MCP Inspector, the Claude app, ChatGPT and Raycast by OAuth, to see what each dialog shows and sends.

**Scope as landed.** `Beamlet.OAuth.Clients` with the fetch, the guard, the hour-long cache and loopback matching. `Beamlet.OAuth.Codes`. `Beamlet.OAuth.AuthorizeController` `:new` and `:create` with the consent page and the error page, behind the login. `Beamlet.OAuth.TokenController` `:create` with both grants and the OAuth error bodies. `Beamlet.Users.authenticate_refresh/1` and `rotate_token/2`, rotation in place. The `iss` parameter. `beamlet tokens` with an `EXPIRES` column. The server reading `BEAMLET_URL` in every environment. Tests driving the whole flow through `Phoenix.ConnTest` with `Req.Test` standing in for the client document and a test resolver in place of DNS.

**Settled at the planning pass:**

- Lifetimes: an access token lives a day, a refresh token thirty days, sliding, so a client in regular use never asks the person to consent again. Constants on `Beamlet.OAuth`, not config; revocation is delete, so a short access token would buy little.
- Scopes: none advertised, none understood. A one-scope or per-tool scheme was weighed and lost: a scope that cannot be declined is decorative, and per-tool scopes put a second permission axis beside the policy. `scope` is accepted and ignored at authorize and echoed in the token reply when sent, which under RFC 6749 states what omitting it already implies, out loud for clients that read the field.
- Login before the client fetch, so only a signed-in person can make the beamlet issue an outbound request; the stored return path carries the query string.
- The SSRF guard is `req_ssrf`, over hand-rolled code and over `safeurl`, which is IPv4-only, checks one address and passes a failed lookup. Attached with https only and no address literals, plus no redirects, a five-second timeout and a 64KB body cap of the beamlet's own. The DNS rebinding window is accepted, as the library documents: pinning the connection to the checked address costs a Finch instance per hostname.
- `resource` is optional and must equal the MCP URL byte for byte when present: a beamlet token is only ever for this beamlet, so requiring it would buy nothing and risk a client that omits it.
- The consent page is provisional: the client's host in the heading, the client id URL in small text, no `client_name`, the declared policies as radios with `default` selected and each policy's tools on its line, a warning for a loopback redirect, Allow and Deny, and the signed-in name with a sign-out. To be polished after the first connections.
- A token whose refresh has expired stays as a row until the operator deletes it; the listing shows the expiry.
- The test seam is a module-keyed config entry, `config :beamlet, Beamlet.OAuth.Clients, req_options: [...]`, empty in production, carrying the `Req.Test` plug and the resolver in test. A `Beamlet.Config` key lost on putting a test seam on the operator surface.
- No CORS until a client proves it needs it; the inspector, being browser-based, may. Dynamic registration likewise: added the day verification proves a client needs it.

**Verified 2026-09-22**, locally over a Tailscale funnel, defaults left alone in every client:

- **ChatGPT**: exposes a page of advanced OAuth settings, none needed. Connects and signs in smoothly; prompts that read the beamlet and call tools work.
- **Claude** (set up from the desktop app): offers "use Claude's published identity" (CIMD, the default), "register automatically" (dynamic registration) and a client of one's own. The default works. The flow bounces through a claude.ai page before the beamlet's consent and back to the app: more steps than the others, but it lands.
- **Raycast**: offers "dynamic" or "static" OAuth; the default works with no registration endpoint, so it reaches for the metadata document. Smooth, except that approving opens the Mac app by a custom-scheme redirect and leaves the browser tab sitting on the consent page with its buttons still showing.
- **MCP Inspector**: detects the OAuth challenge but offers no way to run the flow itself, only pre-configured credentials. So it neither needed CORS nor proved it does; the question stays closed until a browser-based client turns up.

No client asked for dynamic registration and none tripped on the scope echo. The one thing verification surfaced is the Raycast tab: a consent that redirects to a custom scheme needs a page that says the person is being sent back to the app, rather than the form left standing. Open for phase 4, where the per-client copy is written.

### Phase 4 — The home page

Roadmap step 5, after step 4 bounded the policies a user may choose. Landed 2026-09-22; the settled items are in `design.md` § 2 under "Web" as "The beamlet's own pages are styled by a built stylesheet" and "The home page", and in "The authorization server" for the consent changes.

**Scope as landed.** `HomeLive` at `/beamlet` as the setup page: the MCP URL, then apps, coding agents and code, each with the clients named and the commands or config to paste. The asset pipeline for the beamlet's own pages: the `tailwind` hex package, `assets/css/beamlet.css`, the committed `priv/static/beamlet.css` served by `Beamlet.Assets`, `mix assets.build` in `precommit`, and a watcher in the server's dev config. `Beamlet.Web.Layouts` with `root` for agent pages, `beamlet` for the beamlet's own and `app` for the signed-in ones. The consent page's copy reviewed and its footer moved to the app layout; a custom-scheme redirect renders a page that sends the browser on. Tests through `Plug.Test`, `Phoenix.ConnTest` and LiveView tests, asserting the presence of each section and snippet and never the wording.

**Settled at the planning pass:**

- Tailwind for the beamlet's pages, the CDN for agents'. The dependency dev and test only, never runtime; the built file committed, as `phoenix_live_dashboard` ships its stylesheet, so the hex package, a git dependency and the image need no build step; `precommit` refreshes it so it cannot drift. The server's watcher runs the library's task in the library directory, so one config owns the build. Building in the Dockerfile and at publish lost on breaking git dependencies and adding a network step to the image.
- No JavaScript pipeline. An `app.js` entrypoint with esbuild was weighed and put off: without colocated hooks it would carry nothing the raw modules do not, and colocated pieces compile into whichever project's `_build` compiles the module, the server's for a path dependency, which a watcher in the library directory would not see. The question returns with the first hook, likely at the admin pages.
- Three layouts in one module, the browser pipeline putting the `beamlet` root on every beamlet-owned route, the login page included, and the generated router keeping `root`.
- The page lists and does not mint. Self-service tokens and the token list wait for 0.5; the page shows the operator's command with the signed-in name filled in.
- OAuth where a client offers it, the header everywhere else. Codex joins Claude Code on the OAuth path, since it signs in with `codex mcp login`.
- No plan or pricing claims on the page. Menu paths and form fields as of writing, nothing more.
- A custom-scheme consent gets a page with a meta refresh and a link, so the no-JavaScript decision holds there too; http and https keep the 302.
- `mcp-remote` is off the page until someone cannot connect without it.
- Snippets checked against current docs at the planning pass, not written from memory: Claude Code's `--transport http` and `${VAR}` expansion in `.mcp.json`, Codex's `codex mcp add --url` and `codex mcp login`, Cursor's `headers` with `${env:VAR}`, the Claude API's `mcp-client-2025-11-20` beta with `mcp_servers` and an `mcp_toolset`, and the OpenAI Responses `mcp` tool with `authorization`.

**To verify by hand** over the funnel, as phase 3 was: Claude Code's OAuth, which phase 3 never ran; Claude and ChatGPT once more against the written steps; Raycast for the sending-back page.
