defmodule Beamlet.CLIResetTest do
  # Cold, like the CLI's other commands outside a test beamlet: reset
  # starts nothing and works on the data dir's files alone.
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Beamlet.CLI
  alias Beamlet.Config

  setup do
    for dir <- [Config.code_dir(), Config.files_dir()], do: File.rm_rf!(dir)
    :ok
  end

  test "removes the code dir, the files dir and the agent database, keeping the rest" do
    File.mkdir_p!(Path.join(Config.code_dir(), "lib"))
    File.mkdir_p!(Path.join(Config.code_dir(), ".git"))
    File.write!(Path.join(Config.code_dir(), "lib/hello.ex"), "defmodule Hello do end")
    File.mkdir_p!(Config.files_dir())
    File.write!(Path.join(Config.files_dir(), "note.txt"), "kept?")
    File.mkdir_p!(Config.db_dir())
    agent_db = Config.agent_db_file()
    for file <- [agent_db, agent_db <> "-wal", agent_db <> "-shm"], do: File.write!(file, "")
    File.touch!(Config.system_db_file())
    config_file = Path.join(Config.data_dir(), "config.exs")
    File.touch!(config_file)
    on_exit(fn -> File.rm(config_file) end)

    assert {:ok, output} = with_io(fn -> CLI.main(["reset"]) end)

    assert output =~ "Removed the code dir and its history: #{Config.code_dir()}"
    assert output =~ "Removed the files dir: #{Config.files_dir()}"
    assert output =~ "Removed the agent database: #{agent_db}"
    assert output =~ "restart it now"

    refute File.exists?(Config.code_dir())
    refute File.exists?(Config.files_dir())
    for file <- [agent_db, agent_db <> "-wal", agent_db <> "-shm"], do: refute(File.exists?(file))
    assert File.exists?(Config.system_db_file())
    assert File.exists?(config_file)
    assert Process.whereis(Beamlet) == nil
  end

  test "says what was absent when there is nothing to remove" do
    agent_db = Config.agent_db_file()
    for file <- [agent_db, agent_db <> "-wal", agent_db <> "-shm"], do: File.rm(file)

    assert {:ok, output} = with_io(fn -> CLI.main(["reset"]) end)

    assert output =~ "No code dir and its history at #{Config.code_dir()}"
    assert output =~ "No files dir at #{Config.files_dir()}"
    assert output =~ "No agent database at #{agent_db}"
  end

  test "a bad config fails the command with the boot's own error" do
    Application.put_env(:beamlet, :eval, timeout: 0)
    on_exit(fn -> Application.delete_env(:beamlet, :eval) end)
    File.mkdir_p!(Config.code_dir())

    assert {:error, output} = with_io(:stderr, fn -> CLI.main(["reset"]) end)
    assert output =~ "config :beamlet, :eval"
    assert File.exists?(Config.code_dir())
  end
end
