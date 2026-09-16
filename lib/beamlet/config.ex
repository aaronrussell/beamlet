defmodule Beamlet.Config do
  @moduledoc """
  How a beamlet runs: `:beamlet` application config, checked once at
  boot and read plainly after.

  One config surface, read at runtime, so a release or container sets
  it from the environment in `runtime.exs`. `validate!/0` runs before
  a beamlet starts anything and fails the boot with a message naming
  the key at fault; the accessors then return what was checked, with
  defaults merged in, and never raise. A change is a restart.

  The data dir is the root everything a beamlet persists lives under;
  the modules owning paths beneath it add their accessors here as
  they arrive. Policies are declared here too (`Beamlet.Policy`), and
  the eval limits (`Beamlet.Eval`).

      config :beamlet,
        data_dir: "/var/lib/beamlet",
        eval: [timeout: 60_000]
  """

  @eval_defaults [timeout: 30_000, max_heap_bytes: 268_435_456, max_output: 16_384]

  @doc """
  Checks every key, raising `ArgumentError` for the first at fault.

  `Beamlet` calls it before starting anything. The data dir must be
  set and absolute, since it holds state that must never silently
  depend on the working directory; the policies must be a keyword
  list of name to document, each document checked by
  `Beamlet.Policies` when it builds them; the eval limits must be
  known keys with positive integers.
  """
  @spec validate!() :: :ok
  def validate! do
    validate_data_dir!(Application.fetch_env(:beamlet, :data_dir))
    validate_policies!(Application.get_env(:beamlet, :policies, []))
    validate_eval!(Application.get_env(:beamlet, :eval, []))
    :ok
  end

  @doc "The data directory, an absolute path."
  @spec data_dir() :: Path.t()
  def data_dir, do: Application.fetch_env!(:beamlet, :data_dir)

  @doc "Directory holding Beamlet and agent database files."
  @spec db_dir() :: Path.t()
  def db_dir, do: Path.join(data_dir(), "db")

  @doc "The policies declared beside `default`, as a keyword list of name to document (`Beamlet.Policy`). Empty when unset."
  @spec policies() :: keyword()
  def policies, do: Application.get_env(:beamlet, :policies, [])

  @doc """
  The eval limits, merged over the defaults: `timeout` 30 seconds,
  `max_heap_bytes` 256MB, `max_output` 16KB (`Beamlet.Eval` says
  what each protects).
  """
  @spec eval() :: keyword()
  def eval do
    eval = Application.get_env(:beamlet, :eval, [])
    for {key, default} <- @eval_defaults, do: {key, Keyword.get(eval, key, default)}
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

  defp validate_eval!(eval) do
    unless Keyword.keyword?(eval) do
      raise ArgumentError,
            "config :beamlet, :eval must be a keyword list of limits, got: #{inspect(eval)}"
    end

    for {key, value} <- eval,
        key not in Keyword.keys(@eval_defaults) or not is_integer(value) or value < 1 do
      raise ArgumentError,
            "config :beamlet, :eval: the limits are timeout, max_heap_bytes and " <>
              "max_output, each a positive integer, got: #{inspect({key, value})}"
    end
  end
end
