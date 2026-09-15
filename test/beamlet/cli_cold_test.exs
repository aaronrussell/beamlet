defmodule Beamlet.CLIColdTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Beamlet.CLI

  @moduletag :capture_log

  test "runs with no beamlet in the VM, starting and stopping the system repo itself" do
    assert Process.whereis(Beamlet) == nil
    assert Process.whereis(Beamlet.Repo) == nil

    assert {:ok, output} = with_io(fn -> CLI.main(["users.create", "cold"]) end)
    assert output =~ "Created user cold."
    assert Process.whereis(Beamlet.Repo) == nil

    assert {:ok, output} = with_io(fn -> CLI.main(["tokens.create", "cold", "laptop"]) end)
    assert output =~ "Secret (shown once): "

    assert {:ok, output} = with_io(fn -> CLI.main(["users.delete", "cold"]) end)
    assert output =~ "Deleted user cold and 1 token."
    assert Process.whereis(Beamlet.Repo) == nil

    assert File.exists?(Path.join(Beamlet.Config.db_dir(), "beamlet.db"))
  end
end
