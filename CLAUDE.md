# CLAUDE.md

Guidance for Claude Code working in `beamlet`. Design decisions live
in `context/design.md`; this file covers what the project is, how it
is laid out, and the conventions to follow.

## What this project is

Beamlet is a programmable Elixir code server for AI agents. Agents
define modules, execute code, and build APIs and live dashboards
inside a running application, over MCP. It ships as an embeddable
Elixir package and as a standalone server. A running instance is *a
beamlet*; the agent works *on your beamlet*, it is not the beamlet.
Beamlet is not an Omni package and does not depend on Omni. It is a
port of the code-mode work in `../omni_host`, rebuilt step by step
with its own view of the world; that code is the reference for what
is being ported, not the specification for it.

## Layout

```
lib/host/            Host.*          the stdlib agent code calls
lib/beamlet/         Beamlet.*       everything else: tools, policy, code
                                     server, databases, users, web pieces
lib/beamlet/mcp/     Beamlet.MCP.*   the Anubis MCP server and tool components
lib/mix/tasks/       mix beamlet     the dev entry to `Beamlet.CLI`
server/              beamlet_server  separate mix project: the standalone
                                     Phoenix app, path dep on `..`
data/                dev data dir (gitignored)
context/             design notes
```

Two audiences, two surfaces: `Host.*` is what agent code reads and
calls; `Beamlet.*` is what the operator and the embedding host use.
Keep them apart.

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
```

Run the affected tests while working and `mix precommit` before
claiming done.

## Rules

- **The library is a child spec, not an application.** A host starts
  `Beamlet` in its own supervision tree with options. No `mod:` in
  the package.
- **`server/` contains nothing a second embedder would want.**
  Endpoint, application module, config, release, Dockerfile. If
  something is tempting to put there, it belongs in the library.
- **Two databases, both Beamlet's.** The agent database (`Host.Repo`)
  for what agents build, including the route table; the system
  database for users and tokens. Agent-built work wipes and backs up
  as a unit.
- **Principal and authentication are separate.** The principal
  (user, token, policy, client) is what everything keys on and is
  built per request, never stored. Turning a token into a principal
  is edge work at `Beamlet.MCP.Plug`; only Beamlet's own tokens are
  valid. Policy attaches to the token. Provenance is one struct with
  two encodings: JSON on a route row, git trailers on a commit.
- **Plain Phoenix and Ecto.** Agents author vanilla Phoenix at
  runtime, so no DSL layer in the way. Canonical Ecto: a root-level
  context, plural, owns a resource and its sub-resources and is the
  only `Repo` caller for their tables; the schemas with their
  changesets sit beside it at the root, singular (`Beamlet.Users`
  owns `Beamlet.User` and `Beamlet.Token`). Plain `create`, `update`,
  `delete`, `list`, `find` and `find_by` take conventional
  arguments; a function that takes the parent resource is named
  for the sub-resource (`create_token(user, attrs)`).
- **No features beyond the task.** No speculative abstractions, no
  "while I'm in here" refactors.
- **No migration paths for dev data, pre-release.** Wipe it.
- **Never commit unless explicitly asked to.** Finish the work, run
  the checks, stop.

## Conventions

- Terminology: **Beamlet** is the project, **a beamlet** is a
  running instance, **my beamlet** is where your code lives. Every
  other noun stays ordinary: modules, routes, tools, applications,
  users, tokens. **Tool use**, not "tool call".
- Path naming: `*_dir` for directories, `*_file` for files, `*_path`
  for generic or URL paths.
- Public functions return `{:ok, result} | {:error, reason}`. Match
  existing error shapes.
- Errors that agents see are **teaching errors**: they say what went
  wrong and what to do instead, in the agent's vocabulary.
- Migrations via `mix ecto.gen.migration name_in_snake_case`.
- No emojis in code, docs, or commit messages.
- No comments unless they explain a non-obvious *why*. Never
  reference the current task in a comment.
- Commit messages: imperative mood, ~50-char subject, terse body
  when needed, signed `AI-assisted commit (Claude)`.

## Documentation

- Public modules have a `@moduledoc`; internal ones `@moduledoc false`.
  This matters more here than usual: `@moduledoc false` is also how
  policy tells library internals from public surface, and module
  docs are what agents read to discover the environment.
- Public functions have `@doc` and `@spec`; public types a
  `@typedoc`. Rely on the spec for types, do not repeat them in prose.
- Tone: friendly, curious, technically fluent. Concrete, example-led,
  no AI hype.

## Testing

- The test suite is the signal that something works, not a connected
  client. Drive the MCP plug with `Plug.Test`; assert on tool
  results, teaching errors, and what appears in the data dir.
- No test hits the network or a real model. Stub HTTP with `Req.Test`.
- `start_supervised!/1` for every process; `use Beamlet.Case` starts
  a beamlet per test against the per-run data dir from
  `config/test.exs`. A test needing its own directory passes it to
  the component, not through config.
- No `Process.sleep/1` for synchronisation: `assert_receive` on the
  event, `Process.monitor` for termination, `:sys.get_state/1` to
  flush a mailbox.
- Test through public surfaces and assert on results, not on server
  state.

## Working on this project

- **The design grows with the code.** `context/design.md` is short on
  purpose and records only what is settled. When a decision lands or
  changes in code, update it in the same piece of work. Do not carry
  principles over from `../omni_host` unexamined; each one earns its
  place when the code that needs it arrives.
- **Each step gets a planning pass** that pins the spec before
  implementation.

## Where to look

- **Design** — `context/design.md`: framing, settled decisions,
  what is deliberately open.
- **Roadmap** — `context/roadmap.md`: the steps of the port and
  where it stands. `../omni_host/context/beamlet.md` holds the
  longer note behind it: the shape discussion, the seam being
  crossed, and the context carried from the spike.
- **Reference implementation** — `../omni_host/lib/omni_host/code`,
  `../omni_host/lib/host`, `../omni_host/lib/omni_host/mcp`, with
  `../omni_host/context/code-mode.md` as its design record and
  `../omni_host/context/mcp-spike.md` for what MCP clients actually
  do with instructions, descriptions and errors.
