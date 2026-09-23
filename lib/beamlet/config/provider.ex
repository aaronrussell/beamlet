defmodule Beamlet.Config.Provider do
  @moduledoc """
  The operator config file: an optional `config.exs` in the data dir,
  merged into application config when a release boots.

  A container declares its policies without a rebuild. The file is a
  plain `Config` file, read by this `Config.Provider` after
  `runtime.exs` and merged over everything before it, so what it says
  is the last word. A release names it beside its other providers:

      releases: [
        my_app: [
          config_providers: [
            {Beamlet.Config.Provider, path: {:system, "BEAMLET_DATA_DIR", "/config.exs"}}
          ]
        ]
      ]

  The file is for the keys `Beamlet.Config` documents, the policies
  above all, and the eval and define limits beside them:

      import Config

      config :beamlet,
        policies: [
          explorer: [tools: [:eval]]
        ]

  It is application config all the same, so it can set any key of any
  application, including ones the environment set a moment earlier,
  and nothing here stands in the way. That is not the intended use:
  the environment configures the deployment, this file configures the
  beamlet, and an operator who reaches past that is on their own.

  No file means no change, silently. A file that fails to evaluate
  fails the boot, naming the file and the line; a policy it declares
  badly fails the boot the way any declared policy does
  (`Beamlet.Policies`). The release's `eval` command runs config
  providers too, so `beamlet policies` on the container reads the
  file afresh and either lists what it declares or prints what is
  wrong with it, without a restart; the running beamlet picks the
  change up on its next start. The file is trusted code, evaluated as
  the release's user: a policy that grants `File` to agent code hands
  it over, as it hands over the code dir.

  The file is one file: `import_config` is disabled inside it, and
  `config_env/0` is not available.
  """

  @behaviour Config.Provider

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    Config.Provider.validate_config_path!(path)
    path
  end

  @impl true
  def load(config, path) do
    file = Config.Provider.resolve_config_path!(path)

    if File.regular?(file) do
      Config.Reader.merge(config, read!(file))
    else
      config
    end
  end

  @doc """
  Reads the file, returning what it declares.

  Raises `ArgumentError` naming the file, and the line when the error
  has one in it, so a boot log says where to look.
  """
  @spec read!(Path.t()) :: keyword()
  def read!(file) when is_binary(file) do
    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          {:ok, Config.Reader.read!(file, imports: :disabled)}
        rescue
          error -> {:error, error, __STACKTRACE__}
        end
      end)

    case result do
      {:ok, config} ->
        config

      {:error, error, stacktrace} ->
        reraise ArgumentError,
                [message: located(error, diagnostics, file, stacktrace)],
                stacktrace
    end
  end

  # The compiler reports an undefined name as a diagnostic with the
  # line and a bare "cannot compile file" error without one; a syntax
  # error carries its own line; a raise while evaluating leaves a
  # stack frame recorded against the file's absolute path.
  defp located(error, diagnostics, file, stacktrace) do
    case Enum.find(diagnostics, &(&1.severity == :error)) do
      %{message: message, position: position} ->
        "#{file}:#{line_of(position)}: #{message}"

      nil ->
        message = Exception.message(error)

        case line_in(error, file, stacktrace) do
          nil -> "#{file}: #{message}"
          line -> "#{file}:#{line}: #{message}"
        end
    end
  end

  defp line_of({line, _column}), do: line
  defp line_of(line), do: line

  defp line_in(%{file: error_file, line: line}, file, _stacktrace)
       when is_binary(error_file) and is_integer(line) and line > 0 do
    if Path.expand(error_file) == Path.expand(file), do: line
  end

  defp line_in(_error, file, stacktrace) do
    Enum.find_value(stacktrace, fn
      {_module, _fun, _arity, location} ->
        with frame_file when frame_file != nil <- Keyword.get(location, :file),
             true <- Path.expand(to_string(frame_file)) == Path.expand(file) do
          location[:line]
        else
          _ -> nil
        end

      _frame ->
        nil
    end)
  end
end
