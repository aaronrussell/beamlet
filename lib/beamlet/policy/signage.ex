defmodule Beamlet.Policy.Signage do
  @moduledoc """
  The teaching copy appended to a refusal, for the few names where
  "not permitted by your policy" would leave an agent guessing.

  A hint is one of two kinds. A **redirect** names the door the agent
  would not guess: `File` is refused, `Host.FS` is where scoped file
  access lives. A **closure** says a whole family is withheld, so
  the agent stops walking its siblings: refusing `Task` with no hint
  invites `spawn`, then `GenServer`, then `:timer`. Everything else
  denied gets the generic copy, and this overlay covers nothing on
  its own; the rulings live in `Beamlet.Policy.Default`.

  Signage is Beamlet-wide, and a lookup takes the policy so the copy
  stays true for it. A module the policy grants is never refused, so
  its hint never fires. A redirect is dropped when the policy
  withholds its door, whether a `Host.*` module it denies or has not
  yet got, or the `define` tool, because a pointer at a closed door
  is the one hint that misleads.
  """

  alias Beamlet.Policy

  @typedoc "Where a redirect points: a module, the `define` tool, or nowhere."
  @type door :: module() | {:tool, Policy.tool()} | nil

  # Copy follows "X is not permitted by your policy: ", one line, no
  # promises about what is planned.
  @categories [
    fs: {"Host.FS provides scoped file access", Host.FS},
    state: {"state that outlives an eval is kept in Host.KV", Host.KV},
    concurrency:
      {"process primitives are withheld as a family; there is no sibling to reach for", nil},
    confidentiality: {"environment and application config may hold credentials", nil},
    eval: {"durable code is made with the define tool", {:tool, :define}},
    routing: {"the URL surface is managed through Host.Router", Host.Router},
    pubsub: {"publish/subscribe goes through Host.PubSub", Host.PubSub},
    migrations: {"migrations are run through Host.Migrator", Host.Migrator},
    data:
      {"the agent database is reached through Host.Repo; raw SQL is Host.Repo.query!(sql)",
       Host.Repo}
  ]

  @modules %{
    File => :fs,
    File.Stream => :fs,
    File.Stat => :fs,
    :file => :fs,
    :filelib => :fs,
    Agent => :state,
    :ets => :state,
    :dets => :state,
    :persistent_term => :state,
    :atomics => :state,
    :counters => :state,
    Process => :concurrency,
    Task => :concurrency,
    Task.Supervisor => :concurrency,
    GenServer => :concurrency,
    Supervisor => :concurrency,
    DynamicSupervisor => :concurrency,
    PartitionSupervisor => :concurrency,
    Registry => :concurrency,
    :timer => :concurrency,
    :gen_server => :concurrency,
    :gen_statem => :concurrency,
    :proc_lib => :concurrency,
    Application => :confidentiality,
    Code => :eval,
    Module => :eval,
    :code => :eval,
    :erl_eval => :eval,
    Phoenix.Router => :routing,
    Phoenix.Endpoint => :routing,
    Phoenix.LiveView.Router => :routing,
    Plug.Router => :routing,
    Phoenix.PubSub => :pubsub,
    Ecto.Migrator => :migrations,
    Ecto.Repo => :data,
    Ecto.Adapters.SQL => :data
  }

  # Keyed by name, not arity: the grants own arities, the hint only
  # has to teach.
  @functions %{
    {Kernel, :spawn} => :concurrency,
    {Kernel, :spawn_link} => :concurrency,
    {Kernel, :spawn_monitor} => :concurrency,
    {Kernel, :send} => :concurrency,
    {Kernel, :exit} => :concurrency,
    {System, :get_env} => :confidentiality,
    {System, :fetch_env} => :confidentiality,
    {System, :fetch_env!} => :confidentiality,
    {System, :put_env} => :confidentiality,
    {System, :delete_env} => :confidentiality,
    {Phoenix.Component, :embed_templates} => :fs,
    {Phoenix.Controller, :send_download} => :fs,
    {Plug.Conn, :send_file} => :fs,
    {Ecto.Migration, :execute_file} => :fs
  }

  @doc "The hint for a refused module, or `nil` when the generic copy is all there is."
  @spec hint(Policy.t(), module()) :: String.t() | nil
  def hint(%Policy{} = policy, module), do: lookup(policy, Map.fetch(@modules, module))

  @doc "The hint for a refused function of a partially granted module, or `nil`."
  @spec hint(Policy.t(), module(), atom()) :: String.t() | nil
  def hint(%Policy{} = policy, module, fun),
    do: lookup(policy, Map.fetch(@functions, {module, fun}))

  @doc """
  What the policy deliberately withholds, for `Beamlet.Policy.render/1`:
  each hint whose door is open under the policy, with the signed
  modules the policy denies. A hint no module needs is left out.
  """
  @spec denials(Policy.t()) :: [{String.t(), [module()]}]
  def denials(%Policy{} = policy) do
    for {category, {copy, door}} <- @categories,
        open?(policy, door),
        modules = denied_in(policy, category),
        modules != [] do
      {copy, modules}
    end
  end

  @doc "Every signed module."
  @spec modules() :: [module()]
  def modules, do: Map.keys(@modules)

  @doc "Every signed `{module, function}` pair."
  @spec functions() :: [{module(), atom()}]
  def functions, do: Map.keys(@functions)

  @doc "Every door a redirect points at."
  @spec doors() :: [door()]
  def doors, do: for({_category, {_copy, door}} <- @categories, door != nil, do: door)

  defp lookup(policy, {:ok, category}) do
    {copy, door} = @categories[category]
    if open?(policy, door), do: copy
  end

  defp lookup(_policy, :error), do: nil

  defp open?(_policy, nil), do: true
  defp open?(policy, {:tool, tool}), do: tool in policy.tools
  defp open?(policy, module), do: Policy.allowed?(policy, module)

  defp denied_in(policy, category) do
    denied =
      for {module, ^category} <- @modules,
          not Policy.allowed?(policy, module),
          do: module

    Enum.sort_by(denied, &inspect/1)
  end
end
