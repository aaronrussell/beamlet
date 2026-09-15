defmodule Beamlet.PoliciesTest do
  use ExUnit.Case, async: false

  alias Beamlet.Policies
  alias Beamlet.Policy

  setup do
    on_exit(fn -> Application.delete_env(:beamlet, :policies) end)
    :ok
  end

  test "a beamlet with no declarations has only the default" do
    start_supervised!({Beamlet, []})

    assert Policies.names() == ["default"]
    assert Policies.fetch("default") == {:ok, Policy.default()}
    assert Policies.fetch("nope") == {:error, :not_found}
  end

  test "declared policies are built on the default at boot" do
    Application.put_env(:beamlet, :policies,
      explorer: [tools: [:eval], deny: [IO]],
      builder: [rules: [allow_defmacro: true]]
    )

    start_supervised!({Beamlet, []})

    assert Policies.names() == ["builder", "default", "explorer"]

    assert {:ok, %Policy{name: "explorer", tools: [:eval]} = explorer} =
             Policies.fetch("explorer")

    refute Policy.allowed?(explorer, IO)
    assert Policy.allowed?(explorer, Enum, :map, 2)

    assert {:ok, %Policy{rules: %{allow_defmacro: true}}} = Policies.fetch("builder")
  end

  @tag :capture_log
  test "a bad declaration fails the boot with the teaching error" do
    Application.put_env(:beamlet, :policies, explorer: [tool: [:eval]])

    assert boot_error() =~ "policy explorer: unknown key :tool"
  end

  @tag :capture_log
  test "declaring default fails the boot" do
    Application.put_env(:beamlet, :policies, default: [])

    assert boot_error() =~ "policy default: the name is reserved"
  end

  @tag :capture_log
  test "declaring a policy twice fails the boot" do
    Application.put_env(:beamlet, :policies, explorer: [], explorer: [])

    assert boot_error() =~ "policy explorer: declared twice"
  end

  @tag :capture_log
  test "policies that are not a keyword list fail the boot" do
    Application.put_env(:beamlet, :policies, %{explorer: []})

    assert boot_error() =~ "config :beamlet, :policies must be a keyword list"
  end

  defp boot_error do
    assert {:error, {{:shutdown, {:failed_to_start_child, Policies, {error, _stack}}}, _spec}} =
             start_supervised({Beamlet, []})

    Exception.message(error)
  end
end
