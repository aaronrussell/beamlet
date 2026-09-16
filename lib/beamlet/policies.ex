defmodule Beamlet.Policies do
  @moduledoc """
  The policies on your beamlet, built at boot and looked up by name.

  `default` is always present. The rest come from application config
  (`Beamlet.Policy` documents the shape), each built on the default
  when the beamlet starts. A bad declaration fails the boot with an
  error naming the policy and the key at fault, so a running beamlet
  never carries a policy it could not build. Declare and restart;
  there is no reload.

      Beamlet.Policies.names()
      #=> ["default", "explorer"]

      Beamlet.Policies.fetch("explorer")
      #=> {:ok, %Beamlet.Policy{name: "explorer", tools: [:eval], ...}}

  Runs as a child of `Beamlet`, owning a table that dies with it.
  Lookups read the table directly, so a request never waits on this
  process.
  """

  use GenServer

  alias Beamlet.Config
  alias Beamlet.Policy

  @doc "Starts the process and builds every declared policy."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Finds a policy by name."
  @spec fetch(String.t()) :: {:ok, Policy.t()} | {:error, :not_found}
  def fetch(name) when is_binary(name) do
    case :ets.lookup(__MODULE__, name) do
      [{^name, policy}] -> {:ok, policy}
      [] -> {:error, :not_found}
    end
  end

  @doc "The names of every policy on the beamlet, sorted."
  @spec names() :: [String.t()]
  def names do
    __MODULE__ |> :ets.tab2list() |> Enum.map(fn {name, _policy} -> name end) |> Enum.sort()
  end

  @impl true
  def init(_opts) do
    table = :ets.new(__MODULE__, [:named_table, :protected, read_concurrency: true])
    :ets.insert(table, Enum.map(build_all!(), &{&1.name, &1}))
    {:ok, table}
  end

  defp build_all! do
    Enum.reduce(Config.policies(), [Policy.default()], fn {name, document}, built ->
      case Policy.build(name, document) do
        {:ok, policy} ->
          if Enum.any?(built, &(&1.name == policy.name)) do
            raise ArgumentError,
                  "policy #{policy.name}: declared twice in config :beamlet, :policies"
          end

          [policy | built]

        {:error, message} ->
          raise ArgumentError, message
      end
    end)
  end
end
