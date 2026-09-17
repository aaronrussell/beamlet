defmodule Beamlet.TestPolicies do
  @moduledoc false

  alias Beamlet.Policy
  alias Beamlet.Policy.Signage

  # The default with every signage door granted, for tests about the
  # join between a refusal and its hint. Every door is a real module
  # the default grants since step 15, so today this is the default
  # itself; it stays as the written form of "all doors open" should a
  # door ever leave the default, built as a struct update because
  # Policy.build/2 refuses a module it cannot load.
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
