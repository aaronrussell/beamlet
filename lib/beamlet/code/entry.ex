defmodule Beamlet.Code.Entry do
  @moduledoc false

  # The per-module steps define and patch share, each runtime keeping
  # its own wording for what they refuse: parsing the source, finding
  # its one top-level defmodule, deciding from its `use` line whether
  # it is a migration and where it is filed, and the scan and docs
  # gate over the formatted text.

  alias Beamlet.Code.Docs
  alias Beamlet.Config
  alias Beamlet.Policy
  alias Beamlet.Scanner

  @type kind :: :module | :migration

  @spec parse(String.t()) :: {:ok, Macro.t()} | {:error, {non_neg_integer(), String.t()}}
  def parse(code) when is_binary(code) do
    {:ok, Code.string_to_quoted!(code)}
  rescue
    e in [SyntaxError, TokenMissingError, MismatchedDelimiterError] ->
      {:error, {e.line, e.description}}
  end

  @spec module(Macro.t()) ::
          {:ok, module(), Macro.t()}
          | {:error, :no_module | :not_literal | {:no_body, module()} | {:several, [String.t()]}}
  def module(ast) do
    modules =
      ast
      |> block_forms()
      |> Enum.flat_map(fn
        {:defmodule, _meta, [{:__aliases__, _, parts} | rest]} -> [{parts, rest}]
        _other -> []
      end)

    case modules do
      [{parts, rest}] ->
        cond do
          not literal?(parts) -> {:error, :not_literal}
          match?([[{:do, _body} | _]], rest) -> {:ok, Module.concat(parts), body(rest)}
          true -> {:error, {:no_body, Module.concat(parts)}}
        end

      [] ->
        {:error, :no_module}

      several ->
        {:error,
         {:several,
          Enum.map(several, fn {parts, _rest} -> Macro.to_string({:__aliases__, [], parts}) end)}}
    end
  end

  defp literal?(parts), do: is_list(parts) and Enum.all?(parts, &is_atom/1)

  defp body([[{:do, body} | _rest]]), do: body

  @spec kind(Macro.t()) :: kind()
  def kind(body) do
    if Enum.any?(block_forms(body), &migration_use?/1), do: :migration, else: :module
  end

  defp migration_use?({:use, _meta, [{:__aliases__, _, [:Ecto, :Migration]} | _opts]}), do: true
  defp migration_use?(_form), do: false

  # A migration's stored path carries the version the code server
  # assigns in its lane, so a new migration locates by its name until
  # then; a module already defined locates by its file.
  @spec path(module(), kind(), %{module() => Beamlet.Code.paths()}) :: Path.t()
  def path(module, kind, manifest) do
    case manifest do
      %{^module => %{source_file: source_file}} ->
        Path.relative_to(source_file, Config.code_dir())

      _new ->
        name = Macro.underscore(module)

        case kind do
          :module -> "lib/#{name}.ex"
          :migration -> "migrations/#{String.replace(name, "/", "_")}.ex"
        end
    end
  end

  @spec check(String.t(), module(), Policy.t(), Path.t(), keyword()) :: :ok | {:error, String.t()}
  def check(source, module, %Policy{} = policy, path, opts \\ []) do
    scan_opts = [file: path, context: Keyword.get(opts, :context, 0)]

    with :ok <- Scanner.scan_define(source, module, policy, scan_opts) do
      Docs.check(source)
    end
  end

  defp block_forms({:__block__, _meta, forms}), do: forms
  defp block_forms(form), do: [form]
end
