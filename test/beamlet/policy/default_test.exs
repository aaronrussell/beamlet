defmodule Beamlet.Policy.DefaultTest do
  use ExUnit.Case, async: true

  alias Beamlet.Policy
  alias Beamlet.Policy.Default

  # The guards on the curation pass.
  #
  # The pinning test freezes the curated default against a committed
  # golden file, so no regrouping or platform upgrade can change the
  # table silently; regeneration instructions are in
  # Beamlet.PolicyRender.
  #
  # The coverage test makes the walk provably exhaustive: every
  # documented module of the platform applications must carry exactly
  # one ruling in Beamlet.Policy.Default, granted or recorded as not
  # granted. A new module arriving with an Elixir/OTP upgrade fails
  # this test by name and demands a ruling.

  @platform_apps [:elixir, :stdlib, :kernel, :erts, :crypto]

  describe "the curation guards" do
    test "the curated default is pinned by the golden file" do
      fixture = Path.expand("../../support/fixtures/policy_default.txt", __DIR__)

      assert Beamlet.PolicyRender.render(Default.grants()) == File.read!(fixture),
             "the default's grants changed. If the change is deliberate, regenerate " <>
               "the golden (instructions in Beamlet.PolicyRender) and review the diff"
    end

    test "every documented platform module has an explicit ruling" do
      universe = platform_universe()

      # Guard the internal filter itself: if doc chunks went missing
      # (a stripped build), the universe would silently collapse.
      assert Enum in universe
      assert :lists in universe

      ruled =
        MapSet.union(MapSet.new(Map.keys(Default.grants())), MapSet.new(not_granted()))

      unruled = Enum.reject(universe, &MapSet.member?(ruled, &1))

      assert unruled == [],
             "platform modules without a ruling in Beamlet.Policy.Default " <>
               "(grant them, or record the denial under not-granted): #{inspect(unruled)}"
    end

    test "granted and not-granted are disjoint" do
      granted = MapSet.new(Map.keys(Default.grants()))
      buckets = MapSet.new(not_granted())

      assert MapSet.intersection(granted, buckets) == MapSet.new(),
             "granted modules must not appear under not-granted"
    end

    test "not-granted names no module twice" do
      modules = not_granted()
      assert Enum.uniq(modules) == modules
    end

    test "every partial grant names functions the module exports" do
      stale =
        for {mod, {_kind, fas}} <- Default.grants(),
            {fun, arity} <- fas,
            not (Code.ensure_loaded?(mod) and exported?(mod, fun, arity)),
            do: {mod, fun, arity}

      assert stale == [],
             "partial grants naming functions that do not exist: #{inspect(stale)}"
    end

    test "not-granted lists no module that does not exist" do
      universe = MapSet.new(platform_universe())
      stale = Enum.reject(not_granted(), &MapSet.member?(universe, &1))

      assert stale == [],
             "not-granted entries absent from the platform universe: #{inspect(stale)}"
    end
  end

  describe "grants/0" do
    setup do
      %{policy: Policy.default()}
    end

    test "grants core data modules wholesale", %{policy: policy} do
      assert policy.grants[Enum] == :all
      assert policy.grants[Map] == :all
      assert policy.grants[DateTime] == :all
    end

    test "denies anything absent", %{policy: policy} do
      for mod <- [File, Process, Task, :os, :ets, Application] do
        refute Policy.allowed?(policy, mod), "#{inspect(mod)} should be absent"
      end
    end

    test "grants the Erlang gap-fillers", %{policy: policy} do
      assert policy.grants[:math] == :all
      assert policy.grants[:crypto] == :all
      assert policy.grants[:queue] == :all
    end

    test "limits System to clock and VM introspection", %{policy: policy} do
      assert Policy.allowed?(policy, System, :monotonic_time, 0)
      assert Policy.allowed?(policy, System, :convert_time_unit, 3)
      refute Policy.allowed?(policy, System, :get_env, 1)
      refute Policy.allowed?(policy, System, :cmd, 2)
      refute Policy.allowed?(policy, System, :halt, 0)
    end

    test "denies term serialization on :erlang", %{policy: policy} do
      assert Policy.allowed?(policy, :erlang, :phash2, 1)
      refute Policy.allowed?(policy, :erlang, :term_to_binary, 1)
      refute Policy.allowed?(policy, :erlang, :binary_to_term, 1)
    end

    test "scrubs the laundering functions from Kernel and String", %{policy: policy} do
      refute Policy.allowed?(policy, Kernel, :apply, 2)
      refute Policy.allowed?(policy, Kernel, :spawn, 1)
      refute Policy.allowed?(policy, Kernel, :send, 2)
      refute Policy.allowed?(policy, String, :to_atom, 1)
      assert Policy.allowed?(policy, Kernel, :to_string, 1)
      assert Policy.allowed?(policy, String, :upcase, 1)
    end

    test "limits IO to output", %{policy: policy} do
      assert Policy.allowed?(policy, IO, :puts, 1)
      assert Policy.allowed?(policy, IO, :inspect, 2)
      refute Policy.allowed?(policy, IO, :gets, 1)
      refute Policy.allowed?(policy, IO, :write, 1)
    end

    test "grants Path except the filesystem-touching wildcard", %{policy: policy} do
      assert Policy.allowed?(policy, Path, :join, 2)
      refute Policy.allowed?(policy, Path, :wildcard, 1)
      refute Policy.allowed?(policy, Path, :wildcard, 2)
    end

    test "grants the Elixir exception family, including those of denied modules",
         %{policy: policy} do
      assert policy.grants[ArgumentError] == :all
      assert policy.grants[File.Error] == :all
      refute Policy.allowed?(policy, File)
    end

    test "grants Host.Repo minus its process controls", %{policy: policy} do
      assert Policy.allowed?(policy, Host.Repo, :query!, 2)
      assert Policy.allowed?(policy, Host.Repo, :all, 1)
      refute Policy.allowed?(policy, Host.Repo, :put_dynamic_repo, 1)
      refute Policy.allowed?(policy, Host.Repo, :stop, 0)
    end

    test "grants the web authoring surface with its filesystem carve-outs", %{policy: policy} do
      assert policy.grants[Phoenix.LiveView] == :all
      assert policy.grants[Phoenix.HTML] == :all
      assert Policy.allowed?(policy, Phoenix.Component, :assign, 3)
      refute Policy.allowed?(policy, Phoenix.Component, :embed_templates, 1)
      refute Policy.allowed?(policy, Plug.Conn, :send_file, 3)
      refute Policy.allowed?(policy, Phoenix.Router)
      refute Policy.allowed?(policy, Phoenix.Endpoint)
    end

    test "grants the data authoring surface and the Ecto exception family", %{policy: policy} do
      assert policy.grants[Ecto.Query] == :all
      assert policy.grants[Ecto.Changeset] == :all
      assert policy.grants[Ecto.NoResultsError] == :all
      refute Policy.allowed?(policy, Ecto.Migration, :execute_file, 1)
      refute Policy.allowed?(policy, Ecto.Repo)
      refute Policy.allowed?(policy, Ecto.Migrator)
    end

    test "expands the shipped packages, hidden modules excluded", %{policy: policy} do
      assert Default.packages() == [:jason, :req]
      assert policy.grants[Req] == :all
      assert policy.grants[Req.Response] == :all
      assert policy.grants[Jason] == :all
      # No moduledoc at all still grants; @moduledoc false does not.
      assert policy.grants[Req.Test.OwnershipError] == :all
      refute Policy.allowed?(policy, Req.Utils)
      refute Policy.allowed?(policy, Req.Application)
    end
  end

  defp exported?(mod, fun, arity) do
    function_exported?(mod, fun, arity) or macro_exported?(mod, fun, arity)
  end

  defp not_granted do
    Enum.flat_map(Default.not_granted(), fn {_reason, modules} -> modules end)
  end

  defp platform_universe do
    for app <- @platform_apps,
        _ = Application.load(app),
        module <- Application.spec(app, :modules) || [],
        documented?(module) do
      module
    end
  end

  # Hidden or absent docs mark a module internal, the platform's own
  # convention. A filter mistake here is benign: an internal module
  # wrongly surfaced fails the coverage test asking for a ruling; a
  # public module wrongly hidden stays denied by default.
  defp documented?(module) do
    match?({:docs_v1, _, _, _, %{}, _, _}, Code.fetch_docs(module))
  end
end
