# Beamlet — patch

**Status:** The spec for editing modules in place, agreed 2026-09-26 and sequenced 2026-09-27 into the five phases of § 9, which is the plan. Each phase is a session of its own that starts from this note: a planning pass pinning the phase against the code as it stands, the implementation, the tests, `mix precommit`, and an update to this note. Phase 1 landed 2026-09-27; phase 2 is next. The work is next up on the roadmap, ahead of the 0.1 code review, so the reviews and the docs cover three tools. When the last phase lands, the settled parts move into `design.md` and this note goes.

**Last updated:** 2026-09-27 (phase 1 landed: scattered clauses refused at define and boot, the locator convention started)

---

## 1. The problem

Today an agent changes a module by printing its source with `Host.Code.print_source/1` and defining the whole module again with `replace: true`. Three costs and one wall:

- **Tokens.** A one-function change to a 200-line module costs a 200-line print and a 200-line re-emission, and output tokens are the slow, expensive kind.
- **Drift.** Re-emission is where a model tidies a docstring, drops a clause or reorders things. Git records every version, so the operator can recover, but nobody is looking at the moment it happens and the agent cannot look at all.
- **Lost updates.** Two writers to one module where the second read it before the first wrote: the first change is gone silently. Two agents, one agent's parallel tool calls, or a hand edit.
- **The wall.** Eval's output cap is 16KB, so a module past about 450 lines cannot be printed whole and therefore cannot be replaced safely at all. Agents cannot capture the print to slice it, since the process primitives are closed.

No measurements from beamlet sessions yet. The prior is that every coding agent moved from whole-file writes to anchored edits for these reasons. The 0.1 walkthroughs (roadmap step 16) are the chance to measure: `git log -p` in the code dir after a session shows every hunk the transcript did not ask for.

## 2. The shape

Four pieces sharing one parser module, and one guard:

- **Read in pieces.** `Host.Code.print_outline/1` prints a module's structure with line ranges. `print_source/2` and `print_source/3` print one function, every arity or one, and `print_source/2` with a range prints lines. The outline's range for a function is exactly what a patch's `select` touches.
- **Store formatted.** Agent source is stored as the formatter lays it out (§ 5). A patched file is byte-identical outside the patched region, `find` always quotes canonical text, and the tool needs no indentation or spacing rules.
- **Write in pieces.** A third tool, `patch` (§ 3): a list of `{module, anchor, operation}` applied in order as one transaction through the define pipeline. `find` anchors text; `select` anchors a function by `name/arity`; the operation is `replace`, `before` or `after`.
- **See what changed.** The summary of every replace and every patch names the functions added, changed and dropped, with clause counts, so a lost function is in the tool result at the moment it is lost.
- **Guard the stale read.** A patch carries a hash of the source it read, and the code server refuses to write over a module that changed in between (§ 7).

Two small rules land with it: scattered clauses of one function are refused at define and patch (§ 5), and every pipeline error locates by the text of the line rather than by a number (§ 6).

**Why a tool and not a form in define.** A `defpatch Mod, drop: [...], after: [...] do ... end` form inside the define buffer was designed first and set aside (§ 8). The buffer-is-the-transaction argument holds for both: every write compiles, so an edit must be a set of changes that compiles together, and a list of patches is such a set. What decided it: a form that exists nowhere in Elixir must be learned from the description, and every open question in its design was about its mini-language; its function-level floor fails on exactly the headline case, a `render/1` too long to print whole; and find-and-replace is the most practised tool shape these models have. The third tool costs a description of about 750 bytes in every session, a policy entry and a listing row, all bounded.

## 3. The `patch` tool

### Schema

```elixir
schema do
  embeds_many :patches, required: true do
    field :module, {:required, :string}   # "Shopping.List"
    field :find, :string                   # text occurring exactly once
    field :select, :string                 # a function, "total/1"
    field :replace, :string                # empty removes
    field :before, :string
    field :after, :string
  end
end
```

Each patch is a module, exactly one anchor and exactly one operation. The keys present are the type; a `type` field would restate them. There are no anchorless patches: rewriting a module whole is `define` with `replace: true`, and appending is `select` on the last function of the right visibility with `after`, which places deliberately where an append would not and sends the agent through the outline, where a duplicate name would show. If append is missed in practice, the addition is an explicit `append` key, never an anchorless `after`, whose meaning (append, or after the module?) is ambiguous on sight.

**The one-anchor, one-operation rule reaches the client as prose** (2026-09-27). The flat schema above, six optional strings, each field's description stating its half of the rule and the tool description stating it whole. Flat validation keeps every present key, so a patch carrying both anchors reaches `execute` and is refused there with a teaching error, which is the only place the rule can be enforced under any schema. The JSON Schema says less than the truth, and that is the starting position because it costs nothing and couples to nothing; whether a precise schema guides models better than a sentence is not answerable before there are sessions to watch, and the 0.1 walkthroughs are where to look.

The alternative, kept for that revisit: a hand-written JSON Schema saying exactly the rule, the six properties, `module` required, `additionalProperties: false`, and two `oneOf` groups under `allOf` for the anchor and the operation. Not reachable through the DSL: `use Anubis.Server.Component` generates `input_schema/0` from the `schema do` block with no override, and Peri's own `{:oneof, [...]}` renders as `oneOf` but validates as first match and strips the keys outside the matched branch, so a double anchor would pass with one silently dropped. It is reachable by writing the component as a plain module implementing `Anubis.Server.Component.Tool`, supplying by hand the two generated functions the server reads, `__mcp_component_type__/0` and `__mcp_raw_schema__/0` with a flat Peri schema for validation, and `input_schema/0` with the JSON Schema; registration, the advertised `allOf` and flat validation all work (checked against the installed Anubis 2.0). The costs: coupling to two `@doc false` names an Anubis upgrade could rename (a one-line upstream change making `input_schema/0` overridable would remove it), a test to pin the two schemas to the same property names, and a schema that is strictly true but complex, which clients translate for their providers unevenly.

### Semantics

- **`find` is a string operation.** The anchor is bytes occurring exactly once in the module's source as it stands. `replace` swaps them; `before` and `after` splice the text immediately before or after, with no separator logic.
- **`select` is a block operation over whole lines.** The anchor is a function as `name/arity`, any visibility, `defmacro`, `defguard` and `defdelegate` included: all its clauses and the function-level forms directly above the first (§ 4). `replace` swaps the block and empty removes it; `before` inserts above the block, which is above its docs; `after` inserts below its last clause. The inserted text is trimmed of leading and trailing blank lines and separated from its neighbours by one, and the formatter tidies the rest.
- **Patches apply in order** to the source as the previous ones left it, and each `select` re-parses the current text. A patch that leaves the module unparseable fails the whole call, naming the patch after which parsing stopped and the parser's message.
- **The touched modules then run the define pipeline as a replace:** scanner, docs gate, format, compile with dependents, broken-caller check, one commit with the subject `patch: Shopping.List, Shopping.Cart` and the principal as trailers. On any error nothing changes. Timeout, cancel and the lane are define's. The scanner and the docs gate run over each module's patched source on its own, so their errors are relative to that module (§ 6); the results then concatenate into one buffer for the compile, so the code server needs no new path.
- **The module must be defined or quarantined.** A quarantined module is patchable, since a one-line fix is the natural recovery; its source may not parse, so `select` fails there and `find` works. A pending migration is patchable; an applied one refuses, as for replace.
- **Changing the `defmodule` line's name is refused.** The pipeline would file a new module and leave the old. Rename by defining the new and removing the old.
- **A patch whose result equals the current source** is a no-op summary, not a refusal, since empty commits are already allowed for a replace with the same source (2026-09-27).

### Errors, all teaching, nothing changed

Every error follows § 6: it names the module, quotes the line, and for a pipeline failure names the patch that caused it.

- No match: the module and the first line of `find`. When the text matches once with leading whitespace ignored, the error says so, since that is the mismatch models make. It also says that source is stored formatted, so text quoted from a `define` buffer in the same session may differ from what is stored, and to quote from `print_source` (§ 5).
- Several matches: the count, and the hint to quote more context.
- Unknown function under `select`: the module's functions listed, as `print_docs` does.
- Both anchors, both operations, or neither: the rule, one anchor and one operation.
- An unknown module: not defined on this beamlet, with `print_modules` named.
- The stale-read refusal, and the removed-module refusal (§ 7).

### Summary

One line per module, then define's dependents and runtime-caller lines as they are:

```
Patched Shopping.List: changed total/1 (1 to 2 clauses); added remove/2; dropped load/1
```

The same diff line goes on `Defined Shopping.List (replaced)`. Clause counts are what make an accidental second clause visible: Elixir accepts it with at most a warning, and the old clause keeps matching. When the previous source does not parse, a quarantined module being replaced, the summary says so in place of the diff.

### Description

About 750 bytes, held under 2,048 by the same test as the others:

```
Patch modules on your beamlet: targeted edits to their source.

Each patch names a module, an anchor and an operation. The anchor is
`find`, text occurring exactly once in the module's current source, or
`select`, a function as `name/arity`: all its clauses and the `@doc`
and `@spec` above them. The operation is `replace`, empty to remove,
or `before` or `after`, code inserted around the anchor. All patches
apply as one transaction, in order: the modules recompile together
with their dependents, and on any error nothing changes. Source is
stored formatted.

Read before you patch: `Host.Code.print_outline(Mod)` for the shape
and the `name/arity` spellings, `print_source(Mod, fun, arity)` or a
line range for exact text to quote. Define's rules hold for the
result: public functions documented, your policy applied, a function
another module still calls not dropped.
```

The server instructions gain one sentence, phrased to survive a token without the tool: `patch`, when it is in your tool list, edits a module's source by find and replace or by function. The `eval` description is unchanged. The `define` refusal for a module that already exists names both doors: patch it, or pass `replace: true` to rewrite it whole.

### Policy and audit

`patch` joins the valid tool names beside `eval` and `define`; `default` grants all three, a custom `tools:` list names what it wants, and the per-request listing filter and the call refusal work unchanged. A token with define and no patch is odd but legal, since the tools list is independent of grants. The audit gains a third commit kind.

**The patcher's policy governs the whole resulting module** (2026-09-27). The scanner runs over the patched source entire, under the patching principal's policy, so a one-line patch by bob to a module alice defined can be refused on a line bob never wrote. This is already what a replace does, it is the safe answer, since no principal ends up with a module doing what their policy denies, and the error quotes the line so the cause is plain. What it points at is that Beamlet has no concept of code ownership; that is a discussion for after 0.1 (design § 4 already defers per-module ownership), and until then this is accepted.

### Shape in code

- `Beamlet.Code.Source`, `@moduledoc false`: pure functions over source text. `outline/1`, `select/2` returning a block's line range, the splice operations, and the diff between two outlines. The code server's `split_sources` moves onto it.
- `Beamlet.Patch`: the runtime, in the shape of `Beamlet.Define`: resolves the modules, reads and hashes their sources, applies the patches, scans and docs-gates each result, and hands the merged buffer on with the hashes.
- `Beamlet.MCP.Patch`: the component, a `use Anubis.Server.Component` with the flat DSL schema, mapping the tuple to a tool result.
- `Host.Code.print_outline/1`, `print_source/2` and `print_source/3` render through `Beamlet.Code.Discovery`, which calls `Source`. `print_source/2` takes an atom, every arity of a function, or a `Range`, `print_source(Mod, 40..80)`; `/3` takes name and arity, as `print_docs` does. No string form (2026-09-27): one way is the house rule.

## 4. Selections

A selection is what the parser sees, `Code.string_to_quoted/2` with `token_metadata: true`; no text heuristics.

- **Its end** is the last line of its last clause. A one-liner has no `end` token, and the parser's `end_of_expression` metadata gives it (verified 2026-09-27 on 1.20.4: `def one, do: :ok` carries `end: nil` and `end_of_expression: [line: n]`).
- **Its start** is found by walking upward from the first clause over the forms that belong to a function: `@doc`, `@spec`, `@impl`, `@deprecated`, and Phoenix's `attr` and `slot`. Anything else stops the walk, so a `@default_limit 10` directly above stays where it is.
- **Comments never attach.** They are not forms. A comment above a removed function stays, visible in the next print and one `find` away; the docs gate steers agent code to `@doc`, so the case is rare.
- **Naming `attr` and `slot` is a curation record** beside the framework module list. The beamlet ships them and imports them through `Host.Web`, an agent's own `attr` needs `allow_defmacro`, and a macro placed directly above a function in that style is by placement an annotation of it. The general rule, any adjacent bare call attaches, lost: it swallows a `plug :auth` written with no blank line above the action. A missed macro from a future library costs the agent a `find` to tidy, and the compile is loud since an orphaned `attr` fails.
- **The outline prints each function's range as its selection**, docs included, so the agent sees what a `select` will touch. The outline lists the header items too, moduledoc, directives, attributes, struct and types, with their lines, since a range read needs them.
- **A module that does not parse has no outline.** `print_outline` on a quarantined module raises with the parser's message and points at `print_source` with a range and at `find`, the two reads and the one anchor that work on unparseable text.
- **A quarantined module with scattered clauses is the one place `select` can meet a non-contiguous block** (phase 1, 2026-09-27). Define and boot refuse scattered clauses (§ 5), so every defined module is contiguous, but a hand-edited scattered file parses and sits in quarantine. `select` on such a function refuses with a teaching error pointing at `find`; the outline still prints, since the ranges are honest about what is there.

Tests for the walk: doc, spec and impl; attr and slot; a constant directly above that must stay; an adjacent comment that must stay; a one-liner; a private function; a multi-clause function with a `@spec` between clauses.

## 5. Formatting and scattered clauses

**Source is stored formatted.** Confirmed 2026-09-27 as a change to define itself, not only a patch feature: every module written from now on is stored as the formatter lays it out, and the code dir stops reading byte-for-byte as authored. The flow in define and patch: scan and docs gate on the agent's text, so the errors agents hit most name their own lines; then `Code.format_string!/2`, which cannot fail after a successful parse; then compile and persist the formatted text, so stack-trace lines match `print_source`. The description says source is stored formatted and `print_source`'s doc says the same.

The one ambiguity is a same-session patch to a module just defined, where the agent may quote its own unformatted text and miss. The no-match error says so (§ 3), and the patch description sends the agent through the outline and the source before it writes; the habit to teach is to read liberally before patching. Every module is a new module in a new session, so the case is bounded.

Details: the no-parens locals, so `plug :auth` does not become `plug(:auth)`, are read at compile time from the packages' `.formatter.exs` exports into a module attribute, since a release does not carry those files. Phoenix, ecto, ecto_sql and plug ship exports, and phoenix's carries `attr` and `slot`; phoenix_live_view exports nothing (verified 2026-09-27). Without the list the formatter wraps `plug`, `attr` and `slot` in parens; with it they stay bare. The HEEx plugin stays out, so `~H` content is verbatim (verified). The formatter is idempotent, so the only visible change on an existing beamlet is a one-time reformat of an old module at its first patch; an Elixir upgrade that changes the formatter's output does the same, one hunk at the module's next patch, accepted. Pre-release, dev data is wiped as usual.

**Scattered clauses are refused.** Elixir only warns when clauses of one function are separated by other definitions (verified on 1.20.4 with OTP 29: the module compiles and runs), so a `select` could otherwise meet a non-contiguous block. There is no per-warning compiler flag and `warnings_as_errors` is all or nothing. The code server already receives warnings as diagnostics on a successful compile and ignores them: with `return_diagnostics: true` they arrive as `compile_warnings` in the map `Kernel.ParallelCompiler.compile/2` returns, each with `message`, `position` and `file`, and the message begins `clauses with the same name and arity (number of arguments) should be grouped together, "def a/1" was previously defined (file:2)` (verified 2026-09-27). Define and patch filter for the prefix "clauses with the same name and arity" and refuse with a teaching error, rolled back like a compile failure. A test pins the wording so an Elixir release that rewords it fails the suite rather than letting the case back in; CI runs 1.19 and 1.20, so both must agree.

Landed in phase 1 (2026-09-27), with three things settled against the code:

- **Boot refuses too.** A hand-edited scattered file is quarantined at boot with the same error, as a compile failure is, so no defined module on the beamlet has scattered clauses and the define-side check needs no scoping to the buffer's own file: a dependent recompiled alongside cannot carry the warning. Hand edits follow the same rules as the tools.
- **Only the arity variant.** Elixir has a sibling warning, "clauses with the same name should be grouped together", for `a/1`, then `b/0`, then `a/2`. Different arities are different selections, so that layout stays legal, and a test pins the filter as not too broad.
- **The wording**, one line per scattered function, the kind as the compiler names it so a guard reads `defmacro`:

  ```
  def total/1 (buffer:9) is separated from its earlier clause (buffer:4) by other definitions — group the clauses of a function together
  ```

  The parts come from the diagnostic, the function and the earlier line from the message and the later line from its position, and Elixir's own text never reaches the agent, since it carries the staging path. At boot the locators name the file, `lib/shopping/list.ex:9`, per § 6.

**Normalising order was rejected.** Guards and macros must precede their uses in a module, `attr` must sit directly above its component, `plug` calls are an ordered pipeline, and an attribute set between functions is read by the next one at compile time. Each is a special case where a reorder silently rewrites what the agent meant, and it breaks the promise that the code dir reads as authored. Formatting changes neither meaning nor order, and placement by `select` with `before` and `after` buys the same outcome with no rewriting.

## 6. Errors and line numbers

Settled 2026-09-27. A line number is worth something only when it indexes text the agent can read, and in the write pipeline it never does:

| Error | What the number indexes | Readable by the agent |
|---|---|---|
| define, scanner or syntax | the agent's buffer | yes, it wrote it |
| define, compile | the formatted buffer | no, never stored |
| patch, any | the concatenated patched text | no, never stored |
| runtime, stack trace | the stored file | yes, `print_source` |

Today every number is buffer-relative: the whole buffer compiles as one staging file and the split into one file per module happens at commit, so a two-module buffer reports a bare buffer line for either. After formatting, a compile error's number indexes text the agent has not seen; after a patch, text nobody has. Only the stack-trace row is a number worth chasing, and it is the payoff of storing formatted: it matches `print_source`, and the range read makes it actionable. The rest is not worth hoops, and the rule is instead:

- **The text is the locator, the number a hint.** Every pipeline error names the module and quotes the offending line. The scanner has the source and the line; the docs gate already names the function, which is better than a line; compile diagnostics carry a position into the staged text. Attribution in a multi-module buffer comes from the parse: the module ranges the split computes map any buffer line to its module. No offset tables, no change to staging.
- **A number says what it is relative to**, in the error itself, as a locator of the shape `<form>:<line>` where the form names the text the number indexes (settled in phase 1, 2026-09-27): `buffer:42` for what the agent sent, and `lib/shopping/list.ex:9` at boot, the stored file's path relative to the code dir, which `print_source` reads. Phase 2 names the formatted text's form when it introduces it. The shape is the `file:line` models already read, and the ambiguity is gone at the moment it would mislead. Phase 1 uses it for the scattered-clause error; phase 2 applies it to the scanner's `line N:` prefix and to compile errors, which today pass Elixir's diagnostics through verbatim, including a trailing `** (CompileError) <staging path>: cannot compile module ...` diagnostic at position 0 that leaks the staging path and must go.
- **A patch error brings the file to the model.** Since the patched text exists nowhere readable, the error names the patch that caused it and shows the failing line with two or three lines either side: `patch 2 (Shopping.Cart, select total/1): the result fails to compile at ...`, then the context. A handful of lines in a failure result is the cost.
- **Nothing about line numbers is taught in the descriptions.** No error asks the model to count. The habit the patch description already teaches, read the outline and the source and quote exact text, is the whole of it.

Phase 2 introduces the rule with the formatting; phases 4 and 5 inherit it for the patch copy.

## 7. The stale-read guard

The tool reads a module, patches it in memory, and hands the whole new file to the code server. The read is outside the server's lane, and the window to the write includes the scan, the docs gate and the queue behind a compile of up to thirty seconds. A write to the module inside that window would be overwritten from the patch's copy, and the `find` check cannot see it, since it checks only the lines being patched. The writers are two agents, one agent's parallel tool calls, or a hand edit. Define with `replace` has the same problem with no read to guard, since the buffer carries no record of what was printed minutes earlier, and stays last-writer-wins.

The runtime takes a SHA-256 of the bytes it read, per touched module, and passes the hashes with the buffer. The server, inside its lane where nothing else can write, hashes the file on disk and compares. Equal proceeds. Different refuses with "Shopping.List changed while you were patching it, read it again", and nothing changes; the retry is a fresh read and the same patches, which usually succeed since the other writer touched other lines. A module removed in the window has no file to hash, and that counts as changed with its own wording, "Shopping.List was removed while you were patching it", since classify would otherwise file the patch as a new module (2026-09-27). Compare-and-swap, per module, one hash each; two patches to one module in one call share one hash of the state before either applied. A lock lost: it would hold every other agent for the scan-and-queue duration and need releasing on cancel and crash, for a conflict that is rare. Moving the read into the lane lost: the scanner and docs gate need the patched text and would move in with it, changing the split between runtime and server.

## 8. Alternatives considered

Recorded because each would plausibly be proposed again.

- **`defpatch` inside the define buffer**, a partial module whose functions replace their namesakes by name and arity, with `drop:` and a placement key. Elixir-shaped and one tool, but a concept no model brings from training, a mini-language of selectors and placement that grew with every question asked of it, and a function-level floor that cannot touch a function too long to print. Kept in the background if the tool proves too coarse.
- **A single-edit tool.** Every write compiles, so an edit must be a set of changes that compiles together; a change to a function and its callers in one module has no compile-valid intermediate state. The list of patches is what makes the tool a transaction.
- **`merge: true` on define.** A flag with different semantics from `replace: true` beside it, and the two composed confusingly. Intent belongs in the buffer or in the tool, not in a flag.
- **Implicit upsert**, where a `defmodule` of an existing name merges by default. A reader of the buffer cannot tell a whole module from a partial one without the beamlet's state, and the two commonest mistakes become quiet.
- **Metadata as attributes**, `@drop` and `@after` inside `defmodule`. They look like real attributes, must be stripped before compile, and still need something to mark the module as a patch.
- **Explicit drops with additive bodies**, so adding a clause needs no re-emission. A forgotten drop leaves a second `total/1` clause after the first, which Elixir accepts, and the change silently never runs.
- **Clause-level selection**, `handle_info/2:3`. Ordinals are line numbers in disguise: they shift when a clause is added or dropped in the same patch, and models miscount. A clause's only stable identity is its head text, which is a `find` anchor.
- **Anchorless patches**, with no anchor meaning the module body so that `after` appends. Ambiguous on sight, and a blind append is the one path to a duplicate clause that never runs.
- **Attaching adjacent comments** by a blank-line rule. Ambiguous either way; the parser-only rule is the honest one.
- **Depending on probex.** A CLI with no library API, so it cannot be embedded; the two commands wanted, `outline` and `body`, are a hundred-odd lines over the parser the code server already uses. Its lessons carried over: parse, never compile; no silent no-ops; `name/arity` as the selector.
- **`Host.Code.edit/3` from eval.** Two strings inside Elixir inside JSON, where a module's own `"""` docs terminate the heredoc.
- **Accurate line numbers for pipeline errors**, by offset tables or per-module staging. The numbers would index text the agent cannot read either way (§ 6); the text of the line is the locator.

## 9. The plan

Five phases, in order, each a session of its own. A phase starts from this note and CLAUDE.md, with design § 2 Define and Discovery beside them, and runs as every roadmap step does: a planning pass that pins the phase's spec against the code as it stands and asks what is unclear, the implementation, the phase's tests, `mix precommit`, and an update to this note recording what the phase settled or changed. A phase does only what it lists; a later phase never starts before the earlier one has landed; nothing is committed unless asked. Sizes are relative: 1 is small, 2 and 3 medium, 4 large, 5 medium.

### Phase 1. Scattered clauses refused (landed 2026-09-27)

**Goal.** A define whose clauses of one function are separated by other definitions is refused, so a later `select` always meets a contiguous block, and the pattern of treating a compile warning as a refusal exists for phase 4 to reuse.

**Built.** In `Beamlet.Code`, one detector over `compile_warnings` and one renderer, shared by define and boot. The define outcome checks the warnings first, ahead of the broken-caller and placement checks, and a match rolls back exactly as a compile failure with the § 5 wording, `buffer:N` locators. Boot's successful-compile branch runs the same detector and quarantines a matching file through the same path a compile failure takes, with the file's relative path as the locator form; the quarantine tail of the boot loop is one helper both branches call. The planning pass widened the entry from define alone to boot, since a hand edit must follow the same rules, and narrowed the filter to the arity variant.

**Tests.** A scattered buffer refused with nothing defined and nothing on disk, the wording pinned exactly; two scattered functions giving two lines in buffer order; the same name at another arity still defining; a scattered replace rolling the module back, file bytes unchanged; a scattered file quarantined at boot with its error and log line. A contiguous multi-clause function was already covered by the `defguard` test.

**Not in this phase.** Formatting, the summary, anything in `Host.Code`.

**Touched.** `lib/beamlet/code.ex` (`run_define`'s outcome, the boot loop, the moduledoc), `test/beamlet/define_test.exs`, `test/beamlet/code_test.exs`.

### Phase 2. Store formatted, errors locate by text

**Goal.** Agent source is stored as the formatter lays it out (§ 5), and every pipeline error names the module and quotes the line (§ 6).

**Builds.** In the define flow, after the scan and the docs gate, `Code.format_string!/2` with the locals list, then compile and persist the formatted text. The locals list read at compile time from the `.formatter.exs` exports of phoenix, ecto, ecto_sql and plug into a module attribute; the HEEx plugin out. The errors: scanner refusals and syntax errors quote the line and say "of your buffer"; compile errors name the module, from the buffer's module ranges, and quote the line, saying "of the formatted source". `print_source`'s doc and the define description say source is stored formatted; the description's byte count stays under the cap.

**Tests.** A buffer stored formatted; `plug :auth`, `attr` and `slot` kept without parens; a `~H` heredoc untouched; idempotence on a second define of the stored text; a compile error naming the module and quoting the line; a scanner error quoting the line; a two-module buffer whose compile error names the right module; a runtime error's stack-trace line matching `print_source`.

**Not in this phase.** The outline, the diff line, anything about patches.

**Touches.** `lib/beamlet/code.ex`, `lib/beamlet/define.ex`, `lib/beamlet/scanner.ex` (error rendering), `lib/beamlet/code/docs.ex` (the syntax branch), `lib/beamlet/mcp/define.ex`, `lib/host/code.ex`, and the tests beside each.

### Phase 3. The read side and the diff line

**Goal.** A module can be read in pieces, and a replace says what it changed.

**Builds.** `Beamlet.Code.Source`, pure over text: `outline/1`, `select/2` returning a block's line range per § 4, the diff between two outlines with clause counts, and `split_sources` moved onto it from the code server. `Host.Code.print_outline/1`; `print_source/2` taking an atom or a `Range`; `print_source/3` taking name and arity; all rendered through `Beamlet.Code.Discovery`. The diff line on `Defined X (replaced)`, read from the old file at commit; when the old source does not parse, the summary says so instead. `print_outline` and a function print on a module that does not parse raise per § 4. The `Host.Code` moduledoc and the eval description point at the new reads where they point at `print_source` today, within the caps.

**Tests.** The outline's ranges against known sources; the § 4 walk list; the diff line naming added, changed and dropped with clause counts, on a replace and on a replace of a quarantined module; a range print, a function print at each arity, and the not-found copy for each; the unparseable cases.

**Not in this phase.** The splice operations, the hash, the tool.

**Touches.** New `lib/beamlet/code/source.ex` and its test; `lib/beamlet/code/discovery.ex`; `lib/host/code.ex`; `lib/beamlet/code.ex` (the split and the commit summary); `lib/beamlet/mcp/eval.ex` if the description changes.

### Phase 4. The patch runtime

**Goal.** `Beamlet.Patch.run/2` applies a list of patches as one transaction through the define pipeline, guarded by the stale-read hash, with every teaching error of § 3 in the shape of § 6.

**Builds.** The splice operations on `Source`: `find` with the exactly-once check and its three operations; `select` with block replace, removal, `before` and `after` under the blank-line rule. `Beamlet.Patch`, in the shape of `Beamlet.Define`: resolve each module as defined or quarantined; read and SHA-256 each source; apply the patches in order, re-parsing per `select`; refuse a `defmodule` rename; scan and docs-gate each module's result on its own; concatenate; hand the buffer and the hashes to the code server. `Beamlet.Code.define/5` gains the hashes and the patch kind as options: the compare inside the lane, a missing file counting as changed, the `Patched X: ...` summary line and the `patch:` commit subject in `Beamlet.Code.Audit`. A no-op patch is a summary and an empty commit.

**Tests.** At the runtime level, as `define_test` is: each anchor with each operation; order of application; a failing second patch failing the whole call with nothing changed; a quarantined module patched by `find` and refused by `select`; a pending migration patched and an applied one refused; the rename refusal; each teaching error, the formatted-source hint included; a stale read refused and its retry succeeding; a module removed in the window refused; the no-op case; the summary's diff line.

**Not in this phase.** The MCP component, the policy entry, any description or instruction copy.

**Touches.** `lib/beamlet/code/source.ex`; new `lib/beamlet/patch.ex` and its test; `lib/beamlet/code.ex`; `lib/beamlet/code/audit.ex`.

### Phase 5. The patch tool

**Goal.** `patch` is in the tool list of every token whose policy grants it, and the three tools describe each other.

**Builds.** `Beamlet.MCP.Patch` with the flat DSL schema of § 3, each field's description carrying its half of the rule and the tool description carrying it whole, and the one-anchor, one-operation refusal in `execute`. `:patch` in `Beamlet.Policy`'s tool names, type, validation message and rendering, with `default` granting all three. The description under the cap and in the cap test; the instructions sentence; define's exists error naming both doors; the component line and the moduledoc on `Beamlet.MCP.Server`; the policy moduledoc where it lists the tools.

**Tests.** Through the plug, as define's are: the listing shows `patch` under `default` and not under `tools: [:eval]`; a call is refused as unknown for a token without it; a patch end to end with its summary; the both-anchors and neither-anchor errors; the description under the cap; the policy tests for the new name and its refusal message.

**Not in this phase.** Nothing else; this is wiring and copy.

**Touches.** New `lib/beamlet/mcp/patch.ex`; `lib/beamlet/mcp/server.ex`; `lib/beamlet/policy.ex`; `lib/beamlet/mcp/define.ex`; `lib/beamlet/code.ex` (the exists error); the tests beside each.

**After phase 5.** The settled parts of this note move into `design.md` (§ 2 Define, Discovery, Policy and MCP), the roadmap step is marked done, § 11 moves to the roadmap's deferred list, and this note goes.

## 10. Open

- `find` with `before` or `after` is allowed for the uniform rule; nothing is expected to use it.
- A second `select` kind, `@name` for attributes, if a session shows the need.
- `replace_all` for renames within a module, if a session shows the need.
- Whether the precise JSON Schema guides models better than the prose (§ 3), after the walkthroughs.

## 11. Later: drafts for failed defines

Surfaced 2026-09-27, out of scope here, recorded for the roadmap after 0.1.

A define that fails to compile leaves nothing behind, so the fix is a whole re-emission, the same cost patch removes for working modules and probably the commoner case: first defines fail more often than working modules need edits, and the re-emission after a compile error is exactly the drift moment. A coding agent with files writes, compiles, reads the error and edits; a beamlet agent starts over.

The narrow shape that falls out of this work: **a failed new define is kept, quarantined.** Quarantine already means source on disk with no beam, listed with its error, readable by `print_source`, patchable by § 3's rule and removable, and boot would quarantine the same file for the same reason. **A failed replace stays discarded**, since with patch in hand the right move is to patch the live module, not repair a draft of the rewrite; the asymmetry is the feature. Open if it proceeds: quarantine is an operator signal today with a boot-time warning, and routine failed defines need quieter copy; whether git records the failed attempt; a multi-module buffer where one module fails, which needs per-module staging; and that a draft is shared with no owner, the same ownership question as § 3's policy note. Not the general shape, a draft area beside the live modules, which makes every read and write choose between two versions of one name.

Failed defines leave no trace, so the walkthrough transcripts are the only measure of how often a model re-emits a module whole after a compile error. That number decides whether this earns a step.
