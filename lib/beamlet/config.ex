defmodule Beamlet.Config do
  @moduledoc """
  How a beamlet runs: accessors over `:beamlet` application config.

  One config surface, read at runtime, so a release or container sets
  it from the environment in `runtime.exs`. The data dir is the root
  everything a beamlet persists lives under; the modules owning paths
  beneath it add their accessors here as they arrive. Policies are
  declared here too (`Beamlet.Policy`), and the eval limits
  (`Beamlet.Eval`).

      config :beamlet,
        data_dir: "/var/lib/beamlet",
        eval: [timeout: 60_000]
  """

  @eval_defaults [timeout: 30_000, max_heap_bytes: 268_435_456, max_output: 16_384]

  @doc """
  The data directory. Must be configured as an absolute path.

  Raises when unset or relative: the data dir holds state that must
  never silently depend on the working directory.
  """
  @spec data_dir!() :: Path.t()
  def data_dir! do
    case Application.fetch_env(:beamlet, :data_dir) do
      {:ok, dir} when is_binary(dir) ->
        if Path.type(dir) == :absolute do
          dir
        else
          raise ArgumentError, "config :beamlet, :data_dir must be absolute, got: #{dir}"
        end

      {:ok, other} ->
        raise ArgumentError,
              "config :beamlet, :data_dir must be a path string, got: #{inspect(other)}"

      :error ->
        raise ArgumentError, "config :beamlet, :data_dir is not set"
    end
  end

  @doc "Directory holding Beamlet and agent database files."
  @spec db_dir() :: Path.t()
  def db_dir, do: Path.join(data_dir!(), "db")

  @doc """
  The policies declared beside `default`, as a keyword list of name
  to document (`Beamlet.Policy`). Empty when unset.

  Raises when the value is not a keyword list; each document is
  validated by `Beamlet.Policies` at boot.
  """
  @spec policies!() :: keyword()
  def policies! do
    policies = Application.get_env(:beamlet, :policies, [])

    if Keyword.keyword?(policies) do
      policies
    else
      raise ArgumentError,
            "config :beamlet, :policies must be a keyword list of policy name to " <>
              "document, got: #{inspect(policies)}"
    end
  end

  @doc """
  The eval limits, merged over the defaults: `timeout` 30 seconds,
  `max_heap_bytes` 256MB, `max_output` 16KB (`Beamlet.Eval` says
  what each protects).

  Raises when the value is not a keyword list, names another key, or
  sets a limit to anything but a positive integer.
  """
  @spec eval!() :: keyword()
  def eval! do
    eval = Application.get_env(:beamlet, :eval, [])

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

    for {key, default} <- @eval_defaults, do: {key, Keyword.get(eval, key, default)}
  end
end
