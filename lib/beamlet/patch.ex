defmodule Beamlet.Patch do
  @moduledoc """
  Patch modules on your beamlet: the runtime behind the `patch`
  tool.

  A patch names a module, one anchor and one operation, as the tool
  passes them:

      %{module: "Shopping.List", select: "total/1", replace: "..."}
      %{module: "Shopping.List", find: "def total(items)", before: "..."}

  `find` is text occurring exactly once in the module's stored
  source; `select` is a function as `name/arity`, whose block is all
  its clauses and the `@doc` and `@spec` above them. `replace` swaps
  the anchor, empty to remove it; `before` and `after` insert around
  it. The patches apply in order to in-memory copies of the sources,
  each seeing the text the previous ones left, and the touched
  modules then run the define pipeline as a replace
  (`Beamlet.Define`): formatted, scanned against the principal's
  policy, checked for docs, compiled with their dependents and
  committed as one `patch:` commit. On any error nothing changes.

  A module must be defined or quarantined. A quarantined module
  whose source does not parse is patchable by `find`, since a
  one-line fix is the natural recovery, and may take several
  patches to parse again; `select` needs a source that parses.

  The stale-read guard: each module's source is hashed as read, and
  the code server refuses to write over a module that changed in
  between, so two writers never lose an update silently. The retry
  is a fresh read and the same patches.

  The result is one line per module with what changed beneath it:

      {:ok, "Patched Shopping.List\\n  - changed total/1"} =
        Beamlet.Patch.run(patches, principal)

  Every error is a teaching error naming the patch that caused it,
  `patch 2 (Shopping.List, select total/1): ...`, and an error from
  the pipeline quotes the failing line with two lines either side,
  since the patched text exists nowhere the agent can read.
  `opts[:timeout]` is define's compile timeout.
  """

  alias Beamlet.Code
  alias Beamlet.Code.Entry
  alias Beamlet.Code.Format
  alias Beamlet.Code.Source
  alias Beamlet.Config
  alias Beamlet.Policies
  alias Beamlet.Policy
  alias Beamlet.Principal
  alias Beamlet.Scanner

  @context 2
  @label_width 60
  @anchors [:find, :select]
  @operations [:replace, :before, :after]
  @select ~r/\A([a-z_][a-zA-Z0-9_]*[?!]?)\/(\d+)\z/

  @typedoc """
  One patch: the module by name, exactly one anchor (`find` or
  `select`) and exactly one operation (`replace`, `before` or
  `after`).
  """
  @type patch :: %{
          required(:module) => String.t(),
          optional(:find) => String.t(),
          optional(:select) => String.t(),
          optional(:replace) => String.t(),
          optional(:before) => String.t(),
          optional(:after) => String.t()
        }

  @doc """
  Applies `patches` in order and defines the patched modules as
  `principal`, returning the summary or the error text.

  `opts`: `timeout` overrides the configured compile timeout.
  """
  @spec run([patch()], Principal.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(patches, %Principal{} = principal, opts \\ []) when is_list(patches) do
    {:ok, policy} = Policies.fetch(principal.policy)
    policy = Policy.grant(policy, Code.defined())

    with {:ok, parsed} <- parse_patches(patches),
         {:ok, order, sources} <- read_sources(parsed),
         {:ok, sources} <- apply_patches(parsed, sources),
         {:ok, entries} <- finish(order, sources, parsed, policy) do
      run_opts = [verb: :patch, context: @context] ++ Keyword.take(opts, [:timeout])
      Code.define(entries, principal, run_opts)
    end
  end

  # ── The patches ───────────────────────────────────────────────────

  # Every patch is checked for shape before any is applied, and the
  # errors come back together in patch order, as define's entry
  # errors do.
  defp parse_patches(patches) do
    {parsed, errors} =
      patches
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {patch, index}, {parsed, errors} ->
        case parse_patch(patch, index) do
          {:ok, parsed_patch} -> {[parsed_patch | parsed], errors}
          {:error, error} -> {parsed, [error | errors]}
        end
      end)

    case errors do
      [] -> {:ok, Enum.reverse(parsed)}
      _some -> {:error, errors |> Enum.reverse() |> Enum.join("\n")}
    end
  end

  defp parse_patch(patch, index) when is_map(patch) do
    with {:ok, module, file} <- module_of(patch, index),
         {:ok, anchor} <- anchor_of(patch, index),
         {:ok, op} <- op_of(patch, index) do
      {:ok, %{index: index, module: module, file: file, anchor: anchor, op: op}}
    end
  end

  defp parse_patch(_patch, index) do
    {:error,
     "patch #{index} is not a map — each patch is a map with the module, an anchor and an " <>
       "operation"}
  end

  defp module_of(patch, index) do
    case Map.get(patch, :module) do
      name when is_binary(name) and name != "" ->
        module = Module.concat([name])

        case source_file(module) do
          {:ok, file} ->
            {:ok, module, file}

          :error ->
            if Elixir.Code.ensure_loaded?(module) do
              {:error,
               "patch #{index}: #{inspect(module)} is part of your beamlet, not a defined " <>
                 "module — patch edits modules defined with define; " <>
                 "Host.Code.print_modules() shows them"}
            else
              {:error,
               "patch #{index}: #{inspect(module)} is not a defined module — " <>
                 "Host.Code.print_modules() shows what is"}
            end
        end

      _missing ->
        {:error, "patch #{index} names no module — each patch names the module it edits"}
    end
  end

  # A quarantined module has a source and no beam, and its file is
  # what print_source shows, so that is the path its errors carry.
  defp source_file(module) do
    case Code.manifest() do
      %{^module => %{source_file: source_file}} ->
        {:ok, source_file}

      _not_defined ->
        case Enum.find(Code.quarantined(), &(module in &1.modules)) do
          %{file: file} -> {:ok, file}
          nil -> :error
        end
    end
  end

  defp anchor_of(patch, index) do
    case present(patch, @anchors) do
      [:find] ->
        case Map.fetch!(patch, :find) do
          text when is_binary(text) and text != "" ->
            {:ok, {:find, text}}

          _empty ->
            {:error,
             "patch #{index}: find is empty — quote text occurring exactly once in the " <>
               "module's current source"}
        end

      [:select] ->
        with text when is_binary(text) <- Map.fetch!(patch, :select),
             [name, arity] <- Regex.run(@select, text, capture: :all_but_first) do
          {:ok, {:select, String.to_atom(name), String.to_integer(arity)}}
        else
          _other ->
            {:error,
             "patch #{index}: select #{inspect(Map.fetch!(patch, :select))} is not a function " <>
               "as name/arity — spell it as Host.Code.print_outline lists it, like total/1"}
        end

      [] ->
        {:error, "patch #{index} has no anchor — " <> anchor_rule()}

      _both ->
        {:error, "patch #{index} has both find and select — " <> anchor_rule()}
    end
  end

  defp anchor_rule do
    "one anchor per patch: find, text occurring exactly once in the module's source, or " <>
      "select, a function as name/arity"
  end

  defp op_of(patch, index) do
    case present(patch, @operations) do
      [:replace] ->
        case Map.fetch!(patch, :replace) do
          code when is_binary(code) -> {:ok, {:replace, code}}
          _other -> {:error, "patch #{index}: replace must be a string, empty to remove"}
        end

      [key] ->
        case Map.fetch!(patch, key) do
          code when is_binary(code) and code != "" ->
            {:ok, {key, code}}

          _empty ->
            {:error,
             "patch #{index}: #{key} is empty — nothing to insert; replace with empty text " <>
               "removes the anchor"}
        end

      [] ->
        {:error, "patch #{index} has no operation — " <> op_rule()}

      several ->
        {:error, "patch #{index} has #{Enum.join(several, " and ")} — " <> op_rule()}
    end
  end

  defp op_rule do
    "one operation per patch: replace (empty removes), before or after"
  end

  defp present(patch, keys), do: Enum.filter(keys, &(Map.get(patch, &1) != nil))

  # ── The sources ───────────────────────────────────────────────────

  # Each touched module is read once, in first-touch order, and the
  # bytes are hashed there and then: that hash is what the code
  # server compares against the file when the write comes.
  defp read_sources(parsed) do
    order = parsed |> Enum.map(& &1.module) |> Enum.uniq()
    files = Map.new(parsed, &{&1.module, &1.file})

    Enum.reduce_while(order, {:ok, order, %{}}, fn module, {:ok, order, sources} ->
      file = Map.fetch!(files, module)

      case File.read(file) do
        {:ok, bytes} ->
          state = %{
            module: module,
            path: Path.relative_to(file, Config.code_dir()),
            source: bytes,
            hash: :crypto.hash(:sha256, bytes),
            parsed?: match?({:ok, _ast}, Entry.parse(bytes)),
            last: nil
          }

          {:cont, {:ok, order, Map.put(sources, module, state)}}

        {:error, reason} ->
          {:halt,
           {:error, "could not read the source of #{inspect(module)} (#{inspect(reason)})"}}
      end
    end)
  end

  # In order, each to the text the previous ones left, stopping at
  # the first that fails. The result is parsed after every patch: a
  # module that was parsing and stops is refused at that patch, and
  # a quarantined module that never parsed goes on, since repairing
  # it may take more than one find.
  defp apply_patches(parsed, sources) do
    Enum.reduce_while(parsed, {:ok, sources}, fn patch, {:ok, sources} ->
      state = Map.fetch!(sources, patch.module)

      case apply_patch(patch, state) do
        {:ok, state} -> {:cont, {:ok, Map.put(sources, patch.module, %{state | last: patch})}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp apply_patch(%{anchor: {:find, text}, op: op} = patch, state) do
    case Source.patch_find(state.source, text, op) do
      {:ok, source} -> check_parse(patch, %{state | source: source})
      {:error, reason} -> {:error, find_error(patch, reason)}
    end
  end

  defp apply_patch(%{anchor: {:select, name, arity}, op: op} = patch, state) do
    case Source.patch_select(state.source, name, arity, op) do
      {:ok, source} ->
        check_parse(patch, %{state | source: source})

      {:error, :not_found, []} ->
        {:error,
         "#{label(patch)}: #{inspect(state.module)} has no function #{name}/#{arity} — it " <>
           "defines no functions; Host.Code.print_outline(#{inspect(state.module)}) shows " <>
           "what it holds"}

      {:error, :not_found, functions} ->
        {:error,
         "#{label(patch)}: #{inspect(state.module)} has no function #{name}/#{arity} — " <>
           "Host.Code.print_outline(#{inspect(state.module)}) lists what it has: " <>
           Enum.join(functions, ", ")}

      {:error, :scattered} ->
        {:error,
         "#{label(patch)}: #{inspect(state.module)}.#{name}/#{arity} has clauses separated " <>
           "by other definitions, so select cannot take it as one block — patch the " <>
           "clauses with find"}

      {:error, {line, message}} ->
        {:error,
         "#{label(patch)}: #{inspect(state.module)} does not parse, so select cannot find " <>
           "#{name}/#{arity} — #{Scanner.locate(state.source, state.path, line, message)}\n" <>
           "Repair it with find, or read it by line range: #{range_print(state)}"}
    end
  end

  defp check_parse(patch, state) do
    case Entry.parse(state.source) do
      {:ok, _ast} ->
        {:ok, %{state | parsed?: true}}

      {:error, _reason} when not state.parsed? ->
        {:ok, state}

      {:error, {line, message}} ->
        located = Scanner.locate(state.source, state.path, line, message, context: @context)
        {:error, "#{label(patch)}: the result does not parse — #{located}"}
    end
  end

  defp find_error(patch, :not_found) do
    "#{label(patch)}: no match — quote text exactly as Host.Code.print_source prints it. " <>
      "Source is stored formatted, so text from a define buffer may differ from what is stored."
  end

  defp find_error(patch, :indented) do
    "#{label(patch)}: no exact match, though the text matches once with leading whitespace " <>
      "ignored — quote it with its indentation as Host.Code.print_source prints it. Source " <>
      "is stored formatted, so text from a define buffer may differ from what is stored."
  end

  defp find_error(patch, {:several, count}) do
    "#{label(patch)}: the text occurs #{count} times — quote more context, so it occurs once"
  end

  # ── The pipeline ──────────────────────────────────────────────────

  # Each module's result on its own: it must parse and still be the
  # one module, then it is formatted, scanned and docs-gated, every
  # error prefixed by the patches that produced it. Errors from
  # every module come back together.
  defp finish(order, sources, parsed, policy) do
    labels = module_labels(parsed)

    {entries, errors} =
      Enum.reduce(order, {[], []}, fn module, {entries, errors} ->
        state = Map.fetch!(sources, module)

        case finish_module(state, Map.fetch!(labels, module), policy) do
          {:ok, entry} -> {[entry | entries], errors}
          {:error, error} -> {entries, [error | errors]}
        end
      end)

    case errors do
      [] -> {:ok, Enum.reverse(entries)}
      _some -> {:error, errors |> Enum.reverse() |> Enum.join("\n")}
    end
  end

  defp finish_module(state, label, policy) do
    case Entry.parse(state.source) do
      {:error, {line, message}} ->
        {:error,
         "#{inspect(state.module)} did not parse before this call and still does not after " <>
           "patch #{state.last.index}: #{Scanner.locate(state.source, state.path, line, message)}\n" <>
           "Read it by line range: #{range_print(state)}"}

      {:ok, ast} ->
        with {:ok, body} <- same_module(ast, state, label),
             {:ok, source} <- format(state, label),
             :ok <- check(source, state, label, policy) do
          {:ok,
           %{
             module: state.module,
             source: source,
             kind: Entry.kind(body),
             replace: true,
             hash: state.hash,
             label: label
           }}
        end
    end
  end

  # The pipeline files a module by its name, so a patch that changed
  # the defmodule line would leave the old module behind under the
  # new one's summary.
  defp same_module(ast, state, label) do
    module = state.module

    case Entry.module(ast) do
      {:ok, ^module, body} ->
        {:ok, body}

      {:ok, other, _body} ->
        {:error,
         "#{label} changed the defmodule line from #{inspect(module)} to #{inspect(other)} — " <>
           "the pipeline would file a new module and leave the old. Keep the name; to rename, " <>
           "define #{inspect(other)} and remove #{inspect(module)}."}

      {:error, :no_module} ->
        {:error,
         "#{label} left #{inspect(module)} with no defmodule — a module's source is one " <>
           "top-level defmodule"}

      {:error, {:several, names}} ->
        {:error,
         "#{label} left more than one module in #{inspect(module)}'s source " <>
           "(#{Enum.join(names, ", ")}) — one module per source; define the other on its own"}

      {:error, :not_literal} ->
        {:error, "#{label} left #{inspect(module)} with a defmodule name that is not a literal"}

      {:error, {:no_body, other}} ->
        {:error, "#{label} left defmodule #{inspect(other)} without its do ... end body"}
    end
  end

  defp format(state, label) do
    case Format.format(state.source) do
      {:ok, source} -> {:ok, source}
      {:error, message} -> {:error, "#{label}: #{message}"}
    end
  end

  defp check(source, state, label, policy) do
    case Entry.check(source, policy, state.path, context: @context) do
      :ok -> :ok
      {:error, message} -> {:error, "#{label}: #{message}"}
    end
  end

  # ── Labels ────────────────────────────────────────────────────────

  defp label(%{index: index, module: module, anchor: anchor}) do
    "patch #{index} (#{inspect(module)}, #{anchor_text(anchor)})"
  end

  defp anchor_text({:select, name, arity}), do: "select #{name}/#{arity}"

  defp anchor_text({:find, text}) do
    line = text |> String.split("\n", parts: 2) |> hd() |> String.trim()

    line =
      if String.length(line) > @label_width,
        do: String.slice(line, 0, @label_width - 3) <> "...",
        else: line

    "find #{inspect(line)}"
  end

  # A module several patches touched is labelled by all of them, since
  # a pipeline error cannot tell which one caused it.
  defp module_labels(parsed) do
    parsed
    |> Enum.group_by(& &1.module)
    |> Map.new(fn
      {module, [patch]} ->
        {module, label(patch)}

      {module, patches} ->
        {module, "patches #{join_indexes(patches)} (#{inspect(module)})"}
    end)
  end

  defp join_indexes(patches) do
    indexes = Enum.map(patches, & &1.index)
    {init, [last]} = Enum.split(indexes, -1)
    "#{Enum.join(init, ", ")} and #{last}"
  end

  defp range_print(state) do
    "Host.Code.print_source(#{inspect(state.module)}, 1..#{Source.line_count(state.source)})"
  end
end
