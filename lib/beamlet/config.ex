defmodule Beamlet.Config do
  @moduledoc """
  How a beamlet runs: `:beamlet` application config, checked once at
  boot and read plainly after.

  One config surface, read at runtime, so a release or container sets
  it from the environment in `runtime.exs`. `validate!/0` runs before
  a beamlet starts anything and fails the boot with a message naming
  the key at fault; the accessors then return what was checked, with
  defaults merged in, and never raise. A change is a restart.

  The data dir is the root everything a beamlet persists lives under:
  the databases under `db/` and the defined modules under `code/`
  (`Beamlet.Code`). Policies are declared here too (`Beamlet.Policy`),
  and the limits on the two tools (`Beamlet.Eval`, `Beamlet.Define`).

      config :beamlet,
        data_dir: "/var/lib/beamlet",
        eval: [timeout: 60_000],
        define: [timeout: 60_000]
  """

  @eval_defaults [timeout: 30_000, max_heap_bytes: 268_435_456, max_output: 16_384]
  @define_defaults [timeout: 30_000]

  @doc """
  Checks every key, raising `ArgumentError` for the first at fault.

  `Beamlet` calls it before starting anything. The data dir must be
  set and absolute, since it holds state that must never silently
  depend on the working directory; the policies must be a keyword
  list of name to document, each document checked by
  `Beamlet.Policies` when it builds them; the eval and define limits
  must be known keys with positive integers.
  """
  @spec validate!() :: :ok
  def validate! do
    validate_data_dir!(Application.fetch_env(:beamlet, :data_dir))
    validate_policies!(Application.get_env(:beamlet, :policies, []))
    validate_limits!(:eval, @eval_defaults, Application.get_env(:beamlet, :eval, []))
    validate_limits!(:define, @define_defaults, Application.get_env(:beamlet, :define, []))
    :ok
  end

  @doc "The data directory, an absolute path."
  @spec data_dir() :: Path.t()
  def data_dir, do: Application.fetch_env!(:beamlet, :data_dir)

  @doc "Directory holding Beamlet and agent database files."
  @spec db_dir() :: Path.t()
  def db_dir, do: Path.join(data_dir(), "db")

  @doc "Directory holding the defined modules: their sources, beams and git history."
  @spec code_dir() :: Path.t()
  def code_dir, do: Path.join(data_dir(), "code")

  @doc "The policies declared beside `default`, as a keyword list of name to document (`Beamlet.Policy`). Empty when unset."
  @spec policies() :: keyword()
  def policies, do: Application.get_env(:beamlet, :policies, [])

  @doc """
  The eval limits, merged over the defaults: `timeout` 30 seconds,
  `max_heap_bytes` 256MB, `max_output` 16KB (`Beamlet.Eval` says
  what each protects).
  """
  @spec eval() :: keyword()
  def eval, do: limits(:eval, @eval_defaults)

  @doc """
  The define limits, merged over the defaults: `timeout` 30 seconds,
  the time one compile may take (`Beamlet.Define`).
  """
  @spec define() :: keyword()
  def define, do: limits(:define, @define_defaults)

  defp limits(key, defaults) do
    configured = Application.get_env(:beamlet, key, [])
    for {name, default} <- defaults, do: {name, Keyword.get(configured, name, default)}
  end

  defp validate_data_dir!({:ok, dir}) when is_binary(dir) do
    unless Path.type(dir) == :absolute do
      raise ArgumentError, "config :beamlet, :data_dir must be absolute, got: #{dir}"
    end
  end

  defp validate_data_dir!({:ok, other}) do
    raise ArgumentError,
          "config :beamlet, :data_dir must be a path string, got: #{inspect(other)}"
  end

  defp validate_data_dir!(:error) do
    raise ArgumentError, "config :beamlet, :data_dir is not set"
  end

  defp validate_policies!(policies) do
    unless Keyword.keyword?(policies) do
      raise ArgumentError,
            "config :beamlet, :policies must be a keyword list of policy name to " <>
              "document, got: #{inspect(policies)}"
    end
  end

  defp validate_limits!(key, defaults, limits) do
    unless Keyword.keyword?(limits) do
      raise ArgumentError,
            "config :beamlet, #{inspect(key)} must be a keyword list of limits, got: #{inspect(limits)}"
    end

    names = Keyword.keys(defaults)

    for {name, value} <- limits,
        name not in names or not is_integer(value) or value < 1 do
      raise ArgumentError,
            "config :beamlet, #{inspect(key)}: the limits are #{list(names)}, " <>
              "each a positive integer, got: #{inspect({name, value})}"
    end
  end

  defp list([name]), do: to_string(name)

  defp list(names) do
    {last, rest} = List.pop_at(names, -1)
    Enum.join(rest, ", ") <> " and " <> to_string(last)
  end
end
