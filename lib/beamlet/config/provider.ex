defmodule Beamlet.Config.Provider do
  @moduledoc """
  Reads a `config.exs` from the data dir when a release boots.

  The file lets you configure a beamlet without rebuilding it. It is
  a plain Elixir config file:

      import Config

      config :beamlet,
        policies: [
          explorer: [tools: [:eval]]
        ],
        eval: [timeout: 60_000]

  It can set any of the keys `Beamlet.Config` lists. It is read after
  all other config, so what it says wins.

  > #### A policy here replaces the policy whole {: .warning}
  >
  > When the file names a policy, its version replaces any policy of
  > the same name declared elsewhere. The two are not merged.
  > Policies the file does not name are kept.

  A change takes a restart. `beamlet policies.show` reads the file
  afresh each time it runs, so you can check a change first. A
  beamlet with no file starts as usual. A file that fails to
  evaluate stops the boot with the file and line at fault.

  The file stands alone: `import_config` and `config_env/0` do not
  work in it.

  ## In your own release

  The standalone server reads the file already. To read it in your
  own release, add the provider to its `config_providers`:

      releases: [
        my_app: [
          config_providers: [
            {Beamlet.Config.Provider, path: {:system, "BEAMLET_DATA_DIR", "/config.exs"}}
          ]
        ]
      ]

  `path` takes any path `Config.Provider` accepts. Point it at the
  same directory as `:data_dir`.
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
      merge(config, read!(file))
    else
      config
    end
  end

  # A policy the file names replaces that policy whole, rather than
  # merging rule by rule with the one before it. Policies that are not
  # a keyword list are left to Beamlet.Config.validate!/0 to report.
  defp merge(config, file_config) do
    merged = Config.Reader.merge(config, file_config)
    before = get_in(config, [:beamlet, :policies]) || []
    file_policies = get_in(file_config, [:beamlet, :policies])

    if Keyword.keyword?(before) and Keyword.keyword?(file_policies) do
      put_in(merged, [:beamlet, :policies], Keyword.merge(before, file_policies))
    else
      merged
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
          {:ok, file |> Config.Reader.read!(imports: :disabled) |> validate!()}
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

  # Elixir 1.20 checks the file's value is config; 1.19 returns it as
  # it is, and the merge would then raise without naming the file.
  defp validate!(config) do
    if Keyword.keyword?(config) and Enum.all?(config, fn {_app, kw} -> Keyword.keyword?(kw) end) do
      config
    else
      raise ArgumentError,
            "expected the file to return a keyword list of {app, keyword} pairs, " <>
              "got: #{inspect(config)}"
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
