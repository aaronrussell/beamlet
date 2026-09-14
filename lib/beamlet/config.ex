defmodule Beamlet.Config do
  @moduledoc """
  How a beamlet runs: accessors over `:beamlet` application config.

  One config surface, read at runtime, so a release or container sets
  it from the environment in `runtime.exs`. The data dir is the root
  everything a beamlet persists lives under; the modules owning paths
  beneath it add their accessors here as they arrive.

      config :beamlet, data_dir: "/var/lib/beamlet"
  """

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
end
