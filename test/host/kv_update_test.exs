defmodule Host.KVUpdateTest do
  # On Ecto's ordinary pool, as in production: the sandbox's one
  # shared connection would serialise the writers this test races.
  use Beamlet.Case, agent_sandbox: false

  test "concurrent updates to one key lose nothing" do
    1..50
    |> Enum.map(fn _ ->
      Task.async(fn ->
        for _ <- 1..20, do: Host.KV.update("kv-test:hits", 1, &(&1 + 1))
      end)
    end)
    |> Task.await_many()

    assert Host.KV.get("kv-test:hits") == 1000
  end
end
