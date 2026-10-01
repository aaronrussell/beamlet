defmodule Beamlet.CLIColdTest do
  # The cold path: the CLI in a VM with no beamlet running, which is
  # what `mix beamlet` and the release script are. It starts the
  # system half of a beamlet itself and stops it after. Tests under
  # `Beamlet.Case` never reach this branch, since they always have a
  # beamlet running.
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Beamlet.CLI

  @moduletag :capture_log

  setup do
    on_exit(fn -> Application.delete_env(:beamlet, :policies) end)
    :ok
  end

  test "runs with no beamlet in the VM, starting and stopping the system half itself" do
    Application.put_env(:beamlet, :policies, restricted: [tools: [:eval]])
    assert Process.whereis(Beamlet) == nil

    # No sandbox here, so the token is committed: a unique name keeps a
    # run that failed before its delete from failing the next.
    name = "cold#{System.unique_integer([:positive])}"

    assert {:ok, output} =
             with_io(fn -> CLI.main(["tokens.create", name, "--policy", "restricted"]) end)

    assert output =~ "Created token #{name} (policy restricted)."
    assert output =~ "Secret (shown once): "
    assert Process.whereis(Beamlet) == nil
    assert Process.whereis(Beamlet.Repo) == nil

    assert {:ok, output} = with_io(fn -> CLI.main(["tokens"]) end)
    [id] = Regex.run(~r/^(\d+)\s+cli\s+#{name}\s+restricted/m, output, capture: :all_but_first)

    assert {:ok, output} = with_io(fn -> CLI.main(["policies"]) end)
    assert String.split(output, "\n", trim: true) == ["default", "restricted"]

    assert {:ok, output} = with_io(fn -> CLI.main(["policies.show", "restricted"]) end)

    assert output =~
             "Policy: restricted\nTools: eval (not granted: define, patch)\n"

    assert {:ok, output} = with_io(fn -> CLI.main(["tokens.delete", id]) end)
    assert output =~ "Deleted token #{name} (#{id})."
    assert Process.whereis(Beamlet) == nil

    assert File.exists?(Path.join(Beamlet.Config.db_dir(), "beamlet.db"))
  end

  test "a bad policy declaration fails the command with the boot's error" do
    Application.put_env(:beamlet, :policies, explorer: [tool: [:eval]])

    assert {:error, output} = with_io(:stderr, fn -> CLI.main(["tokens"]) end)
    assert output =~ "policy explorer: unknown key :tool"
    assert Process.whereis(Beamlet) == nil
    assert Process.whereis(Beamlet.Repo) == nil
  end

  test "a boot check raised outside any child fails the command with its message" do
    data_dir = Application.fetch_env!(:beamlet, :data_dir)
    on_exit(fn -> Application.put_env(:beamlet, :data_dir, data_dir) end)

    missing =
      Path.join(System.tmp_dir!(), "beamlet_missing_#{System.unique_integer([:positive])}")

    Application.put_env(:beamlet, :data_dir, missing)

    assert {:error, output} = with_io(:stderr, fn -> CLI.main(["tokens"]) end)

    assert output ==
             "config :beamlet, :data_dir does not exist: #{missing} " <>
               "(create or mount it before starting)\n"

    assert Process.whereis(Beamlet) == nil
  end
end
