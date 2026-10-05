defmodule Beamlet.CLIResetTest do
  # Cold, like the CLI's other commands outside a test beamlet: reset
  # starts the system half itself, for the route rows in the
  # beamlet's database, and works on the data dir's files for the
  # rest. No sandbox here, so what a test writes to that database is
  # committed and cleaned up after.
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Beamlet.CLI
  alias Beamlet.Config

  setup do
    for dir <- [Config.code_dir(), Config.files_dir()], do: File.rm_rf!(dir)
    :ok
  end

  test "removes the routes, the agent database, the code dir and the files dir, keeping the rest" do
    File.mkdir_p!(Path.join(Config.code_dir(), "lib"))
    File.mkdir_p!(Path.join(Config.code_dir(), ".git"))
    File.write!(Path.join(Config.code_dir(), "lib/hello.ex"), "defmodule Hello do end")
    File.mkdir_p!(Config.files_dir())
    File.write!(Path.join(Config.files_dir(), "note.txt"), "kept?")
    File.mkdir_p!(Config.db_dir())
    agent_db = Config.agent_db_file()
    for file <- [agent_db, agent_db <> "-wal", agent_db <> "-shm"], do: File.write!(file, "")
    config_file = Path.join(Config.data_dir(), "config.exs")
    File.touch!(config_file)
    on_exit(fn -> File.rm(config_file) end)
    token = with_system(fn -> mount_route!() end)
    on_exit(fn -> with_system(fn -> Beamlet.Tokens.delete(token) end) end)

    assert {:ok, output} = with_io(fn -> CLI.main(["reset"]) end)

    assert output =~ "Removed 1 route"
    assert output =~ "Removed the agent database: #{agent_db}"
    assert output =~ "Removed the code dir and its history: #{Config.code_dir()}"
    assert output =~ "Removed the files dir: #{Config.files_dir()}"
    assert output =~ "restart it now"

    refute File.exists?(Config.code_dir())
    refute File.exists?(Config.files_dir())
    for file <- [agent_db, agent_db <> "-wal", agent_db <> "-shm"], do: refute(File.exists?(file))
    assert File.exists?(Config.beamlet_db_file())
    assert File.exists?(config_file)
    assert Process.whereis(Beamlet) == nil

    with_system(fn ->
      assert Beamlet.Routes.list() == []
      assert {:ok, _token} = Beamlet.Tokens.find(token.id)
    end)
  end

  test "says what was absent when there is nothing to remove" do
    agent_db = Config.agent_db_file()
    for file <- [agent_db, agent_db <> "-wal", agent_db <> "-shm"], do: File.rm(file)

    assert {:ok, output} = with_io(fn -> CLI.main(["reset"]) end)

    assert output =~ "No routes mounted"
    assert output =~ "No agent database at #{agent_db}"
    assert output =~ "No code dir and its history at #{Config.code_dir()}"
    assert output =~ "No files dir at #{Config.files_dir()}"
  end

  test "a file it cannot remove stops the reset, saying what is left" do
    agent_db = Config.agent_db_file()
    File.mkdir_p!(Config.db_dir())
    File.write!(agent_db, "")
    File.mkdir_p!(Config.code_dir())
    locked = Path.join(Config.files_dir(), "locked")
    File.mkdir_p!(locked)
    File.write!(Path.join(locked, "stuck.txt"), "")
    # Root ignores the mode, so this fails in a container running as root.
    File.chmod!(locked, 0o500)
    on_exit(fn -> File.chmod(locked, 0o700) end)

    {result, stdout} =
      with_io(fn ->
        assert {:error, stderr} = with_io(:stderr, fn -> CLI.main(["reset"]) end)
        stderr
      end)

    assert stdout =~ "Removed the agent database: #{agent_db}"
    assert stdout =~ "Removed the code dir and its history"
    refute stdout =~ "restart it now"
    assert result =~ "could not remove"
    assert result =~ "The reset stopped partway"
    assert result =~ "run `beamlet reset` again"
    refute File.exists?(agent_db)
    refute File.exists?(Config.code_dir())
    assert Process.whereis(Beamlet) == nil

    File.chmod!(locked, 0o700)
    assert {:ok, output} = with_io(fn -> CLI.main(["reset"]) end)
    assert output =~ "Removed the files dir"
    refute File.exists?(Config.files_dir())
  end

  test "a bad config fails the command with the boot's own error" do
    Application.put_env(:beamlet, :eval, timeout: 0)
    on_exit(fn -> Application.delete_env(:beamlet, :eval) end)
    File.mkdir_p!(Config.code_dir())

    assert {:error, output} = with_io(:stderr, fn -> CLI.main(["reset"]) end)
    assert output =~ "config :beamlet, :eval"
    assert File.exists?(Config.code_dir())
  end

  # A row as Host.Router would write it, and a token to mount it with,
  # which is what the reset must keep.
  defp mount_route! do
    {:ok, token} = Beamlet.Tokens.create(name: "reset#{System.unique_integer([:positive])}")
    {:ok, authenticated} = Beamlet.Tokens.authenticate(token.secret)
    principal = Beamlet.Principal.from_token(authenticated)

    {:ok, _route} =
      Beamlet.Routes.create(%{
        kind: :live_view,
        path: "/reset-test",
        module: "Reset.PageLive",
        principal: principal
      })

    token
  end

  defp with_system(fun) do
    {:ok, pid} = Beamlet.start_link(only: :system)

    try do
      fun.()
    after
      Supervisor.stop(pid)
    end
  end
end
