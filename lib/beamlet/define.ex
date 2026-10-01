defmodule Beamlet.Define do
  @moduledoc """
  Define modules on your beamlet: the runtime behind the `define`
  tool.

  A define is a list of entries, one top-level `defmodule` each with
  its own `replace` permission. Each entry is formatted, scanned
  against the principal's policy (`Beamlet.Scanner`) and checked for
  docs, then the set is handed to the code server (`Beamlet.Code`),
  which compiles it into the running beamlet, writes one source file
  per module and commits the change with the principal as provenance.
  The modules are callable from `eval` and from other modules the
  moment the define returns, and are reloaded at boot.

  The entries' rules, each refused with a teaching error:

  - One top-level `defmodule` per entry, and a module named by one
    entry only. An expression is for `eval`; a nested module is
    defined as its own entry.
  - Every module has a `@moduledoc` and every public function a
    `@doc`, because docs are how a module is found later.
  - The policy applies inside module bodies exactly as it does in
    `eval`, and a denied call is refused before anything compiles.
  - `Beamlet.*` and `Host.*` are reserved; a name any loaded module
    already has is refused; redefining a module defined before
    needs `replace: true` on its entry, and that flag is harmless on
    a new module.

  Source is stored as the formatter lays it out, and it is formatted
  before anything reads it, so every error locates by the module's
  path and a line of its stored source: `lib/shopping/list.ex:4`.

  The result is a summary, one line per module:

      {:ok, "Defined Shopping.List (new)"} =
        Beamlet.Define.run([%{code: code}], principal)

  The entries land together or not at all. A replace recompiles the
  module's dependents and names them; a dependent that no longer
  compiles, or a caller of a function the replacement dropped, fails
  the whole define with nothing changed.

  One limit, set in config: `timeout` (30 seconds) is how long one
  compile may take, since a define holds the code server's single
  lane. On any error, a timeout included, nothing is changed.

      config :beamlet, define: [timeout: 30_000]
  """

  alias Beamlet.Code
  alias Beamlet.Code.Entry
  alias Beamlet.Code.Format
  alias Beamlet.Policies
  alias Beamlet.Policy
  alias Beamlet.Principal
  alias Beamlet.Scanner

  @typedoc "One module to define: its source and whether it may replace a module of the same name."
  @type entry :: %{required(:code) => String.t(), optional(:replace) => boolean()}

  @doc """
  Formats, scans, checks and defines the modules in `entries` as
  `principal`, returning the summary or the error text.

  `opts`: `timeout` overrides the configured compile timeout for
  this run.
  """
  @spec run([entry()], Principal.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(entries, %Principal{} = principal, opts \\ []) when is_list(entries) do
    {:ok, policy} = Policies.fetch(principal.policy)
    policy = Policy.grant(policy, Code.defined())

    with {:ok, parsed} <- parse_entries(entries),
         :ok <- check_entries(parsed, Policy.grant(policy, Enum.map(parsed, & &1.module))) do
      modules = Enum.map(parsed, &Map.take(&1, [:module, :source, :kind, :replace]))
      Code.define(modules, principal, Keyword.take(opts, [:timeout]))
    end
  end

  # Each entry parsed and formatted, with its module, kind and path.
  # Errors from every entry are collected so one call reports them
  # all, in entry order.
  defp parse_entries(entries) do
    manifest = Code.manifest()

    {parsed, errors} =
      entries
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {entry, index}, {parsed, errors} ->
        case parse_entry(entry, index, manifest) do
          {:ok, parsed_entry} -> {[parsed_entry | parsed], errors}
          {:error, error} -> {parsed, [error | errors]}
        end
      end)

    case errors do
      [] -> {:ok, Enum.reverse(parsed)}
      _some -> {:error, errors |> Enum.reverse() |> Enum.join("\n")}
    end
  end

  defp parse_entry(%{code: code} = entry, index, manifest) when is_binary(code) do
    with {:ok, ast} <- parse(code, index),
         {:ok, module, body} <- single_module(ast, index),
         {:ok, source} <- Format.format(code) do
      kind = Entry.kind(body)

      {:ok,
       %{
         index: index,
         module: module,
         body: body,
         kind: kind,
         path: Entry.path(module, kind, manifest),
         source: source,
         replace: Map.get(entry, :replace, false) == true
       }}
    end
  end

  defp parse_entry(_entry, index, _manifest) do
    {:error,
     "entry #{index} has no code — each entry is a map with the module's source under code"}
  end

  # A syntax error comes before the entry has a module. Its `defmodule`
  # line usually still reads, and then the locator is the module's
  # path as it will be everywhere else.
  defp parse(code, index) do
    case Entry.parse(code) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, {line, description}} ->
        case Regex.run(~r/^\s*defmodule\s+([A-Z][\w.]*)/m, code, capture: :all_but_first) do
          [name] ->
            file = Entry.path(Module.concat([name]), :module, %{})
            {:error, Scanner.locate(code, file, line, description)}

          nil ->
            {:error, "entry #{index}, " <> Scanner.locate(code, nil, line, description)}
        end
    end
  end

  defp single_module(ast, index) do
    case Entry.module(ast) do
      {:ok, module, body} ->
        {:ok, module, body}

      {:error, :not_literal} ->
        {:error, "entry #{index}: module name must be a literal, like Shopping.List"}

      {:error, {:no_body, module}} ->
        {:error, "entry #{index}: defmodule #{inspect(module)} is missing its do ... end body"}

      {:error, :no_module} ->
        {:error,
         "entry #{index} defines no module — each entry is one top-level defmodule; " <>
           "run expressions with eval"}

      {:error, {:several, names}} ->
        {:error,
         "entry #{index} defines #{Enum.join(names, ", ")} — one module per entry; " <>
           "give each its own entry"}
    end
  end

  defp check_entries(parsed, policy) do
    duplicates =
      parsed
      |> Enum.group_by(& &1.module, & &1.index)
      |> Enum.filter(fn {_module, indexes} -> length(indexes) > 1 end)
      |> Enum.sort_by(fn {_module, indexes} -> indexes end)
      |> Enum.map(fn {module, indexes} ->
        "#{inspect(module)} is defined by entries #{Enum.join(indexes, " and ")} — " <>
          "one entry per module"
      end)

    violations =
      Enum.flat_map(parsed, fn entry ->
        case Entry.check(entry, policy) do
          :ok -> []
          {:error, message} -> [message]
        end
      end)

    case duplicates ++ violations do
      [] -> :ok
      errors -> {:error, Enum.join(errors, "\n")}
    end
  end
end
