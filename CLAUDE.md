# CLAUDE.md

Guidance for Claude Code working in `beamlet`. Design decisions live in `context/design.md`; this file covers what the project is, how it is laid out, and the conventions to follow.

## What this project is

Beamlet is a programmable Elixir code server for AI agents. Agents define modules, execute code, and build APIs and live dashboards inside a running application, over MCP. It ships as an embeddable Elixir package and as a standalone server. A running instance is *a beamlet*; the agent works *on your beamlet*, it is not the beamlet. Beamlet is not an Omni package and does not depend on Omni. It is a port of the code-mode work in `../omni_host`, rebuilt step by step with its own view of the world; that code is the reference for what is being ported, not the specification for it.

## Layout

```
lib/host/            Host.*          the stdlib agent code calls
lib/beamlet/         Beamlet.*       everything else: tools, policy, code
                                     server, databases, owner and tokens,
                                     web pieces
lib/beamlet/mcp/     Beamlet.MCP.*   the Anubis MCP server and tool components
lib/mix/tasks/       mix beamlet     the dev entry to `Beamlet.CLI`
server/              beamlet_server  separate mix project: the standalone
                                     Phoenix app, path dep on `..`
data/                dev data dir (gitignored)
context/             design notes
guides/              the hexdocs extras: the operator's guides,
                     with their images under assets/
Dockerfile           builds and runs the server; context is the repo root
.github/workflows/   ci.yml on main and PRs, release.yml on a
                     version tag
```

Two audiences, two surfaces: `Host.*` is what agent code reads and calls; `Beamlet.*` is what the operator and the embedding host use. Keep them apart.

## Build & test commands

```bash
mix compile
mix test
mix test path/to/test.exs        # one file
mix test path/to/test.exs:42     # one test
mix format
mix format --check-formatted
mix precommit                    # compile --warnings-as-errors, unused
                                 # deps check, format, test; run before
                                 # claiming done
cd server && mix precommit       # the same for the server, with its
                                 # own tests
```

Run the affected tests while working and `mix precommit` before claiming done, and the server's too when a change reaches `server/` or what it serves.

## Rules

- **The library is a child spec, not an application.** A host starts `Beamlet` in its own supervision tree with options. No `mod:` in the package.
- **`server/` contains nothing a second embedder would want.** Endpoint, application module, config, release, Dockerfile. If something is tempting to put there, it belongs in the library.
- **Two databases, both Beamlet's.** The agent database (`Host.Repo`) holds what agent code reads and writes as data: its own tables and `__kv`. The beamlet's database (`Beamlet.Repo`) holds what Beamlet acts on: the owner, their sessions, the tokens and the route table. A durable record Beamlet reads back goes in the beamlet's database or the code dir, never the agent database, whoever creates it. What agents built wipes as a unit: the route rows, the agent database, the code dir and the files dir.
- **Principal and authentication are separate.** The principal (token and policy) is what everything keys on and is built per request, never stored. Turning a token into a principal is edge work at `Beamlet.MCP.Plug`; only Beamlet's own tokens are valid. Policy attaches to the token. Provenance is one struct with two encodings: JSON on a route row, git trailers on a commit.
- **Plain Phoenix and Ecto.** Agents author vanilla Phoenix at runtime, so no DSL layer in the way. Canonical Ecto: a root-level context, plural, owns a resource and its sub-resources and is the only `Repo` caller for their tables; the schemas with their changesets sit beside it at the root, singular (`Beamlet.Tokens` owns `Beamlet.Token`). Plain `create`, `update`, `delete`, `list`, `find` and `find_by` take conventional arguments; a function that takes the parent resource is named for the sub-resource.
- **No features beyond the task.** No speculative abstractions, no "while I'm in here" refactors.
- **No migration paths for dev data, pre-release.** Wipe it.
- **Never commit unless explicitly asked to.** Finish the work, run the checks, stop.

## Conventions

- Terminology: **Beamlet** is the project, **a beamlet** is a running instance, **my beamlet** is where your code lives. Every other noun stays ordinary: modules, routes, tools, applications, users, tokens. A beamlet belongs to one person, **the owner**, its only user. **Tool use**, not "tool call".
- Spelling: British on what a person meets first: the README, the guides, the public moduledocs, the app's pages and the CLI's output. What the model reads (the `Host.*` docs, tool descriptions and instructions, teaching errors) takes either. Identifiers and OAuth terms keep the specs' spelling: `authorize/2`, an authorization server.
- **Three words name the sides.** *Beamlet* is the whole and its own things: the project, an instance, the `/beamlet` URL prefix, the `Beamlet.*` namespace, `beamlet.db`. *App* is its web surface, the sign-in, the consent page, the home page and the admin pages to come: `/beamlet/app/live`, the `app` layout, `app.css`, the `_beamlet_app_key` cookie. *Agent* is what agents build and what serves it: `agent.db`, the `agent` layout, `/beamlet/agent/live`, agent pages and routes. A new piece takes its side's name and its own plumbing; nothing of the app's is shared with agent pages.
- Path naming: `*_dir` for directories, `*_file` for files, `*_path` for generic or URL paths.
- Public functions return `{:ok, result} | {:error, reason}`. Match existing error shapes.
- Errors that agents see are **teaching errors**: they say what went wrong and what to do instead, in the agent's vocabulary.
- Migrations via `mix ecto.gen.migration name_in_snake_case`.
- No emojis in code, docs, or commit messages.
- Markdown files soft-wrap: one line per paragraph or list item, the editor wraps columns. Doc blocks in `.ex` files hard-wrap as the Elixir convention has it.
- No comments unless they explain a non-obvious *why*. Never reference the current task in a comment.
- Commit messages: imperative mood, ~50-char subject, terse body when needed, signed `AI-assisted commit (Claude)`.

## Documentation

- A module is public when an operator or embedder meets its name: in config, a command, an endpoint or router line, or a boot error. Everything else is hidden with `@moduledoc false`, never ex_doc's `filter_modules`. This matters more here than usual: `@moduledoc false` is also how policy tells library internals from public surface, and module docs are what agents read to discover the environment.
- A public module has a `@moduledoc`, its public functions `@doc` and `@spec`, its public types a `@typedoc`. Rely on the spec for types, do not repeat them in prose. Plumbing on a public module takes `@doc false`; an `@impl` callback needs a `@doc` only when the inherited one is worth overriding.
- A hidden module has `@moduledoc false` followed by a comment block carrying the context a developer or agent working on it needs, as `Beamlet.Code.Audit` does. Its public functions still have a `@doc`. A private function needs none; one that wants it gets a comment.
- The first paragraph of a `@moduledoc`, `@doc` or `@typedoc` is one short sentence: ex_doc's listings render it, and on `Host.*` so do `print_modules` and the function index. The explanation starts in the second paragraph. A convention about one module lives in that module's moduledoc, not in the server instructions.
- Tone: friendly, curious, technically fluent. Concrete, example-led, no AI hype.

## Testing

- The test suite is the signal that something works, not a connected client. Drive the MCP plug with `Plug.Test`; assert on tool results, teaching errors, and what appears in the data dir.
- No test hits the network or a real model. Stub HTTP with `Req.Test`.
- No test depends on what ran before it. `start_supervised!/1` for every process. A test that needs no beamlet uses `ExUnit.Case, async: true`. `use Beamlet.Case` starts a beamlet per test against the per-run data dir from `config/test.exs`, its code dir copied from the run's first boot; `use Beamlet.Case, shared: true` starts one per module, for tests that change only rows, which the sandbox isolates, and never define code, which the case checks. One beamlet runs per VM, so `Beamlet.Case` modules are never async. A test needing its own directory passes it to the component, not through config.
- No `Process.sleep/1` for synchronisation: `assert_receive` on the event, `Process.monitor` for termination, `:sys.get_state/1` to flush a mailbox.
- Test through public surfaces and assert on results, not on server state.
- The server's tests in `server/test` cover only what the library's suite cannot reach: the real endpoint and router, its config and `runtime.exs`.

## Working on this project

- **The design grows with the code.** `context/design.md` is short on purpose and records only what is settled. When a decision lands or changes in code, update it in the same piece of work. Do not carry principles over from `../omni_host` unexamined; each one earns its place when the code that needs it arrives.
- **Each step gets a planning pass** that pins the spec before implementation.

## Where to look

- **Design** — `context/design.md`: framing, settled decisions, what is deliberately open.
- **Security** — `context/security.md`: the stance, what is trusted, the escape classes left open on purpose, the rule for deciding what to fix, and the accepted risks. Read it before a change that adds an input Beamlet reads back, touches the token edge or the app, widens a grant, or makes an outbound request, and update it in the same piece of work.
- **Roadmap** — `context/roadmap.md`: what each version ships and the steps inside it. `../omni_host/context/beamlet.md` holds the shaping note behind the port: the shape discussion, the seam crossed, and the context carried from the spike.
- **Reference implementation** — `../omni_host/lib/omni_host/code`, `../omni_host/lib/host`, `../omni_host/lib/omni_host/mcp`, with `../omni_host/context/code-mode.md` as its design record and `../omni_host/context/mcp-spike.md` for what MCP clients actually do with instructions, descriptions and errors.
