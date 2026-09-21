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

    assert {:ok, output} = with_io(fn -> CLI.main(["users.create", "cold", "--no-password"]) end)
    assert output =~ "Created user cold."
    assert Process.whereis(Beamlet) == nil
    assert Process.whereis(Beamlet.Repo) == nil

    assert {:ok, output} =
             with_io(fn ->
               CLI.main(["tokens.create", "cold", "laptop", "--policy", "restricted"])
             end)

    assert output =~ "Created token laptop for cold (policy restricted)."
    assert output =~ "Secret (shown once): "

    assert {:ok, output} = with_io(fn -> CLI.main(["policies"]) end)
    assert String.split(output, "\n", trim: true) == ["default", "restricted"]

    assert {:ok, output} = with_io(fn -> CLI.main(["policies.show", "restricted"]) end)

    assert output =~
             "Policy: restricted\nTools: eval (no define: modules cannot be added with this token)\n"

    assert {:ok, output} = with_io(fn -> CLI.main(["users.delete", "cold"]) end)
    assert output =~ "Deleted user cold and 1 token."
    assert Process.whereis(Beamlet) == nil

    assert File.exists?(Path.join(Beamlet.Config.db_dir(), "beamlet.db"))
  end

  test "a bad policy declaration fails the command with the boot's error" do
    Application.put_env(:beamlet, :policies, explorer: [tool: [:eval]])

    assert {:error, output} = with_io(:stderr, fn -> CLI.main(["users"]) end)
    assert output =~ "policy explorer: unknown key :tool"
    assert Process.whereis(Beamlet) == nil
    assert Process.whereis(Beamlet.Repo) == nil
  end
end
