# Beamlet — roadmap

Work tracking for Beamlet: the next release, the backlog, what to watch and loose ideas. A live document — add to it freely, clean it up as items land or get rethought.

---

## Next — 0.2.0

- TBD

## Backlog

Grouped by area.

### Agent runtime

- **Supervised processes.** Long-running processes for agent code, and async tasks inside an eval: a beamlet-owned supervisor agents register children into, a durable record of what should be running in the beamlet's database, restart at boot, teardown verbs, a `Host.*` face. Not a policy row: a bare `allow Task` yields processes that die with the eval or leak. The process-primitive closure in the signage becomes a redirect. Shape from the omni_host M15 note.
- **Agent-installed dependencies.** Hex packages at runtime: the agent proposes, the owner approves, the beamlet installs, the policy grants. A durable manifest with git-audit treatment, applied at boot before the code dir compiles; `Mix.install` is once per VM, so a change means a restart. Reopens the trusted-owner posture (`security.md` § 7) and brings a package-level grant (`allow_app`, declined at step 9 of the port).
- **Static assets.** Agent-served files and agent-installed JavaScript and CSS, colocated in agent modules as the likely shape; `Beamlet.Assets` is where served files grow. Open: where npm packages live and who runs the install; colocated CSS needs `root_tag_attribute` set in the VM that compiles the module, so the library sets it or requires it of every host; both extract to files under `_build` for a bundler, which the no-bundler substrate would serve itself.
- **Protocols** (2026-09-30). `defprotocol`, `defimpl` and `@derive` in agent code, all refused today. An agent's own protocol is the easy half; implementing a library one fights build-time consolidation, with two routes open. Demand today is `@derive Jason.Encoder`, which building a map covers. M to L. See `notes/protocols.md`.

### Authoring loop

- **Drafts for failed defines** (2026-09-27). A define that fails to compile leaves nothing behind, so the fix is a whole re-emission. The narrow shape: a failed new define is kept quarantined, listed with its error, readable, patchable and removable; a failed replace stays discarded, since patching the live module is the right move. Open: quieter copy than the operator's quarantine warning, whether git records the attempt, staging for a multi-module call, a draft having no author. It earns its place on how often models re-emit after a compile error; first evidence 2026-10-06, a model aiming a `patch` at a module whose define had just failed.
- **A hint on refused Erlang functions.** `:erlang.float_to_binary`, refused while formatting a temperature, says only that it is not permitted, since signage has no `:erlang` entry. Erlang is gap-filling in the default policy, so a hint naming the Elixir module that covers the ground teaches the recovery.

### App

- **Admin pages.** LiveViews under `/beamlet` behind the login: files with drag-and-drop upload, routes, read-only module source, and the token list with self-service tokens. Sensitive actions ask for the password again.
- **Uploads to agent routes.** The server has no multipart parser (2026-10-03), since `Plug.Parsers` writes uploads to the system temp dir, where agent code cannot read them. Needs the parser back in the endpoint list and a `Host.*` function moving an upload into the files dir. Goes with the files page.
- **Consent hardening** (2026-10-01). Script on an agent page can drive the consent page as the signed-in owner (`security.md` § 6). The fix chosen: Allow asks for the password every time, signed in or not, and client ids on the beamlet's own host are refused. A separate origin for agent pages is the complete fix, needed if pages are ever shared publicly.
- **Private routes.** Routes only the owner can reach: `private: true` on the mount, never the path or the controller, the generated router putting the row in a scope that requires the owner. Access keys on the web identity, never the principal. The app's cookie stays scoped to `/beamlet`, so this needs a second, weaker cookie on agent paths that admits the owner to private routes and to nothing of the app's.
- **Disconnect app pages on a new password** (2026-10-01). A new password from `beamlet setup` deletes every session but cannot disconnect open app pages, since the CLI has no way to the server's PubSub; an open page looks signed in until its next reload, and its events still run. Rare. Closed by the CLI reaching the server over distribution, or app pages checking their session before an event or on a timer.
- **A favicon**, with the brand. There is no `<link rel="icon">`, and `/favicon.ico` answers 404.
- **A welcome at `/`** for a fresh beamlet, pointing the owner at `/beamlet` in place of the plain 404.

### Platform

- **The modern-era MCP protocol** (2026-07-28). Anubis 2.0 is legacy-era and current clients negotiate it. Waits on Anubis.
- **`BEAMLET_URL` from the platform** (2026-10-05). When it is unset, `runtime.exs` falls back to an address from a variable the platform sets, `https://$FLY_APP_NAME.fly.dev` on Fly and the like elsewhere, `BEAMLET_URL` always winning. The Fly guide loses its `fly secrets set` step.
- **A session plug for embedders.** At the head of the app's pipeline, raising when the session is already fetched, enforcing design § Web's precondition. Once embedding is settled.

### Hardening

Security minors from the review (2026-10-01):

- The PKCE `code_verifier` is not checked for length and charset (RFC 7636: 43 to 128 unreserved characters).
- Refresh reuse goes unflagged: a thief who redeems first keeps the token. Detection needs previous refresh hashes kept.
- Anubis session state holds `req_headers`, so a session crash report could log the bearer. Unconfirmed.
- The server's `Plug.RewriteOn` trusts `x-forwarded-proto` from any client when no proxy sits in front.

Code server and stdlib:

- **Orphaned compile workers** (2026-10-03). When a define's compile task dies, its workers run on, leaking a process and a loaded module, or deleting a replaced module from the VM until the next boot. Nothing in normal use triggers it. See `notes/orphaned-compile-workers.md`.
- A failure past the commit point in `Beamlet.Code.commit/2`, such as `File.rename!` on a full disk, leaves some files moved, so the restart boots a partial define. Unreproduced.
- `Host.Migrator.migrate/0` prints "Applied" when `Ecto.Migrator.up/4` answers `:already_up`, as two concurrent migrations would. Unreproduced.
- `Host.Router.unmount/2` deletes the rows before regenerating, so a failed regeneration leaves the routes served while the error says they were unmounted. Untested until the behaviour is decided. Unreproduced.
- A `schema_migrations` row with an unparseable `inserted_at`, which raw SQL can write, makes `print_migrations/0` and `migrate/0` raise Ecto's raw `ArgumentError`. Fix: read it as text and show what cannot parse.
- `Beamlet.Eval.run/3` raises a `MatchError` for an undeclared policy: unreachable through the plug, reachable by an in-process caller.
- `Beamlet.OAuth.Clients.start_link/1` accepts `name:` but `fetch/1` ignores it, and the cache is never swept. Owner-only input.

## Watch

Signals, each with what would make it an item.

- At prompt 10 of the walkthrough, GPT 6 Luna passed the outbound guard's refusal on without its `Host.Router.call/4` pointer. If another model drops it, the pointer leads the message.
- A model cleared `schema_migrations` in raw SQL after the migration bug and the rollback hint, both since fixed, misled it. If it recurs, the copy warns against it.
- On Raycast, a LiveView was twice styled with a `<style>` block filled by `{stylesheet()}`, which HEEx does not interpolate. If it recurs, `Host.Web` says so.
- Not reached by the walkthrough, so first met in real use: on Docker, a hand-edit quarantine and the agent's recovery, `tokens.delete` cutting a connected client off, a restart and `beamlet reset`; any model but GPT 6 Luna on the later prompts, the guardrails and a restricted token; `fly deploy` with the `0.1` tag picking up a patch. What breaks becomes a 0.1.x fix.

## Ideas

One line each, with the release it was noted in.

- Virtual paths on `Host.File`: `~docs/` serving documentation for agents as read-only files, when a topic has no owning module or a `Host` moduledoc outgrows about 4KB. (0.1)
- Atoms in KV values, as a tagged map emitted only when a key is not a string, decoded to existing atoms only. (0.1)
- Package-level denial in a policy (`deny_app`), and reloading policies without a restart. (0.1)
- A `capabilities:` key in a policy naming `eval` and `code`, in place of `tools:` with `define` granting two tools. (0.1)
- Code ownership: refusing a patch on lines the patcher never wrote. (0.1)
- A hosted or external OAuth issuer in place of Beamlet's own. (0.1)
- A principal handed in by an embedding host calling tools in-process, without a token; a principal that encodes and decodes is the seam. (0.1)
- Omni as a dependency, as a library for agents to use. (0.1)
