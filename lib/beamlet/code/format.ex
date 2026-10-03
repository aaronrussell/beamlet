defmodule Beamlet.Code.Format do
  @moduledoc false

  # Agent source is stored as the formatter lays it out, and it is
  # formatted before the scanner, the docs gate or the compiler reads
  # it, so there is one text per module from the first error to the
  # stored file. Elixir's defaults, plus the no-parens locals the
  # packages export so `plug :auth`, `attr` and `slot` stay bare. The
  # exports are read here at compile time because a release carries
  # no `.formatter.exs`. No plugins: `~H` content stays verbatim.

  @deps [:phoenix, :ecto, :ecto_sql, :plug]

  @locals Enum.flat_map(@deps, fn dep ->
            file = Path.join(Mix.Project.deps_paths()[dep], ".formatter.exs")
            {opts, _bindings} = Code.eval_file(file)
            get_in(opts, [:export, :locals_without_parens]) || []
          end)

  for dep <- @deps do
    @external_resource Path.join(Mix.Project.deps_paths()[dep], ".formatter.exs")
  end

  @doc "Formats agent source as it is stored, with a trailing newline."
  @spec format(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def format(source) when is_binary(source) do
    formatted =
      source |> Code.format_string!(locals_without_parens: @locals) |> IO.iodata_to_binary()

    {:ok, formatted <> "\n"}
  rescue
    exception ->
      {:error,
       "could not format the module (#{Exception.message(exception)}) — nothing was changed"}
  end
end
