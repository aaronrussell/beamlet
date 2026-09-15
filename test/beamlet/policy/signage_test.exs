defmodule Beamlet.Policy.SignageTest do
  use ExUnit.Case, async: true

  alias Beamlet.Policy
  alias Beamlet.Policy.Default
  alias Beamlet.Policy.Signage
  alias Beamlet.TestPolicies

  describe "the cross-checks against the default" do
    test "every signed module exists and the default denies it" do
      grants = Default.grants()

      stale =
        Enum.reject(Signage.modules(), fn mod ->
          Code.ensure_loaded?(mod) and not Map.has_key?(grants, mod)
        end)

      assert stale == [],
             "signage for modules that do not exist or that the default grants, " <>
               "so the hint could never fire: #{inspect(stale)}"
    end

    test "every signed function is denied at some exported arity" do
      policy = Policy.default()

      dangling =
        Enum.reject(Signage.functions(), fn {mod, fun} ->
          Code.ensure_loaded?(mod) and
            Enum.any?(0..8, fn arity ->
              exported?(mod, fun, arity) and not Policy.allowed?(policy, mod, fun, arity)
            end)
        end)

      assert dangling == [],
             "signage for functions that exist at no denied arity; the hint would " <>
               "never fire, or the grants drifted: #{inspect(dangling)}"
    end

    test "every door is a Host module or a tool a policy can grant" do
      for door <- Signage.doors() do
        case door do
          {:tool, tool} -> assert tool in Policy.tools()
          module -> assert String.starts_with?(inspect(module), "Host.")
        end
      end
    end
  end

  describe "hint/2" do
    test "a redirect fires when the policy grants its door" do
      assert Signage.hint(TestPolicies.doors_open(), File) ==
               "Host.FS provides scoped file access"
    end

    test "a redirect is dropped when the policy withholds its door" do
      assert Signage.hint(Policy.default(), File) == nil

      {:ok, policy} = Policy.build(:x, deny: [Host.Repo])
      assert Signage.hint(policy, Ecto.Repo) == nil
    end

    test "the define redirect is dropped for a policy without the tool" do
      assert Signage.hint(Policy.default(), Code) =~ "define tool"

      {:ok, policy} = Policy.build(:x, tools: [:eval])
      assert Signage.hint(policy, Code) == nil
    end

    test "a closure fires under any policy" do
      {:ok, policy} = Policy.build(:x, tools: [], deny: [Host.Repo])
      assert Signage.hint(policy, Task) =~ "process primitives are withheld as a family"
      assert Signage.hint(policy, Application) =~ "may hold credentials"
    end

    test "an unsigned module has no hint" do
      assert Signage.hint(Policy.default(), :os) == nil
      assert Signage.hint(Policy.default(), Enum) == nil
    end
  end

  describe "hint/3" do
    test "a carve-out carries its copy under the same door rule" do
      assert Signage.hint(TestPolicies.doors_open(), Plug.Conn, :send_file) ==
               "Host.FS provides scoped file access"

      assert Signage.hint(Policy.default(), Plug.Conn, :send_file) == nil
    end

    test "a Kernel local carries the closure" do
      assert Signage.hint(Policy.default(), Kernel, :spawn) =~ "process primitives"
      assert Signage.hint(Policy.default(), Kernel, :apply) == nil
    end
  end

  describe "denials/1" do
    test "lists open-door categories with the members the policy denies" do
      denials = TestPolicies.doors_open() |> Signage.denials() |> Map.new()

      assert denials["Host.FS provides scoped file access"] ==
               [:file, :filelib, File, File.Stat, File.Stream]

      assert [Ecto.Adapters.SQL, Ecto.Repo] =
               denials[
                 "the agent database is reached through Host.Repo; raw SQL is Host.Repo.query!(sql)"
               ]
    end

    test "a re-granted member drops out and a closed door drops the category" do
      {:ok, policy} = Policy.build(:x, allow: [Task], deny: [Host.Repo])
      denials = Signage.denials(policy)

      {_copy, concurrency} =
        Enum.find(denials, fn {copy, _} -> copy =~ "process primitives" end)

      refute Task in concurrency
      assert Process in concurrency
      refute Enum.any?(denials, fn {copy, _} -> copy =~ "Host.Repo" end)
      refute Enum.any?(denials, fn {copy, _} -> copy =~ "Host.FS" end)
    end
  end

  defp exported?(mod, fun, arity) do
    function_exported?(mod, fun, arity) or macro_exported?(mod, fun, arity)
  end
end
