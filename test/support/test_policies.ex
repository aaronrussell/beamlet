defmodule Beamlet.TestPolicies do
  @moduledoc false

  alias Beamlet.Policy
  alias Beamlet.Policy.Signage

  # The default with every signage door granted, for tests about the
  # join between a refusal and its hint. The Host.* doors land at step
  # 15; until then a redirect at one is dropped under the real
  # default, and Policy.build/2 refuses a module it cannot load, so
  # this is a struct update.
  @spec doors_open() :: Policy.t()
  def doors_open do
    policy = Policy.default()

    doors =
      for door <- Signage.doors(),
          is_atom(door),
          not Policy.allowed?(policy, door),
          do: {door, :all}

    %{policy | grants: Map.merge(policy.grants, Map.new(doors))}
  end
end
