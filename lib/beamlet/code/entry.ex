defmodule Beamlet.Code.Entry do
  @moduledoc false

  # The per-module steps define and patch share, each runtime keeping
  # its own wording for what they refuse: parsing the source, finding
  # its one top-level defmodule, deciding from its `use` line whether
  # it is a migration and where it is filed, and the scan and docs
  # gate over the formatted text. The AST helpers the pipeline's other
  # readers of module source use live here too.

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
        named_path(module, kind)
    end
  end

  # The path a module's name gives it, relative to the code dir. Four-
  # digit padding is cosmetic; the version is parsed numerically.
  @spec named_path(module(), kind(), pos_integer() | nil) :: Path.t()
  def named_path(module, kind, version \\ nil)

  def named_path(module, :module, nil), do: "lib/#{Macro.underscore(module)}.ex"

  def named_path(module, :migration, version) do
    name = module |> Macro.underscore() |> String.replace("/", "_")

    case version do
      nil -> "migrations/#{name}.ex"
      version -> "migrations/#{String.pad_leading(Integer.to_string(version), 4, "0")}_#{name}.ex"
    end
  end

  @spec check(
          %{module: module(), body: Macro.t(), source: String.t(), path: Path.t()},
          Policy.t(),
          keyword()
        ) :: :ok | {:error, String.t()}
  def check(entry, %Policy{} = policy, opts \\ []) do
    scan_opts = [file: entry.path, context: Keyword.get(opts, :context, 0)]

    with :ok <- Scanner.scan_define(entry.source, entry.module, policy, scan_opts) do
      Docs.check(entry.module, entry.body)
    end
  end

  @spec block_forms(Macro.t()) :: [Macro.t()]
  def block_forms({:__block__, _meta, forms}), do: forms
  def block_forms(form), do: [form]

  @spec function_name(Macro.t()) :: {:ok, atom(), arity()} | :error
  def function_name({:when, _meta, [head | _guards]}), do: function_name(head)

  def function_name({name, _meta, args}) when is_atom(name) do
    {:ok, name, if(is_list(args), do: length(args), else: 0)}
  end

  def function_name(_head), do: :error
end
